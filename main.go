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

const systemPrompt = "You are a coding agent - start from exploring the current directory"

// User-global AGENTS.md (Claude Code / friends use this path by convention).
const globalAgentsPath = "/home/andrew/.agents/AGENTS.md"

// Sibling the global AGENTS.md instructs the agent to also read.
const globalAgentsLocalPath = "/home/andrew/.agents/AGENTS.local.md"

// loadSystemPrompt returns: base prompt, then AGENTS.md (if readable)
// under "# Agent Instructions", then AGENTS.local.md (if readable)
// under "# Machine Specific Agent Instructions". Missing files are
// silently skipped.
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

	return blocks
}

func main() {
	// Parse flags against a local FlagSet so we don't mutate the global
	// `flag.CommandLine`. Any positional args after the flags form the
	// free-form initial prompt, joined with spaces. ExitOnError ensures
	// unknown flags print usage and exit non-zero rather than being
	// silently absorbed into the initial prompt. Defining flags here
	// (e.g. `fs.StringVar(...)`) is the only change needed when adding
	// `-f` / `--long-flag` later.
	fs := flag.NewFlagSet(os.Args[0], flag.ExitOnError)
	fs.Parse(os.Args[1:])
	// Whitespace-only arguments (e.g. a stray trailing space that survived
	// shell tokenization) collapse to the empty string here, so they're
	// treated identically to "no initial prompt supplied" — i.e. the
	// loop falls back to interactive stdin rather than sending a
	// whitespace-only first turn.
	initialPrompt := strings.TrimSpace(strings.Join(fs.Args(), " "))

	// Default to the OpenCode Zen Go endpoint when ANTHROPIC_BASE_URL
	// is unset; otherwise let the user's value win.
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
	err := agent.Run(context.TODO()) // context for cancellation/timeout control
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

	// If an initial prompt was supplied on the command line, seed the
	// conversation with it and skip the first stdin prompt. After that
	// turn the loop falls back to the normal interactive flow.
	readUserInput := true
	if a.initialPrompt != "" {
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
				// Streaming has already printed the text and a trailing
				// newline in `runInference`. Nothing to do here.
				_ = content.OfText.Text
			case content.OfToolUse != nil:
				tu := content.OfToolUse
				// `ToolUseBlockParam.Input` is typed `any`; in
				// `runInference` we always store a `json.RawMessage`
				// (the buffered concatenation of `input_json_delta`
				// fragments), so this assertion is guaranteed to hold.
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

	// Open the stream. The SDK already appends `stream: true` internally
	// (see message.go:NewStreaming).
	stream := a.client.Messages.NewStreaming(ctx, anthropic.MessageNewParams{
		Model:     "minimax-m3",
		MaxTokens: 10000,
		System:    loadSystemPrompt(),
		Messages:  conversation,
		Tools:     anthropicTools,
	})
	defer stream.Close()

	// We assemble an `anthropic.MessageParam` directly from the stream
	// instead of building a `Message` and calling `.ToParam()`. Two
	// reasons:
	//   1. `ContentBlockUnion` (the response shape) is a flat struct with
	//      no exported `Of*` accessors; mutating its `Text` field directly
	//      works, but `AsText()`/`AsToolUse()` round-trip through the
	//      fixed `JSON.raw` snapshot and discard streamed edits.
	//   2. `MessageParam`'s `Content` is already a `[]ContentBlockParamUnion`
	//      with tagged-pointer `OfText`/`OfToolUse` fields — which is
	//      exactly what the `Run` loop in this file iterates, and what
	//      the next request round-trips as conversation history.
	// NOTE: Currently we defer all tool execution until after the
	// full stream returns. An optimization would be to execute each
	// tool as soon as its content_block_stop arrives (i.e., when the
	// tool_use input is fully assembled). This would reduce latency
	// for independent tool calls, but requires careful handling of
	// inter-dependent tool chains and partial response error
	// recovery.
	var blocks []anthropic.ContentBlockParamUnion

	// For tool_use blocks, the streamed `input_json_delta` events carry
	// partial JSON fragments. We buffer them per-block-index and
	// materialize a single `json.RawMessage` at `content_block_stop`.
	type toolBuilder struct {
		id, name string
		inputBuf bytes.Buffer
	}
	builders := map[int64]*toolBuilder{}

	// Track whether we've printed the "AI: " prefix yet for this turn so
	// that streamed text appears as one continuous line ("AI: hello there")
	// instead of being prefixed on every delta.
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
			// Nothing to capture — `message_start.Message` is the response
			// shape; we don't need its fields here. Stop reason lands in
			// `message_delta` and isn't surfaced to the conversation.
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
			// Carries stop_reason and cumulative usage. Nothing in this
			// agent surfaces those, but we consume the event so the loop
			// stays symmetric with the wire protocol.
			_ = ev.Delta
			_ = ev.Usage
		case "message_stop":
			// Final event; loop terminates on the next Next().
		}
	}

	if err := stream.Err(); err != nil {
		return anthropic.MessageParam{}, err
	}

	// If any text streamed this turn, terminate with a newline so the next
	// `You:` prompt lands on its own line. (Non-streaming printed `\n`
	// once per text block; streaming prints once at end-of-text.) If only
	// tool_use blocks came back, we still want a newline so any
	// `tool: ...` lines that follow aren't glued to a prior prompt.
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
	return string(result), nil // json.Marshal returns []byte
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
	// replace all occurrences
	const replaceAll = -1
	newContent := strings.Replace(oldContent, editFileInput.OldStr, editFileInput.NewStr, replaceAll)

	// empty oldStr means new file creation; skip equality check to avoid false "not found" error
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

	// Distinguish: a non-zero exit is a successful *tool call* (the command ran;
	// the model should see stderr and decide what to do). A real execution
	// failure (command missing, timeout, etc.) is an is_error=true result.
	if runErr != nil {
		// context.DeadlineExceeded is the timeout case.
		if ctx.Err() == context.DeadlineExceeded {
			result["error"] = "command timed out after " + bashDefaultTimeout.String()
			result["timed_out"] = true
		} else if ee, ok := runErr.(*exec.ExitError); ok {
			// Non-zero exit. Already captured exit_code above; no extra error field.
			_ = ee
		} else {
			// Couldn't even start the command (e.g. /bin/bash missing).
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
			// %w wraps the error for proper error chain unwrapping
			return "", fmt.Errorf("failed to create directory: %w", err)
		}
	}

	err := os.WriteFile(filePath, []byte(content), 0644)
	if err != nil {
		return "", fmt.Errorf("failed to create file: %w", err)
	}

	return fmt.Sprintf("Successfully created file %s", filePath), nil
}
