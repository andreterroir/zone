package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
	"github.com/invopop/jsonschema"
)

const defaultBaseURL = "https://opencode.ai/zen/go"
const systemPrompt = "You are a coding agent named zone - start from exploring the current directory"
const globalAgentsPath = "/home/andrew/.agents/AGENTS.md"
const globalAgentsLocalPath = "/home/andrew/.agents/AGENTS.local.md"

func loadSystemPrompt() []anthropic.TextBlockParam {
	blocks := []anthropic.TextBlockParam{{Text: systemPrompt}}

	if content, err := os.ReadFile(globalAgentsPath); err == nil {
		blocks = append(blocks, anthropic.TextBlockParam{
			Text: "# Agent Instructions\n\n" + string(content),
		})
	}

	if content, err := os.ReadFile(globalAgentsLocalPath); err == nil {
		blocks = append(blocks, anthropic.TextBlockParam{
			Text: "# Machine Specific Agent Instructions\n\n" + string(content),
		})
	}

	if root, err := gitRepoRoot(); err == nil {
		if content, err := os.ReadFile(filepath.Join(root, "AGENTS.md")); err == nil {
			blocks = append(blocks, anthropic.TextBlockParam{
				Text: "# Repository Agent Instructions\n\n" + string(content),
			})
		}
	}

	// cwd AGENTS.md is loaded last so working-directory-specific
	// instructions can override repo-wide ones. Resolved relative to
	// os.Getwd(); missing file is skipped silently.
	if cwd, err := os.Getwd(); err == nil {
		if content, err := os.ReadFile(filepath.Join(cwd, "AGENTS.md")); err == nil {
			blocks = append(blocks, anthropic.TextBlockParam{
				Text: "# Working Directory Agent Instructions\n\n" + string(content),
			})
		}
	}

	return blocks
}

// gitRepoRoot returns the absolute path of the current git working tree's
// top-level directory, or an error if the cwd is not inside a repository.
// Implemented via `git rev-parse --show-toplevel`; failures (no git on
// PATH, not in a repo) are returned to the caller so it can skip silently,
// matching how loadSystemPrompt handles missing agent-instruction files.
func gitRepoRoot() (string, error) {
	cmd := exec.Command("git", "rev-parse", "--show-toplevel")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func main() {
	fs := flag.NewFlagSet(os.Args[0], flag.ExitOnError)
	fs.Parse(os.Args[1:])
	initialPrompt := strings.TrimSpace(strings.Join(fs.Args(), " "))

	opts := []option.RequestOption{option.WithHeader("x-opencode-session", strconv.FormatInt(time.Now().UnixNano(), 10)), option.WithHeader("User-Agent", "zone/0.1")}
	if _, ok := os.LookupEnv("ANTHROPIC_BASE_URL"); !ok {
		opts = append(opts, option.WithBaseURL(defaultBaseURL))
	}
	client := anthropic.NewClient(opts...)
	runAgent(&client, initialPrompt)
}

func runAgent(client *anthropic.Client, initialPrompt string) {
	scanner := bufio.NewScanner(os.Stdin)

	getUserMessage := func() (string, bool) {
		if !scanner.Scan() {
			return "", false
		}
		return scanner.Text(), true
	}

	tools := []ToolDefinition{ReadFileDefinition, ListFilesDefinition, EditFileDefinition, BashDefinition}
	agent := NewAgent(client, getUserMessage, tools, initialPrompt)
	err := agent.Run(context.TODO())
	if err != nil {
		fmt.Printf("Error: %s\n", err.Error())
	}
}

func NewAgent(client *anthropic.Client, getUserMessage func() (string, bool),
	tools []ToolDefinition, initialPrompt string) *Agent {
	return &Agent{
		client:         client,
		getUserMessage: getUserMessage,
		tools:          tools,
		initialPrompt:  initialPrompt,
	}
}

type Agent struct {
	client         *anthropic.Client
	getUserMessage func() (string, bool)
	tools          []ToolDefinition
	initialPrompt  string
}

func (a *Agent) Run(ctx context.Context) error {
	conversation := []anthropic.MessageParam{}

	fmt.Println("Chat with AI (use 'ctrl-c' to quit)")

	readUserInput := true
	if a.initialPrompt != "" {
		// Subsequent turns fall back to interactive stdin.
		fmt.Printf("\u001b[94mYou\u001b[0m: %s\n", a.initialPrompt)
		conversation = append(conversation,
			anthropic.NewUserMessage(anthropic.NewTextBlock(a.initialPrompt)))
		readUserInput = false
	}

	for {
		if readUserInput {
			fmt.Print("\u001b[94mYou\u001b[0m: ")
			userInput, ok := a.getUserMessage()
			if !ok {
				break
			}

			userMessage := anthropic.NewUserMessage(anthropic.NewTextBlock(userInput))
			conversation = append(conversation, userMessage)
		}

		message, err := a.runInference(ctx, conversation)
		if err != nil {
			return err
		}
		conversation = append(conversation, message)

		toolResults := []anthropic.ContentBlockParamUnion{}
		for _, content := range message.Content {
			switch {
			case content.OfText != nil:
				// Text was already streamed and newline-terminated in runInference.
				_ = content.OfText.Text
			case content.OfToolUse != nil:
				tu := content.OfToolUse
				// runInference always stores a json.RawMessage here.
				input, _ := tu.Input.(json.RawMessage)
				result := a.executeTool(tu.ID, tu.Name, input)
				toolResults = append(toolResults, result)
			}
		}
		if len(toolResults) == 0 {
			readUserInput = true
			continue
		}
		readUserInput = false
		conversation = append(conversation, anthropic.NewUserMessage(toolResults...))
	}

	return nil
}

func (a *Agent) executeTool(id, name string, input json.RawMessage) anthropic.ContentBlockParamUnion {
	var toolDef ToolDefinition
	var found bool
	for _, tool := range a.tools {
		if tool.Name == name {
			toolDef = tool
			found = true
			break
		}
	}
	if !found {
		return anthropic.NewToolResultBlock(id, "tool not found", true)
	}

	fmt.Printf("\u001b[92mtool\u001b[0m: %s(%s)\n", name, input)
	response, err := toolDef.Function(input)
	if err != nil {
		return anthropic.NewToolResultBlock(id, err.Error(), true)
	}
	return anthropic.NewToolResultBlock(id, response, false)
}

func (a *Agent) runInference(ctx context.Context, conversation []anthropic.MessageParam) (anthropic.MessageParam, error) {
	anthropicTools := []anthropic.ToolUnionParam{}
	for _, tool := range a.tools {
		anthropicTools = append(anthropicTools, anthropic.ToolUnionParam{
			OfTool: &anthropic.ToolParam{
				Name:        tool.Name,
				Description: anthropic.String(tool.Description),
				InputSchema: tool.InputSchema,
			},
		})
	}

	// SDK appends `stream: true` internally.
	stream := a.client.Messages.NewStreaming(ctx, anthropic.MessageNewParams{
		Model:     "minimax-m3",
		MaxTokens: 10000,
		System:    loadSystemPrompt(),
		Messages:  conversation,
		Tools:     anthropicTools,
	})
	defer stream.Close()

	// Build MessageParam from the stream instead of Message.ToParam():
	// the response ContentBlockUnion has no Of* accessors, and
	// AsText()/AsToolUse() round-trip through a fixed JSON snapshot and
	// discard streamed edits.
	//
	// TODO: execute each tool as soon as its content_block_stop arrives
	// to overlap independent tool calls with the stream.
	var blocks []anthropic.ContentBlockParamUnion

	type toolBuilder struct {
		id, name string
		inputBuf bytes.Buffer // partial JSON; materialized at content_block_stop
	}
	builders := map[int64]*toolBuilder{}

	// Print "AI: " once per turn so deltas flow on a single line.
	aiPrefixPrinted := false
	printAIPrefix := func() {
		if aiPrefixPrinted {
			return
		}
		os.Stdout.Write([]byte("\x1b[93mAI\x1b[0m: "))
		aiPrefixPrinted = true
	}

	for stream.Next() {
		ev := stream.Current()
		switch ev.Type {
		case "message_start":
			_ = ev.Message
		case "content_block_start":
			idx := ev.Index
			cb := ev.ContentBlock
			switch cb.Type {
			case "text":
				blocks = append(blocks, anthropic.ContentBlockParamUnion{
					OfText: &anthropic.TextBlockParam{Type: "text", Text: ""},
				})
			case "tool_use":
				tb := &toolBuilder{id: cb.ID, name: cb.Name}
				builders[idx] = tb
				blocks = append(blocks, anthropic.ContentBlockParamUnion{
					OfToolUse: &anthropic.ToolUseBlockParam{
						Type: "tool_use",
						ID:   tb.id,
						Name: tb.name,
						// Input is filled in at content_block_stop from tb.inputBuf.
					},
				})
			}
		case "content_block_delta":
			idx := ev.Index
			// Defensive: skip deltas that arrive before their block does.
			if int(idx) >= len(blocks) {
				continue
			}
			switch ev.Delta.Type {
			case "text_delta":
				printAIPrefix()
				t := ev.Delta.Text
				os.Stdout.Write([]byte(t))
				if tp := blocks[idx].OfText; tp != nil {
					tp.Text += t
				}
			case "input_json_delta":
				if tb, ok := builders[idx]; ok {
					tb.inputBuf.WriteString(ev.Delta.PartialJSON)
				}
			}
		case "content_block_stop":
			idx := ev.Index
			if int(idx) >= len(blocks) {
				continue
			}
			if tub, ok := builders[idx]; ok {
				if tup := blocks[idx].OfToolUse; tup != nil {
					tup.Input = json.RawMessage(tub.inputBuf.Bytes())
				}
			}
		case "message_delta":
			// stop_reason / usage — not surfaced by this agent.
			_ = ev.Delta
			_ = ev.Usage
		case "message_stop":
		}
	}

	if err := stream.Err(); err != nil {
		return anthropic.MessageParam{}, err
	}

	// Newline so the next You: prompt lands on its own line, even when
	// only tool_use blocks came back (so tool: ... lines aren't glued
	// to the prior prompt).
	if aiPrefixPrinted {
		os.Stdout.Write([]byte("\n"))
	}

	return anthropic.MessageParam{
		Role:    anthropic.MessageParamRoleAssistant,
		Content: blocks,
	}, nil
}

type ToolDefinition struct {
	Name        string                         `json:"name"`
	Description string                         `json:"description"`
	InputSchema anthropic.ToolInputSchemaParam `json:"input_schema"`
	Function    func(input json.RawMessage) (string, error)
}

var ReadFileDefinition = ToolDefinition{
	Name:        "read_file",
	Description: "Read the contents of a given relative file path. use this when you want to see what's inside a file. Do not use this with directory names.",
	InputSchema: ReadFileInputSchema,
	Function:    ReadFile,
}

type ReadFileInput struct {
	Path string `json:"path" jsonschema_description:"The relative path of a file in the working directory."`
}

var ReadFileInputSchema = GenerateSchema[ReadFileInput]()

func ReadFile(input json.RawMessage) (string, error) {
	readFileInput := ReadFileInput{}
	err := json.Unmarshal(input, &readFileInput)
	if err != nil {
		panic(err)
	}

	content, err := os.ReadFile(readFileInput.Path)
	if err != nil {
		return "", err
	}
	return string(content), nil
}

func GenerateSchema[T any]() anthropic.ToolInputSchemaParam {
	reflector := jsonschema.Reflector{
		AllowAdditionalProperties: false,
		DoNotReference:            true,
	}
	var v T

	schema := reflector.Reflect(v)

	return anthropic.ToolInputSchemaParam{
		Properties: schema.Properties,
	}
}

var ListFilesDefinition = ToolDefinition{
	Name:        "list_files",
	Description: "List files and directories at a given path. If no path is provided, lists files in the current directory.",
	InputSchema: ListFilesInputSchema,
	Function:    ListFiles,
}

type ListFilesInput struct {
	Path string `json:"path,omitempty" jsonschema_description:"Optional relative path to list files from. Defaults to current directory if not provided."`
}

var ListFilesInputSchema = GenerateSchema[ListFilesInput]()

func ListFiles(input json.RawMessage) (string, error) {
	listFilesInput := ListFilesInput{}
	err := json.Unmarshal(input, &listFilesInput)
	if err != nil {
		panic(err)
	}

	dir := "."
	if listFilesInput.Path != "" {
		dir = listFilesInput.Path
	}

	var files []string
	err = filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		relPath, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}

		if relPath != "." {
			if info.IsDir() {
				files = append(files, relPath+"/")
			} else {
				files = append(files, relPath)
			}
		}
		return nil
	})

	if err != nil {
		return "", err
	}
	result, err := json.Marshal(files)
	if err != nil {
		return "", err
	}
	return string(result), nil
}

var EditFileDefinition = ToolDefinition{
	Name: "edit_file",
	Description: `Make edits to a text file.

Replaces 'old_str' with 'new_str' in the given file. 'old_str' and 'new_str' MUST be different from each other.

If the file specified with path doesn't exist, it will be created.
`,
	InputSchema: EditFileInputSchema,
	Function:    EditFile,
}

type EditFileInput struct {
	Path   string `json:"path" jsonschema_description:"The path to the file"`
	OldStr string `json:"old_str" jsonschema_description:"Text to search for - must match exactly and must only have one match exactly"`
	NewStr string `json:"new_str" jsonschema_description:"Text to replace old_str with"`
}

var EditFileInputSchema = GenerateSchema[EditFileInput]()

func EditFile(input json.RawMessage) (string, error) {
	editFileInput := EditFileInput{}
	err := json.Unmarshal(input, &editFileInput)
	if err != nil {
		return "", err
	}

	if editFileInput.Path == "" || editFileInput.OldStr == editFileInput.NewStr {
		return "", fmt.Errorf("invalid input parameters")
	}

	content, err := os.ReadFile(editFileInput.Path)
	if err != nil {
		if os.IsNotExist(err) && editFileInput.OldStr == "" {
			return createNewFile(editFileInput.Path, editFileInput.NewStr)
		}
		return "", err
	}

	oldContent := string(content)
	const replaceAll = -1
	newContent := strings.Replace(oldContent, editFileInput.OldStr, editFileInput.NewStr, replaceAll)

	// oldStr == "" is the new-file path; that path is handled above.
	if oldContent == newContent && editFileInput.OldStr != "" {
		return "", fmt.Errorf("old_str not found in file")
	}

	err = os.WriteFile(editFileInput.Path, []byte(newContent), 0644)
	if err != nil {
		return "", err
	}

	return "OK", nil
}

var BashDefinition = ToolDefinition{
	Name:        "bash",
	Description: "Execute a single bash command and return its output. Runs the command via `/bin/bash -c <cmd>` in the current working directory with the inherited environment. Output is returned as a JSON object: {\"stdout\", \"stderr\", \"exit_code\", \"duration_ms\"}. Non-zero exit codes are reported as successful tool results (is_error=false) so the model can read stderr and react; only execution failures (e.g. command not found, timeout) are returned as is_error=true.",
	InputSchema: BashInputSchema,
	Function:    Bash,
}

type BashInput struct {
	Cmd string `json:"cmd" jsonschema_description:"The bash command to execute. Runs via /bin/bash -c with a 30s default timeout. Output is returned as a JSON object with stdout, stderr, exit_code, and duration_ms fields."`
}

var BashInputSchema = GenerateSchema[BashInput]()

const bashDefaultTimeout = 30 * time.Second

func Bash(input json.RawMessage) (string, error) {
	bashInput := BashInput{}
	err := json.Unmarshal(input, &bashInput)
	if err != nil {
		return "", err
	}
	if bashInput.Cmd == "" {
		return "", fmt.Errorf("invalid input parameters")
	}

	ctx, cancel := context.WithTimeout(context.Background(), bashDefaultTimeout)
	defer cancel()

	start := time.Now()
	cmd := exec.CommandContext(ctx, "/bin/bash", "-c", bashInput.Cmd)
	stdoutBuf := &strings.Builder{}
	stderrBuf := &strings.Builder{}
	cmd.Stdout = stdoutBuf
	cmd.Stderr = stderrBuf

	runErr := cmd.Run()
	durationMs := time.Since(start).Milliseconds()

	exitCode := 0
	if cmd.ProcessState != nil {
		exitCode = cmd.ProcessState.ExitCode()
	}

	result := map[string]any{
		"stdout":      stdoutBuf.String(),
		"stderr":      stderrBuf.String(),
		"exit_code":   exitCode,
		"duration_ms": durationMs,
	}

	// A non-zero exit is a *successful* tool call (model reads stderr
	// and decides). Only exec-time failures (timeout, missing binary)
	// set the error field.
	if runErr != nil {
		if ctx.Err() == context.DeadlineExceeded {
			result["error"] = "command timed out after " + bashDefaultTimeout.String()
			result["timed_out"] = true
		} else if _, ok := runErr.(*exec.ExitError); ok {
			// exit_code captured above.
		} else {
			// Couldn't start the command (e.g. /bin/bash missing).
			result["error"] = runErr.Error()
		}
	}

	encoded, err := json.Marshal(result)
	if err != nil {
		return "", err
	}
	return string(encoded), nil
}

func createNewFile(filePath, content string) (string, error) {
	dir := path.Dir(filePath)
	if dir != "." {
		err := os.MkdirAll(dir, 0755)
		if err != nil {
			return "", fmt.Errorf("failed to create directory: %w", err)
		}
	}

	err := os.WriteFile(filePath, []byte(content), 0644)
	if err != nil {
		return "", fmt.Errorf("failed to create file: %w", err)
	}

	return fmt.Sprintf("Successfully created file %s", filePath), nil
}
