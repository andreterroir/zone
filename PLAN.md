# Plan: rewrite `main.go` in Zig 0.16.0

## Source

The current `main.go` is a small REPL-style agent that:

- talks to the OpenCode Anthropic-compatible endpoint with the `minimax-m3` model,
- reads a user message from stdin,
- sends it to the model together with three tool definitions (`read_file`, `list_files`, `edit_file`),
- iterates: if the model returns tool_use blocks, runs the tool, feeds the result back, and loops; otherwise prompts for the next user turn,
- colorizes stdout with raw ANSI escape codes (`\u001b[94m` / `\u001b[92m` / `\u001b[93m` / `\u001b[0m`).

It depends on:

- `github.com/anthropics/anthropic-sdk-go` — Anthropic Messages API client,
- `github.com/invopop/jsonschema` — JSON schema generation from Go structs.

The rewrite drops both dependencies and uses only the Zig 0.16.0 standard library.

## Decisions (confirmed)

1. **API endpoint & model.** Default to the OpenCode Anthropic-compatible endpoint and the `minimax-m3` model. Both are overridable via env vars:
   - `ANTHROPIC_BASE_URL` — overrides the base URL. Default: `https://opencode.ai/zen/go`.
   - `MODEL` — overrides the model name. Default: `minimax-m3`.
   - `API_KEY` — always read from the environment; the program exits with a clear error if it is missing or empty. (No hard-coded key, no fallback.)
2. **HTTP client.** Use `std.http.Client`. Lean on the standard library where it makes sense (no manual HTTP framing, no third-party HTTP).
3. **JSON handling.** Go with option (b): parse each response into an arena-allocated `std.json.Value` tree and extract the few fields we care about (text blocks, tool_use id/name/input) with small helper functions. Verbose but std-lib-only and explicit.
4. **JSON Schemas.** Inline as raw Zig string literals in `main.zig` for the first version. No code generation.
5. **Tool dispatch.** Go with (c): a `[]const ToolDef` array indexed by name lookup. Each tool has its own input struct, parsed from `std.json.Value` inside the tool function. Function pointers are used to point at the implementation.
6. **File layout.** Single `main.zig` at the repo root, no `src/` directory, no `build.zig` for now. Schemas inlined as string constants at the top of the file.
7. **ANSI colors.** Raw escape codes in a small const block at the top of the file (e.g. `const c_you = "\u001b[94m"`).

## Design

### High-level flow

`main.zig` contains:

- `max_response_bytes` and `max_file_bytes` constants (both 1 MiB).
- ANSI color constants.
- A `getEnvOr` helper that defaults on missing/invalid env vars.
- The three tool input structs and their static JSON schemas (as raw `\\` string literals, one line each).
- A `ToolDef` struct bundling `name`, `description`, `schema` (string), and a `ToolFn` function pointer.
- A `const tools = [_]ToolDef{ ... };` array plus a `findTool(name)` linear search.
- Tool implementations: `toolReadFile`, `toolListFiles`, `toolEditFile`, `createNewFile`. Each takes `(value: std.json.Value, arena)` and returns `![]const u8`.
- An API helper:
  - `sendMessage` — builds the body, POSTs via `std.http.Client` (using `request` + `receiveHead` to allow body size capping), reads the body into an arena buffer (capped at `max_response_bytes` using a limited reader loop), and returns a `std.json.Parsed(std.json.Value)`.
  - `buildRequestBody` — emits the JSON envelope with `std.json.Stringify.value(arena, value, .{}, writer)` writing into an `ArrayList(u8)`. Note: `input_schema` is parsed from the schema string and inlined as a `std.json.Value` object (the API requires an object, not a string).
- A response handler (`handleResponse`) that walks the response `content` array, prints text blocks, and returns a `Turn { text, tool_calls }`.
- Conversation helpers: `pushUserText`, `pushAssistant`, `pushToolResults` — each appends a `std.json.Value` to the `Conversation` (which is `std.ArrayListUnmanaged(std.json.Value)`).
- The agent `runAgent` loop (mirrors the Go `Run`):
  - print prompt, read a line from stdin, skip empty lines (re-prompt), break on EOF,
  - push a user message,
  - call the API, print any text, push the assistant message,
  - if no tool calls: loop and prompt again,
  - otherwise: run each tool, build a `tool_result` block per call, push them as a user message, loop.
- `main` — read `API_KEY` (exit 1 if missing/empty), read `ANTHROPIC_BASE_URL` / `MODEL` with defaults, kick off `runAgent`.

### Tool input structs

```zig
const ReadFileInput  = struct { path: []const u8 };
const ListFilesInput = struct { path: ?[]const u8 = null };
const EditFileInput  = struct { path: []const u8, old_str: []const u8, new_str: []const u8 };
```

### Static schemas

Roughly:

```zig
const read_file_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"…"}},"required":["path"],"additionalProperties":false}
;

const list_files_schema =
    \\{"type":"object","properties":{"path":{"type":["string","null"],"description":"…"}},"required":[],"additionalProperties":false}
;

const edit_file_schema =
    \\{"type":"object","properties":{
    \\  "path":{"type":"string","description":"…"},
    \\  "old_str":{"type":"string","description":"…"},
    \\  "new_str":{"type":"string","description":"…"}
    \\},"required":["path","old_str","new_str"],"additionalProperties":false}
;
```

(All on a single line each — the line continuations above are only for readability in this plan. The `list_files` schema's `path` is just `"type":"string"` (no `"null"`) because the input struct uses `?[]const u8 = null` and `parseFromValueLeaky` treats `null` as a present-but-null value; the field is optional by virtue of being absent from `required`.)

### Dispatch

A `const tools = [_]ToolDef{ ... };` array, and a small helper that linear-searches by name (same shape as the Go version):

```zig
fn findTool(name: []const u8) ?ToolDef { … }
```

Each tool function takes `(value: std.json.Value, arena: std.mem.Allocator) anyerror![]const u8` and:

1. Parses `value` into its input struct with `std.json.parseFromValueLeaky`.
2. Does the file operation.
3. Returns a string response (JSON array of strings for `list_files`, plain text otherwise).

For `list_files`, the response is a JSON array of strings built by hand with `std.json.stringify` + manual commas. For `read_file` and `edit_file`, plain text. `edit_file` also performs `createNewFile` when the file doesn't exist and `old_str` is empty.

`edit_file` replaces *all* occurrences of `old_str` with `new_str` (matches the Go `strings.Replace(..., -1)`), implemented as a loop of `std.mem.replaceOwned` calls.

For `list_files`, note this is a *shallow* directory listing (one level) — the Go version's `filepath.Walk` was a recursive walk, so the Zig version is a behavior change. The plan: revisit if a recursive listing is needed (it isn't for typical REPL use).

### Error handling

- `main` uses `std.process.exit(1)` on the missing/empty `API_KEY` case, with a message printed to stderr.
- Tool functions return `anyerror![]const u8`. Errors propagate up; the agent loop catches them and stores `{ .content = @errorName(err), .is_error = true }` in the corresponding `ToolResult`. The Anthropic API receives a `tool_result` block with `"is_error": true` (mirroring `NewToolResultBlock(id, err.Error(), true)`).
- HTTP / JSON errors from `sendMessage` abort the loop with a printed error and the function returns (the arena is freed by `main`'s defer).
- The HTTP layer uses `client.fetch` with a `max_append_size` cap to bound response body size. **TODO**: confirm the exact `FetchOptions` field name in Zig 0.16.0 — it has been renamed across releases (`max_append_size` / `max_chunk_size` / `max_size`). If the field is renamed, the cap is silently dropped; the bound is still enforced by the `readAllArrayList(&body_buf, max_response_bytes)` call that follows.

## Open questions

- ~~**Stdin EOF behaviour.**~~ Resolved: break the loop on EOF; on an empty line, re-prompt without sending a message.
- **Slash command for quit.** Not present in the Go version. Not adding it.
- ~~**Streaming.**~~ Resolved: non-streaming, single request per turn.
- ~~**HTTP body size.**~~ Resolved: 1 MiB response cap (`max_append_size` on the `fetch` call + `readAllArrayList` cap); 1 MiB per-file cap for `read_file` / `edit_file`. **TODO**: confirm the exact `FetchOptions` field name in 0.16.0.
- ~~**TLS.**~~ Resolved: handled by `std.http.Client` (no extra config).
- **list_files depth.** Currently a shallow one-level listing. Go version does a recursive walk. Decide later if the recursive behaviour is needed.
- **Build verification.** No Zig toolchain is wired into this environment. The code is written against the 0.16.0 std-lib API. Likely-compile-fixable issues, in rough order of probability:
  1. `std.http.Client.FetchOptions.max_append_size` may be named differently (`max_chunk_size`, `max_size`, or absent) in 0.16.0 — fall back to just the `readAllArrayList` cap.
  2. `std.json.Value.fromDynamic` inference on anonymous structs may need an explicit `std.json.Dynamic` wrapper, or the structs may need `@TypeOf` adjustments.
  3. `std.mem.replaceOwned` signature may want `gpa` style allocator in some 0.16 builds; the version used here (`arena: std.mem.Allocator`) should be fine.
  4. `std.fs.File.writer()` may be `std.fs.File.writer()` (file-level) vs. needing a buffered writer. The current code uses `std.fs.File.stderr().writer()` which is correct in 0.16.

## Out of scope (for this version)

- No streaming.
- No conversation history truncation / token counting.
- No retry/backoff.
- No multi-provider support (OpenAI etc.).
- No tests.
- No `build.zig` — running is `zig run main.zig` directly.
- No recursive directory walk for `list_files`.
- No slash commands (`/exit`, etc.).
- No proxy / custom TLS / custom CA bundle configuration.

## File to be produced

- `main.zig` — everything (constants, schemas, structs, API helper, tool functions, agent loop, `main`).
- `PLAN.md` — this plan.

No other files will be created.

## How to run

```sh
API_KEY=sk-...  zig run main.zig
# or, with overrides:
ANTHROPIC_BASE_URL=https://other-host   \
MODEL=other-model                       \
API_KEY=sk-...                          \
zig run main.zig
```

## Known behavior differences from the Go version

| | Go (`main.go`) | Zig (`main.zig`) |
|--|--|--|
| `list_files` depth | Recursive (`filepath.Walk`) | One-level only |
| Empty user prompt | Sends an empty user message to the model | Re-prompts, sends nothing |
| `edit_file` replace | All occurrences (`strings.Replace(..., -1)`) | All occurrences (loop of `replaceOwned`) |
| `read_file` / `edit_file` file size | Unbounded | Capped at 1 MiB |
| HTTP response size | Unbounded | Capped at 1 MiB |
| Exit code on `API_KEY` missing | `0` (Go recovers) | `1` (explicit `std.process.exit(1)`) |
| Dependencies | Two third-party Go modules | None (Zig std-lib only) |





