const std = @import("std");
const Io = std.Io;

// ---------------------------------------------------------------------------
// Configuration constants
// ---------------------------------------------------------------------------

/// Upper bound on a single API response body (1 MiB). See README.md.
const max_response_bytes: usize = 1 * 1024 * 1024;

/// Upper bound on a single file read/edit (1 MiB). See README.md.
const max_file_bytes: usize = 1 * 1024 * 1024;

/// Default base URL — the OpenCode Anthropic-compatible endpoint.
/// Note: `std.http.Client` is given just the host root, but the Messages
/// API lives at `${base}/v1/messages`. We append `/v1/messages` in
/// `sendMessage` so this constant stays a clean host.
/// Overridable via `ANTHROPIC_BASE_URL`.
const default_base_url: []const u8 = "https://opencode.ai/zen/go";

/// Default model name. Overridable via `MODEL`.
const default_model: []const u8 = "minimax-m3";

/// Hard-coded path to the shell, matching the Go version. The Go version uses
/// `/bin/bash` directly. (Cross-platform shimming is out of scope.)
const bash_path: []const u8 = "/bin/bash";

// ---------------------------------------------------------------------------
// ANSI color helpers
// ---------------------------------------------------------------------------

const c_you: []const u8 = "\x1b[94m";
const c_ai: []const u8 = "\x1b[93m";
const c_tool: []const u8 = "\x1b[92m";
const c_reset: []const u8 = "\x1b[0m";

// ---------------------------------------------------------------------------
// Environment helpers
// ---------------------------------------------------------------------------

/// `getEnvOr` — return the value of env var `name`, or `default` if the
/// variable is missing or empty. Uses `std.process.Environ.getPosix`
/// (Zig 0.16) which walks the env block captured by the runtime at
/// startup — `std.c.getenv` no longer works because Zig 0.16's
/// standalone runtime does not populate the libc `environ` global.
fn getEnvOr(environ: std.process.Environ, name: []const u8, default: []const u8) []const u8 {
    const value = std.process.Environ.getPosix(environ, name) orelse return default;
    if (value.len == 0) return default;
    return value;
}

// ---------------------------------------------------------------------------
// Tool input structs and inline JSON schemas
// ---------------------------------------------------------------------------

const ReadFileInput = struct {
    path: []const u8,
};

const ListFilesInput = struct {
    /// Optional relative path. `parseFromValueLeaky` treats a JSON `null` as
    /// a present-but-null value, so the field is optional by virtue of being
    /// absent from `required` in the schema.
    path: ?[]const u8 = null,
};

const EditFileInput = struct {
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
};

const BashInput = struct {
    cmd: []const u8,
};

const read_file_schema: []const u8 =
    \\{"type":"object","properties":{"path":{"type":"string","description":"The relative path of a file in the working directory."}},"required":["path"],"additionalProperties":false}
;

const list_files_schema: []const u8 =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Optional relative path to list files from. Defaults to current directory if not provided."}},"required":[],"additionalProperties":false}
;

const edit_file_schema: []const u8 =
    \\{"type":"object","properties":{"path":{"type":"string","description":"The path to the file"},"old_str":{"type":"string","description":"Text to search for - must match exactly and must only have one match exactly"},"new_str":{"type":"string","description":"Text to replace old_str with"}},"required":["path","old_str","new_str"],"additionalProperties":false}
;

const bash_schema: []const u8 =
    \\{"type":"object","properties":{"cmd":{"type":"string","description":"The bash command to execute. Runs via /bin/bash -c with a 30s default timeout. Output is returned as a JSON object with stdout, stderr, exit_code, and duration_ms fields."}},"required":["cmd"],"additionalProperties":false}
;

// ---------------------------------------------------------------------------
// Tool definition / dispatch
// ---------------------------------------------------------------------------

const ToolFn = *const fn (
    value: std.json.Value,
    arena: std.mem.Allocator,
    io: Io,
) anyerror![]const u8;

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
    func: ToolFn,
};

const tools: []const ToolDef = &.{
    .{
        .name = "read_file",
        .description = "Read the contents of a given relative file path. use this when you want to see what's inside a file. Do not use this with directory names.",
        .schema = read_file_schema,
        .func = toolReadFile,
    },
    .{
        .name = "list_files",
        .description = "List files and directories at a given path. If no path is provided, lists files in the current directory. One level deep only.",
        .schema = list_files_schema,
        .func = toolListFiles,
    },
    .{
        .name = "edit_file",
        .description =
        \\Make edits to a text file.
        \\
        \\Replaces 'old_str' with 'new_str' in the given file. 'old_str' and 'new_str' MUST be different from each other.
        \\
        \\If the file specified with path doesn't exist, it will be created.
        ,
        .schema = edit_file_schema,
        .func = toolEditFile,
    },
    .{
        .name = "bash",
        .description = "Execute a single bash command and return its output. Runs the command via `/bin/bash -c <cmd>` in the current working directory with the inherited environment. Output is returned as a JSON object: {\"stdout\", \"stderr\", \"exit_code\", \"duration_ms\"}. Non-zero exit codes are reported as successful tool results (is_error=false) so the model can see stderr and react; only execution failures (command not found, timeout) are returned as is_error=true.",
        .schema = bash_schema,
        .func = toolBash,
    },
};

fn findTool(name: []const u8) ?ToolDef {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

/// Capped version of `readAllArrayList` — reads until EOF or until `limit`
/// bytes have been consumed. Zig 0.16's `std.Io` doesn't expose a
/// public `readAllArrayList` helper, so we roll one. The returned
/// slice is allocated by `gpa`; the caller owns and must free it.
fn readCapped(gpa: std.mem.Allocator, reader: *Io.Reader, limit: usize) ![]u8 {
    var buf: std.array_list.Managed(u8) = std.array_list.Managed(u8).init(gpa);
    defer buf.deinit();
    try buf.ensureTotalCapacity(@min(limit, 4096));

    // Read in chunks. We always pass the same fixed scratch buffer;
    // `readSliceShort` returns the number of bytes consumed.
    var scratch: [4096]u8 = undefined;
    while (buf.items.len < limit) {
        const want = @min(limit - buf.items.len, scratch.len);
        const slice = scratch[0..want];
        const got = reader.readSliceShort(slice) catch return error.ReadFailed;
        if (got == 0) break;
        try buf.appendSlice(slice[0..got]);
    }
    return buf.toOwnedSlice();
}

/// `read_file` — bounded read of a file relative to cwd. Capped at
/// `max_file_bytes` (1 MiB) — see README.md.
fn toolReadFile(
    value: std.json.Value,
    arena: std.mem.Allocator,
    io: Io,
) anyerror![]const u8 {
    const input = try std.json.parseFromValueLeaky(ReadFileInput, arena, value, .{ .ignore_unknown_fields = true });

    const dir = Io.Dir.cwd();
    var file = dir.openFile(io, input.path, .{}) catch |err| return err;
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    // `readCapped` allocates with `arena`; arena lifetime is the whole
    // session, so the returned slice is fine.
    const raw = try readCapped(arena, &reader.interface, max_file_bytes);
    return raw;
}

/// `list_files` — shallow directory listing. Cwd if `path` is missing/empty.
fn toolListFiles(
    value: std.json.Value,
    arena: std.mem.Allocator,
    io: Io,
) anyerror![]const u8 {
    const input = try std.json.parseFromValueLeaky(ListFilesInput, arena, value, .{ .ignore_unknown_fields = true });

    const dir_path = input.path orelse ".";
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    // One-level listing using the Io.Dir.Iterator. We accumulate names and
    // skip "." / "..". The Go version recurses with `filepath.Walk`; the
    // Zig port is intentionally shallow (see README.md "Behavior
    // differences").
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(arena);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        // Duplicate into the arena so the slice outlives the iterator
        // buffer.
        try names.append(arena, try arena.dupe(u8, entry.name));
    }

    // Hand the list off to `Stringify.valueAlloc`, which knows how to
    // emit a JSON array of strings — same shape as the Go version's
    // `json.Marshal([]string{...})`.
    return try std.json.Stringify.valueAlloc(arena, names.items, .{});
}

/// Edit-file helper: create a brand-new file (and any missing parent
/// directories) with `content`, returning a "Successfully created file ..."
/// message. Mirrors the Go version's `createNewFile` helper.
fn createNewFile(
    arena: std.mem.Allocator,
    io: Io,
    file_path: []const u8,
    content: []const u8,
) ![]const u8 {
    // Recreate parent directory if needed. `Io.Dir.createDirPath` is a
    // stdlib primitive that walks the path components and creates each
    // missing directory.
    if (std.fs.path.dirname(file_path)) |parent| {
        if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
            try Io.Dir.cwd().createDirPath(io, parent);
        }
    }
    const dir = Io.Dir.cwd();
    const mode: Io.File.CreateFlags = .{ .read = true, .truncate = true };
    var file = try dir.createFile(io, file_path, mode);
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    return std.fmt.allocPrint(arena, "Successfully created file {s}", .{file_path});
}

/// `edit_file` — replace `old_str` with `new_str` in `path`. Creates the
/// file if it doesn't exist and `old_str` is empty. Replaces *all*
/// occurrences. Returns the string "OK" on success.
fn toolEditFile(
    value: std.json.Value,
    arena: std.mem.Allocator,
    io: Io,
) anyerror![]const u8 {
    const input = try std.json.parseFromValueLeaky(EditFileInput, arena, value, .{ .ignore_unknown_fields = true });

    if (input.path.len == 0 or std.mem.eql(u8, input.old_str, input.new_str)) {
        return error.InvalidInputParameters;
    }

    const dir = Io.Dir.cwd();
    const file = dir.openFile(io, input.path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (input.old_str.len == 0) {
                return createNewFile(arena, io, input.path, input.new_str);
            }
            return err;
        },
        else => return err,
    };
    defer file.close(io);

    // Read up to `max_file_bytes` so the whole replace operates in memory.
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const old_content = try readCapped(arena, &reader.interface, max_file_bytes);

    // `std.mem.replaceOwned` already replaces all occurrences internally
    // (it delegates to `replace` which loops), so this is just one call
    // — matching the Go version's `strings.Replace(..., -1)`.
    const new_content = try std.mem.replaceOwned(
        u8,
        arena,
        old_content,
        input.old_str,
        input.new_str,
    );

    if (std.mem.eql(u8, old_content, new_content) and input.old_str.len > 0) {
        return error.OldStrNotFound;
    }

    var out = try dir.createFile(io, input.path, .{ .read = true, .truncate = true });
    defer out.close(io);
    try out.writeStreamingAll(io, new_content);

    return "OK";
}

/// `bash` — run a single command via `/bin/bash -c <cmd>`. Mirrors the Go
/// version: stdin is ignored, stdout/stderr are captured, the result is a
/// JSON object `{stdout, stderr, exit_code, duration_ms}`. A non-zero
/// exit is a successful *tool* call; only timeout/spawn failures are
/// `is_error`.
fn toolBash(
    value: std.json.Value,
    arena: std.mem.Allocator,
    io: Io,
) anyerror![]const u8 {
    const input = try std.json.parseFromValueLeaky(BashInput, arena, value, .{ .ignore_unknown_fields = true });
    if (input.cmd.len == 0) return error.InvalidInputParameters;

    const argv = [_][]const u8{ bash_path, "-c", input.cmd };
    const start_ts = Io.Clock.awake.now(io);
    const result = std.process.run(std.heap.page_allocator, io, .{
        .argv = &argv,
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = Io.Duration.fromSeconds(30),
        } },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch |err| return err;
    const duration_ms: i64 = @intCast(@divFloor(
        start_ts.durationTo(Io.Clock.awake.now(io)).nanoseconds,
        std.time.ns_per_ms,
    ));

    // `RunResult.term` is a `Child.Term` discriminated union. Go's
    // `cmd.ProcessState.ExitCode()` returns -1 for signal-killed,
    // stopped, or unknown children, so we mirror that for parity.
    const exit_code: i64 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => -1,
    };

    const stdout = result.stdout;
    const stderr = result.stderr;
    defer {
        std.heap.page_allocator.free(stdout);
        std.heap.page_allocator.free(stderr);
    }

    return try std.json.Stringify.valueAlloc(arena, BashResult{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
        .duration_ms = duration_ms,
    }, .{});
}

const BashResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i64,
    duration_ms: i64,
};

// ---------------------------------------------------------------------------
// Anthropic-compatible Messages API
// ---------------------------------------------------------------------------

const ContentBlockParam = union(enum) {
    text: TextBlock,
    tool_use: ToolUseBlock,
    tool_result: ToolResultBlock,

    pub const TextBlock = struct {
        type: []const u8 = "text",
        text: []const u8,
    };

    pub const ToolUseBlock = struct {
        type: []const u8 = "tool_use",
        id: []const u8,
        name: []const u8,
        input: std.json.Value,
    };

    pub const ToolResultBlock = struct {
        type: []const u8 = "tool_result",
        tool_use_id: []const u8,
        content: []const u8,
        is_error: bool = false,
    };

    /// Emit `{"type":"<tag>", ...payload}` directly from the union tag.
    /// Saves a manual `ObjectMap` per content block in `buildRequestBody`.
    pub fn jsonStringify(self: ContentBlockParam, jws: anytype) !void {
        switch (self) {
            .text => |t| try jws.write(t),
            .tool_use => |t| try jws.write(t),
            .tool_result => |t| try jws.write(t),
        }
    }
};

const MessageParam = struct {
    role: []const u8,
    content: []const ContentBlockParam,
};

const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
};

const Request = struct {
    model: []const u8,
    max_tokens: u64 = 10000,
    messages: []const MessageParam,
    tools: []const Tool,
};

/// Parsed shape of a single `content` block in a model response.
const ResponseContent = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    input: std.json.Value = .null,
};

const ParsedResponse = struct {
    text_blocks: []const []const u8,
    tool_calls: []const ResponseContent,
};

/// Build the request envelope for one API call. Returns a fresh
/// `[]u8` allocated by `arena` containing the JSON-encoded body.
/// Sub-values (`input_schema` parsed objects, etc.) are kept alive by
/// the arena for the duration of the request.
fn buildRequestBody(
    arena: std.mem.Allocator,
    model: []const u8,
    messages: []const MessageParam,
    tool_defs: []const ToolDef,
) ![]u8 {
    var tools_arr: std.ArrayList(Tool) = .empty;
    defer tools_arr.deinit(arena);
    for (tool_defs) |t| {
        // Parse the schema into the same arena so the interned strings
        // live as long as the request.
        const input_schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, t.schema, .{});
        try tools_arr.append(arena, .{
            .name = t.name,
            .description = t.description,
            .input_schema = input_schema,
        });
    }

    const request: Request = .{
        .model = model,
        .messages = messages,
        .tools = tools_arr.items,
    };
    return try std.json.Stringify.valueAlloc(arena, request, .{});
}

/// Send one Messages API request and return the parsed response. The
/// response is a `std.json.Value` tree; the caller is responsible for
/// walking it.
fn sendMessage(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    extra_headers: []const std.http.Header,
    base_url: []const u8,
    body_bytes: []const u8,
) !std.json.Value {
    const uri = blk: {
        // The Anthropic Messages API lives at `${base_url}/v1/messages`.
        // Some hosts (e.g. OpenCode's `/zen/go`) already include a
        // versioned path, and the user-provided `ANTHROPIC_BASE_URL`
        // may already end with `/v1` or `/v1/messages`. We naively
        // append `/v1/messages`; if a user wants a different path,
        // they can override `API_PATH` (or just supply the full URL).
        const full_path = std.fmt.allocPrint(arena, "{s}/v1/messages", .{base_url}) catch {
            return error.OutOfMemory;
        };
        break :blk std.Uri.parse(full_path) catch |err| {
            std.log.err("invalid ANTHROPIC_BASE_URL {s}: {t}", .{ base_url, err });
            return err;
        };
    };

    // Build the request and send the body in one call. `sendBodyComplete`
    // sets up content-length and flushes; we don't need to manage the
    // BodyWriter ourselves.
    //
    // `headers.accept_encoding = .override("identity")` opts out of
    // gzip — `std.http.Client` in Zig 0.16 advertises gzip by default
    // and does *not* auto-decompress, so a gzipped response would be
    // opaque to our JSON parser. The Anthropic SDK does the same.
    var req = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .handle_continue = true,
        .extra_headers = extra_headers,
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();
    // `sendBodyComplete` takes `[]u8` (mutable) for the body because
    // the BodyWriter updates the end pointer internally. The body lives
    // in arena-allocated storage, which is mutable in practice; the
    // `[]const u8` type from `Stringify.valueAlloc` is overly strict.
    try req.sendBodyComplete(@constCast(body_bytes));

    // The HTTP response is the only place we need a 1 MiB cap. We use the
    // `receiveHead` + bounded body read pattern: Zig 0.16's
    // `FetchOptions` has no size-limiting field, so we cap on the
    // reader side.
    var response = try req.receiveHead(&.{});
    const status_class = response.head.status.class();
    if (status_class != .success) {
        std.log.err("API returned status {d} {s}", .{
            @intFromEnum(response.head.status),
            response.head.reason,
        });
        return error.ApiError;
    }

    var transfer: [4096]u8 = undefined;
    const reader = response.reader(&transfer);
    // `readCapped` allocates with `arena`; the slice is then parsed
    // into the same arena, so the raw buffer is freed after parsing.
    const raw = try readCapped(std.heap.page_allocator, reader, max_response_bytes);
    defer std.heap.page_allocator.free(raw);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch |err| {
        std.log.err("JSON parse failed ({t}); raw body ({d} bytes): {s}", .{ err, raw.len, raw });
        return error.SyntaxError;
    };
    return parsed;
}

/// Walk the response's `content` array and split it into text blocks and
/// tool_use blocks. Mirrors the Go version's loop over `message.Content`.
fn handleResponse(arena: std.mem.Allocator, response: std.json.Value) !ParsedResponse {
    const content_arr = switch (response) {
        .object => |o| o.get("content") orelse .null,
        else => .null,
    };
    const items = switch (content_arr) {
        .array => |a| a.items,
        else => &[_]std.json.Value{},
    };

    var text_blocks: std.array_list.Managed([]const u8) = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer text_blocks.deinit();
    var tool_calls: std.array_list.Managed(ResponseContent) = std.array_list.Managed(ResponseContent).init(std.heap.page_allocator);
    defer tool_calls.deinit();

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const type_str = switch (obj.get("type") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, type_str, "text")) {
            const text = switch (obj.get("text") orelse .null) {
                .string => |s| s,
                else => "",
            };
            try text_blocks.append(try arena.dupe(u8, text));
        } else if (std.mem.eql(u8, type_str, "tool_use")) {
            const id = switch (obj.get("id") orelse .null) {
                .string => |s| s,
                else => "",
            };
            const name = switch (obj.get("name") orelse .null) {
                .string => |s| s,
                else => "",
            };
            const input = obj.get("input") orelse .null;
            try tool_calls.append(.{
                .id = try arena.dupe(u8, id),
                .name = try arena.dupe(u8, name),
                .input = input,
            });
        }
    }

    return .{
        .text_blocks = try arena.dupe([]const u8, text_blocks.items),
        .tool_calls = try arena.dupe(ResponseContent, tool_calls.items),
    };
}

// ---------------------------------------------------------------------------
// Conversation helpers
// ---------------------------------------------------------------------------

const Conversation = std.ArrayListUnmanaged(MessageParam);

fn pushUserText(c: *Conversation, gpa: std.mem.Allocator, arena: std.mem.Allocator, text: []const u8) !void {
    const block = ContentBlockParam{ .text = .{ .text = try arena.dupe(u8, text) } };
    const blocks = try arena.alloc(ContentBlockParam, 1);
    blocks[0] = block;
    try c.append(gpa, .{ .role = "user", .content = blocks });
}

fn pushAssistant(c: *Conversation, gpa: std.mem.Allocator, arena: std.mem.Allocator, response: ParsedResponse) !void {
    // Build an assistant message containing the same content blocks we
    // saw in the response. We need to round-trip both text and tool_use
    // blocks for the next request so the model has full context.
    const blocks = try arena.alloc(ContentBlockParam, response.text_blocks.len + response.tool_calls.len);
    var i: usize = 0;
    for (response.text_blocks) |t| {
        blocks[i] = .{ .text = .{ .text = t } };
        i += 1;
    }
    for (response.tool_calls) |tc| {
        blocks[i] = .{ .tool_use = .{
            .id = tc.id,
            .name = tc.name,
            .input = tc.input,
        } };
        i += 1;
    }
    try c.append(gpa, .{ .role = "assistant", .content = blocks });
}

fn pushToolResults(
    c: *Conversation,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    results: []const ContentBlockParam.ToolResultBlock,
) !void {
    const blocks = try arena.alloc(ContentBlockParam, results.len);
    for (results, 0..) |r, i| blocks[i] = .{ .tool_result = r };
    try c.append(gpa, .{ .role = "user", .content = blocks });
}

// ---------------------------------------------------------------------------
// I/O helpers
// ---------------------------------------------------------------------------

fn printPrompt(io: Io, stdout: *Io.File) !void {
    // Build the prompt at comptime so it goes out in a single
    // `writeStreamingAll` call.
    const prompt: []const u8 = c_you ++ "You" ++ c_reset ++ ": ";
    try stdout.writeStreamingAll(io, prompt);
}

/// Read one line from stdin (without the trailing `\n`). Returns null on
/// EOF or on read failure. Mirrors the Go version's `bufio.Scanner.Scan`
/// behavior. The reader state lives in `*state`, so the underlying
/// buffer survives between calls.
fn readStdinLine(arena: std.mem.Allocator, _: Io, state: *Io.File.Reader) !?[]u8 {
    const line_with_nl = state.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => {
            // EOF: takeDelimiterInclusive returns EndOfStream when the
            // stream ends without a delimiter. Return any buffered data
            // as a partial line, otherwise null.
            if (state.interface.bufferedLen() == 0) return null;
            const remaining = state.interface.buffered();
            return try arena.dupe(u8, remaining);
        },
        else => return err,
    };
    // `takeDelimiterInclusive` returns the delimiter as the last byte
    // (see `Reader.takeDelimiterInclusive` and its unit test). Strip
    // the trailing `\n` so callers get a clean line.
    const line = line_with_nl[0 .. line_with_nl.len - 1];
    // `takeDelimiterInclusive` returns a slice into the reader's internal
    // buffer, which is invalidated by subsequent reads. Copy into the
    // arena so the caller can use it after the reader is dropped.
    return try arena.dupe(u8, line);
}

// ---------------------------------------------------------------------------
// Agent loop
// ---------------------------------------------------------------------------

fn runAgent(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
) !void {
    // The HTTP client needs a `now` timestamp for TLS certificate
    // validation (see http/Client.zig). The lazy init only loads the
    // CA bundle once `now` is set, so this is a one-time setup.
    var client: std.http.Client = .{
        .allocator = gpa,
        .io = io,
        .now = Io.Clock.real.now(io),
    };
    defer client.deinit();

    // TLS requires a CA bundle. Zig 0.16 does not auto-load one
    // (unlike curl/Go), so we point the client at the system bundle.
    // `ca_bundle.rescan` knows the right location for each supported
    // platform (Linux, macOS, Windows, BSDs). When the user has set
    // `SSL_CERT_FILE`, fall back to loading that specific file
    // (matches curl/Go conventions). Either way, errors are
    // non-fatal: the request will surface `TlsInitializationFailed`
    // if the bundle really is missing, and that already gives a
    // useful diagnostic.
    {
        const ca_path = getEnvOr(environ, "SSL_CERT_FILE", "");
        const now_ts = client.now orelse Io.Clock.real.now(io);
        if (ca_path.len > 0) {
            client.ca_bundle.addCertsFromFilePathAbsolute(gpa, io, now_ts, ca_path) catch |err| {
                std.log.warn("failed to load CA bundle from {s}: {t}", .{ ca_path, err });
            };
        } else {
            client.ca_bundle.rescan(gpa, io, now_ts) catch |err| {
                std.log.warn("failed to rescan CA bundle: {t}", .{err});
            };
        }
    }

    // The auth header is a single `Header` on the stack. The
    // `client.request` call takes a slice of headers and copies the
    // values internally for the duration of the request, so the stack
    // lifetime is sufficient.
    //
    // Note: `accept-encoding` is a privileged header and is set via the
    // structured `RequestOptions.headers` field (see `sendMessage`),
    // not here.
    const extra_headers: []const std.http.Header = &.{
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "content-type", .value = "application/json" },
    };

    var stdin_file = Io.File.stdin();
    var stdout_file = Io.File.stdout();
    const stdin = &stdin_file;
    const stdout = &stdout_file;

    try stdout.writeStreamingAll(io, "Chat with AI (use 'ctrl-c' to quit)\n");

    // Create the stdin reader once and keep it alive for the whole
    // session — the reader's internal buffer must persist across
    // `readStdinLine` calls so leftover data after a delimiter isn't
    // lost.
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(io, &stdin_buf);

    var conversation: Conversation = .empty;
    defer conversation.deinit(gpa);

    // Build the "AI: " and "tool: " prefixes at comptime so each
    // per-turn print is a single `writeStreamingAll` call.
    const ai_prefix: []const u8 = c_ai ++ "AI" ++ c_reset ++ ": ";
    const tool_prefix: []const u8 = c_tool ++ "tool" ++ c_reset ++ ": ";

    var read_user_input = true;
    while (true) {
        var user_text: ?[]u8 = null;
        if (read_user_input) {
            try printPrompt(io, stdout);

            // The Go version sends an empty user message if the user
            // submits an empty line. The plan instead says to re-prompt.
            // We follow the plan: re-prompt on empty input, but still
            // break the loop on EOF.
            while (true) {
                user_text = try readStdinLine(arena, io, &stdin_reader);
                if (user_text == null) break; // EOF
                if (user_text.?.len == 0) {
                    try printPrompt(io, stdout);
                    continue;
                }
                break;
            }
            if (user_text == null) break; // EOF
            try pushUserText(&conversation, gpa, arena, user_text.?);
        }

        const body_bytes = try buildRequestBody(arena, model, conversation.items, tools);
        const raw = sendMessage(arena, &client, extra_headers, base_url, body_bytes) catch |err| {
            std.log.err("API request failed: {t}", .{err});
            return err;
        };
        const parsed = try handleResponse(arena, raw);

        // Print any text blocks (matches Go's `case "text"` branch).
        for (parsed.text_blocks) |t| {
            try stdout.writeStreamingAll(io, ai_prefix);
            try stdout.writeStreamingAll(io, t);
            try stdout.writeStreamingAll(io, "\n");
        }

        try pushAssistant(&conversation, gpa, arena, parsed);

        if (parsed.tool_calls.len == 0) {
            // No tool calls: the model is done with this turn. Go back
            // to the prompt.
            read_user_input = true;
            continue;
        }

        // Execute each tool, build tool_result blocks, push as a user
        // message, and loop without re-prompting. Mirrors the Go
        // version's `toolResults` accumulation.
        var results: std.array_list.Managed(ContentBlockParam.ToolResultBlock) = std.array_list.Managed(ContentBlockParam.ToolResultBlock).init(std.heap.page_allocator);
        defer results.deinit();

        for (parsed.tool_calls) |tc| {
            try stdout.writeStreamingAll(io, tool_prefix);
            try stdout.writeStreamingAll(io, tc.name);
            try stdout.writeStreamingAll(io, "(");

            // Best-effort pretty-print of the tool's input. We use
            // `valueAlloc` which returns a fresh `[]u8` slice (this is
            // the only `Stringify` API that still hides the writer
            // plumbing in 0.16). If the stringify fails, fall back to
            // an empty string and skip the free — `Allocator.free` of a
            // zero-length slice is a no-op, but we don't want to
            // pretend we own a string literal.
            const input_str = std.json.Stringify.valueAlloc(std.heap.page_allocator, tc.input, .{}) catch &.{};
            defer std.heap.page_allocator.free(input_str);
            try stdout.writeStreamingAll(io, input_str);
            try stdout.writeStreamingAll(io, ")\n");

            const tool = findTool(tc.name) orelse {
                try results.append(.{
                    .tool_use_id = tc.id,
                    .content = "tool not found",
                    .is_error = true,
                });
                continue;
            };
            const result_str = tool.func(tc.input, arena, io) catch |err| {
                const err_msg = std.fmt.allocPrint(arena, "{s}", .{@errorName(err)}) catch "error";
                try results.append(.{
                    .tool_use_id = tc.id,
                    .content = err_msg,
                    .is_error = true,
                });
                continue;
            };
            try results.append(.{
                .tool_use_id = tc.id,
                .content = result_str,
                .is_error = false,
            });
        }

        try pushToolResults(&conversation, gpa, arena, results.items);
        read_user_input = false;
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) void {
    // In Zig 0.16 every FS op needs an `io: std.Io` parameter. The
    // `std.Io.Threaded` model is the right fit for a CLI tool that does
    // both stdin/stdout and network I/O. See README.md for the full
    // list of call sites that had to change.
    var threaded = Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The http.Client needs a real heap-backed allocator for its
    // connection pool; `std.heap.page_allocator` is fine for a CLI of
    // this size. (For Debug leak detection, swap in `std.heap.DebugAllocator`.)
    const gpa = std.heap.page_allocator;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Pull config from env. `API_KEY` is required; the others fall
    // back to defaults (see top of file). We exit(1) on missing/empty
    // API key, mirroring the Go version (which prints an error and
    // recovers).
    //
    // `std.process.Environ.getPosix` walks the env block captured at
    // startup. `std.c.getenv` (libc) does NOT work under Zig 0.16's
    // standalone runtime because it doesn't populate libc's
    // `environ` global — see `std/start.zig`.
    const api_key = getEnvOr(init.environ, "API_KEY", "");
    if (api_key.len == 0) {
        const stderr = Io.File.stderr();
        stderr.writeStreamingAll(io, "Error: API_KEY environment variable is required.\n") catch {};
        std.process.exit(1);
    }

    const base_url = getEnvOr(init.environ, "ANTHROPIC_BASE_URL", default_base_url);
    const model = getEnvOr(init.environ, "MODEL", default_model);

    runAgent(arena_alloc, gpa, io, init.environ, api_key, base_url, model) catch |err| {
        const stderr = Io.File.stderr();
        const msg = std.fmt.allocPrint(arena_alloc, "Error: {s}\n", .{@errorName(err)}) catch "Error: <unknown>\n";
        stderr.writeStreamingAll(io, msg) catch {};
    };
}
