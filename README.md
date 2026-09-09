# agent

A small REPL agent that talks to an Anthropic-compatible Messages API and
exposes four tools to the model: `read_file`, `list_files`, `edit_file`,
`bash`. Implemented in Go (`main.go`).

## Build / install

```sh
make           # build ./agent
make install   # install to ~/bin/zone
```

## Run

```sh
ANTHROPIC_BASE_URL='https://opencode.ai/zen/go' ANTHROPIC_API_KEY='<redacted>' go run main.go
```

Positional arguments are joined with spaces and sent as the first user
message; subsequent turns read from stdin. Flag parsing uses the stdlib
`flag` package, so adding `-f` / `--long-flag` later is a drop-in change.

```sh
go run main.go summarize this repo   # one-shot seed + interactive REPL
```

## Configuration

| Env var | Required | Default |
|---|---|---|
| `ANTHROPIC_BASE_URL` | no | `https://opencode.ai/zen/go` |
| `ANTHROPIC_API_KEY` | yes | — |

The default model is `minimax-m3`, hard-coded in `main.go`. Every request
sends an `x-opencode-session` header (per-process nanosecond timestamp)
and `User-Agent: zone/0.1`.

## System prompt

Every turn's system prompt is: `systemPrompt`, then
`~/.agents/AGENTS.md` (if readable) under `# Agent Instructions`, then
`~/.agents/AGENTS.local.md` (if readable) under `# Machine Specific
Agent Instructions`, then the repository's `<root>/AGENTS.md` (if the
cwd is inside a git repo and the file is readable) under `# Repository
Agent Instructions`. Missing files and a missing git repository are
skipped silently. The repo root is resolved with
`git rev-parse --show-toplevel`.
