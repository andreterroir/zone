# agent

A small REPL agent that talks to an Anthropic-compatible Messages API and
exposes three tools to the model: `read_file`, `list_files`, `edit_file`,
and `bash`. Implemented in Go (`main.go`) using two third-party
dependencies: `anthropic-sdk-go` + `invopop/jsonschema`.

## Running

To run with an OpenCode Go Anthropic-compatible model:

```sh
ANTHROPIC_BASE_URL='https://opencode.ai/zen/go' ANTHROPIC_API_KEY='<redacted>' go run main.go
```

OpenCode Go endpoints are documented
[here](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/go.mdx#endpoints).

### Initial prompt

Anything after the (currently empty) flags is joined with spaces and sent
as the first user message — useful for one-shot scripted invocations.
After that turn the agent falls back to the interactive stdin REPL.

```sh
# Equivalent to typing "summarize this repo" at the first You: prompt,
# then continuing the conversation interactively.
go run main.go summarize this repo
```

Flag parsing uses the stdlib `flag` package, so adding `-f` / `--long-flag`
later is a drop-in change.

## Configuration

The default endpoint is the OpenCode Zen Go Anthropic-compatible endpoint,
and the default model is `minimax-m3`. Both are overridable via env vars.

`ANTHROPIC_BASE_URL` defaults to the OpenCode Zen Go endpoint when
unset; a user-supplied value overrides it.

| Env var | Required | Default |
|---|---|---|
| `ANTHROPIC_BASE_URL` | no | `https://opencode.ai/zen/go` |
| `ANTHROPIC_API_KEY` | yes | — |

The default model is `minimax-m3`, hard-coded in `main.go`.

## System prompt

Every turn's system prompt is: `systemPrompt`, then
`/home/andrew/.agents/AGENTS.md` (if readable) under
`# Agent Instructions`, then `/home/andrew/.agents/AGENTS.local.md`
(if readable) under `# Machine Specific Agent Instructions`. Missing
files are skipped silently.

## Streaming

The Go implementation uses `client.Messages.NewStreaming` (SSE). Text
tokens print to stdout as they arrive; tool-use blocks are accumulated and
only dispatched after `content_block_stop`. `MessageParam` is built
directly from stream events (no `Message.ToParam()` round-trip).

## Out of scope

- No conversation history truncation / token counting.
- No retry / backoff.
- No multi-provider support (OpenAI etc.).
- No tests.
- No slash commands (`/exit`, etc.).
- No proxy / custom TLS / custom CA bundle configuration.
