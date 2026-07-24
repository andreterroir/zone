# agent

A small REPL agent that talks to an Anthropic-compatible Messages API and
exposes three tools to the model: `read_file`, `list_files`, `edit_file`,
and `bash`. Two implementations live in this repo:

- `main.go` — the original implementation (Go, two third-party deps:
  `anthropic-sdk-go` + `invopop/jsonschema`).
- `main.zig` — a std-lib-only rewrite in Zig 0.16.0.

## Running

To run the Go implementation with an OpenCode Go Anthropic-compatible model:

```sh
ANTHROPIC_BASE_URL='https://opencode.ai/zen/go' ANTHROPIC_API_KEY='<redacted>' go run main.go
```

To run the Zig implementation with an OpenCode Go Anthropic-compatible model:

```sh
ANTHROPIC_BASE_URL='https://opencode.ai/zen/go' API_KEY='<redacted>' zig run main.zig
```

OpenCode Go endpoints are documented
[here](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/go.mdx#endpoints).

## Configuration

The default endpoint is the OpenCode Zen Go Anthropic-compatible endpoint,
and the default model is `minimax-m3`. Both are overridable via env vars.

| Env var | Required | Default |
|---|---|---|
| `API_KEY` | yes (exits 1 if missing/empty, Zig only) | — |
| `ANTHROPIC_BASE_URL` | no | `https://opencode.ai/zen/go` |
| `ANTHROPIC_API_KEY` | yes (Go only — `API_KEY` is ignored) | — |
| `MODEL` | no (Zig only; the Go version hard-codes `minimax-m3`) | `minimax-m3` |
| `SSL_CERT_FILE` | no (Zig only) | unset — `ca_bundle.rescan()` picks the platform default (only used if the file is set) |

### Zig override example

```sh
ANTHROPIC_BASE_URL=https://other-host   \
MODEL=other-model                       \
API_KEY=sk-...                          \
zig run main.zig
```

## Behavior differences between the two implementations

These are intentional, documented in `main.zig` at the call sites:

| | Go (`main.go`) | Zig (`main.zig`) |
|--|--|--|
| `list_files` depth | Recursive (`filepath.Walk`) | One-level only (also described in the tool description the model sees) |
| Empty user prompt | Sends an empty user message to the model | Re-prompts, sends nothing |
| `edit_file` replace | All occurrences (`strings.Replace(..., -1)`) | All occurrences (single `std.mem.replaceOwned` — already replaces all internally) |
| `read_file` / `edit_file` file size | Unbounded | Capped at 1 MiB |
| HTTP response size | Unbounded | Capped at 1 MiB |
| Exit code on `API_KEY` missing | `0` (Go recovers) | `1` (explicit `std.process.exit(1)`) |
| Dependencies | Two third-party Go modules | None (Zig std-lib only) |
| TLS / CA bundle | `crypto/tls` defaults | `SSL_CERT_FILE` (if set) or `client.ca_bundle.rescan()` (Zig 0.16 doesn't auto-load one); `rescan` is platform-aware (Linux/macOS/Windows/BSD) |
| HTTP compression | n/a | `accept-encoding: identity` forced — `std.http.Client` advertises gzip but doesn't decompress, which would make responses opaque to the JSON parser |
| Tool input parsing strictness | Go's `json.Unmarshal` ignores unknown fields | `parseFromValueLeaky(..., .{ .ignore_unknown_fields = true })` — same as Go |
| Bash signal exit code | `-1` (Go's `cmd.ProcessState.ExitCode()`) | `-1` (matching Go for parity) |
| `bash` `duration_ms` | `time.Since(start).Milliseconds()` | `Io.Clock.awake` start/end `Timestamp.durationTo` / `ns_per_ms` (matching Go) |

## Zig 0.16.0 notes

A few std-lib quirks that the rewrite has to work around (call sites in
`main.zig` are commented with these rationales):

- **All FS ops need an `io: std.Io` parameter.** `openFile`, `close`,
  `reader`, `writer`, `iterate`, `createFile`, `createDirPath`, etc.
  Initialize once in `main` via `Io.Threaded.init` and pass it through
  to every call.
- **`std.http.Client.FetchOptions` has no size-limiting field** in 0.16
  (no `max_append_size`, `max_chunk_size`, or `max_size`). To cap the
  response body you have to drop to the lower-level
  `client.request()` / `req.sendBodyComplete()` /
  `req.receiveHead()` + `response.reader()` API and cap on the reader
  side. `sendMessage` does exactly this.
- **`std.mem.replaceOwned` already replaces all occurrences** internally
  (it delegates to `replace` which loops). The Zig port calls it once
  per `edit_file` invocation, matching the Go version's
  `strings.Replace(..., -1)`.
- **`std.json.Stringify.value(allocator, value, .{}, writer)`** is the
  replacement for the removed top-level `std.json.stringify` helper.
  The allocator is the first argument. `Stringify.valueAlloc` is the
  convenience that allocates a fresh `[]u8` and returns it.
- **`std.process.Environ.getPosix` walks the env block captured at
  startup.** `std.c.getenv` (libc) does NOT work under Zig 0.16's
  standalone runtime because it doesn't populate libc's `environ`
  global. Use `getEnvOr` in `main.zig` for any env access.
- **Privileged HTTP headers** (e.g. `accept-encoding`) are set via the
  structured `RequestOptions.headers` field, not `extra_headers`. The
  `accept-encoding: identity` override is required because
  `std.http.Client` advertises gzip but does not decompress; without
  the override, a gzipped response would be opaque to the JSON parser.

## Out of scope (neither implementation)

- No streaming.
- No conversation history truncation / token counting.
- No retry / backoff.
- No multi-provider support (OpenAI etc.).
- No tests.
- No `build.zig` — running is `zig run main.zig` directly.
- No recursive directory walk for `list_files` in the Zig port.
- No slash commands (`/exit`, etc.).
- No proxy / custom TLS / custom CA bundle configuration beyond
  `SSL_CERT_FILE`.
