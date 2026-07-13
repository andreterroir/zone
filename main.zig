// main.zig — REPL-style agent that talks to an Anthropic-compatible Messages API.
//
// Default target: OpenCode Go Anthropic-compatible endpoint, model `minimax-m3`.
// Override base URL with `ANTHROPIC_BASE_URL` and model with `MODEL`.
// API key is always read from `API_KEY`; the program exits if it is missing.
//
// Build / run:  zig run main.zig
//
// No external dependencies — Zig 0.16.0 standard library only.
//
// In Zig 0.16.0 the debug-checking allocator is `std.heap.DebugAllocator`
// (formerly `std.heap.GeneralPurposeAllocator`).

const std = @import("std");

const max_response_bytes: usize = 1 * 1024 * 1024; // 1 MiB response cap
const max_file_bytes: usize = 1 * 1024 * 1024; // 1 MiB cap on files read/written by tools

// ---- ANSI colors ------------------------------------------------------------

const c_reset = "\x1b[0m";
const c_you = "\x1b[94m";
const c_ai = "\x1b[93m";
const c_tool = "\x1b[92m";

// In Zig 0.16.0, the `std.fs.File` struct was removed. Files are now just
// `std.posix.fd_t` integers, and the `std.posix.read` / `std.posix.write`
// free functions were also relocated. We use the C standard library's
// `read` / `write` directly via the same `c` import as the env helpers.
// The standard streams are exposed as the `STD{IN,OUT,ERR}_FILENO` constants
// on `std.posix`.
const stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;
const stdout_fd: std.posix.fd_t = std.posix.STDOUT_FILENO;
const stderr_fd: std.posix.fd_t = std.posix.STDERR_FILENO;

// We use `[*c]` (C many-pointer) for the buffer so the C ABI is happy — in
// particular the aarch64_aapcs_darwin calling convention (Apple Silicon)
// does not allow Zig slice types (`[]u8` / `[]const u8`) in `extern "c"`
// declarations, because a Zig slice is a fat `{ptr, len}` struct that the C
// ABI doesn't know how to lower. With `[*c]const u8` Zig passes just the
// pointer, which is exactly what POSIX `read`/`write` expect (they take
// `void *` plus an explicit `size_t` length). The length is supplied
// separately, so the slice's own length is ignored — which is what we want.
extern "c" fn write(fd: c_int, buf: [*c]const u8, count: usize) isize;
extern "c" fn read(fd: c_int, buf: [*c]u8, count: usize) isize;

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = write(fd, bytes[written..].ptr, bytes.len - written);
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.WriteZero;
        written += @intCast(n);
    }
}

fn printFd(fd: std.posix.fd_t, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try writeAll(fd, s);
}

// ---- env helpers ------------------------------------------------------------

// `getenv` is a C standard library function. In Zig 0.16.0 it is no longer
// re-exported under `std.posix`, so we declare it via a tiny C import.
const c = @cImport({
    @cInclude("stdlib.h");
});

fn getEnvOr(arena: std.mem.Allocator, key: []const u8, default: []const u8) ![]const u8 {
    _ = arena;
    const value = c.getenv(key.ptr);
    if (value) |v| {
        return std.mem.span(v);
    }
    return default;
}

// ---- Tool JSON schemas (inline, static) -------------------------------------

const read_file_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"The relative path of a file in the working directory."}},"required":["path"],"additionalProperties":false}
;

const list_files_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Optional relative path to list files from. Defaults to current directory if not provided."}},"required":[],"additionalProperties":false}
;

const edit_file_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"The path to the file"},"old_str":{"type":"string","description":"Text to search for - must match exactly and must only have one match exactly"},"new_str":{"type":"string","description":"Text to replace old_str with"}},"required":["path","old_str","new_str"],"additionalProperties":false}
;

// ---- Tool input structs -----------------------------------------------------

const ReadFileInput = struct {
    path: []const u8,
};

const ListFilesInput = struct {
    path: ?[]const u8 = null,
};

const EditFileInput = struct {
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
};

// ---- Tool dispatch ----------------------------------------------------------

const ToolFn = *const fn (input: std.json.Value, arena: std.mem.Allocator) anyerror![]const u8;

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
    func: ToolFn,
};

const tools = [_]ToolDef{
    .{
        .name = "read_file",
        .description = "Read the contents of a given relative file path. use this when you want to see what's inside a file. Do not use this with directory names.",
        .schema = read_file_schema,
        .func = toolReadFile,
    },
    .{
        .name = "list_files",
        .description = "List files and directories at a given path. If no path is provided, lists files in the current directory.",
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
};

fn findTool(name: []const u8) ?ToolDef {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

// ---- Tool implementations ---------------------------------------------------

fn toolReadFile(input: std.json.Value, arena: std.mem.Allocator) ![]const u8 {
    const parsed = try std.json.parseFromValueLeaky(ReadFileInput, arena, input, .{});
    const content = try std.fs.cwd().readFileAlloc(arena, parsed.path, max_file_bytes);
    return content;
}

fn toolListFiles(input: std.json.Value, arena: std.mem.Allocator) ![]const u8 {
    const parsed = try std.json.parseFromValueLeaky(ListFilesInput, arena, input, .{});
    const dir_path = parsed.path orelse ".";

    var out: std.array_list.Aligned(u8, null) = .empty;
    var first = true;
    const writer = out.writer(arena);
    try writer.writeAll("[");

    var walker = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer walker.close();

    var it = walker.iterate();
    while (try it.next()) |entry| {
        if (!first) try writer.writeAll(",");
        first = false;
        const name = entry.name;
        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        try std.json.stringify(name, .{}, writer);
        try writer.writeAll(suffix);
    }

    try writer.writeAll("]");
    return out.items;
}

fn toolEditFile(input: std.json.Value, arena: std.mem.Allocator) ![]const u8 {
    const parsed = try std.json.parseFromValueLeaky(EditFileInput, arena, input, .{});

    if (parsed.path.len == 0 or std.mem.eql(u8, parsed.old_str, parsed.new_str)) {
        return error.InvalidInputParameters;
    }

    const content = std.fs.cwd().readFileAlloc(arena, parsed.path, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            if (parsed.old_str.len == 0) {
                return createNewFile(arena, parsed.path, parsed.new_str);
            }
            return err;
        },
        else => return err,
    };

    // replace all occurrences of old_str with new_str
    var current: []u8 = try arena.dupe(u8, content);
    var total_replaced: usize = 0;
    while (std.mem.indexOf(u8, current, parsed.old_str)) |idx| {
        const after = idx + parsed.old_str.len;
        const replaced = try std.mem.replaceOwned(u8, arena, current, parsed.old_str, parsed.new_str);
        total_replaced += 1;
        if (replaced.len == current.len) break; // safety
        _ = after;
        current = replaced;
    }

    // empty old_str means new-file creation; skip the "not found" check in that case.
    if (total_replaced == 0 and parsed.old_str.len != 0) {
        return error.OldStrNotFound;
    }

    const file = try std.fs.cwd().createFile(parsed.path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(current);

    return "OK";
}

fn createNewFile(arena: std.mem.Allocator, file_path: []const u8, content: []const u8) ![]const u8 {
    if (std.fs.path.dirname(file_path)) |dir| {
        if (!std.mem.eql(u8, dir, ".") and dir.len != 0) {
            try std.fs.cwd().makePath(dir);
        }
    }

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll(content);

    return try std.fmt.allocPrint(arena, "Successfully created file {s}", .{file_path});
}

// ---- API helper -------------------------------------------------------------

const Conversation = std.array_list.Aligned(std.json.Value, null);

fn sendMessage(
    arena: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    conversation: *const Conversation,
) !std.json.Parsed(std.json.Value) {
    // 1. Build the request body.
    const body = try buildRequestBody(arena, model, conversation);

    // 2. POST to {base_url}/v1/messages via std.http.Client.fetch.
    //
    // Response body size is bounded by `max_append_size` below, which
    // caps how much the client's append buffer will grow while reading.
    // TODO: verify the exact `FetchOptions` field name in 0.16.0 (it has
    // changed across releases — `max_append_size` / `max_chunk_size` /
    // `max_size` — pick whichever this version exposes).
    var client = std.http.Client{ .allocator = arena };
    defer client.deinit();

    const url = try std.fmt.allocPrint(arena, "{s}/v1/messages", .{base_url});

    const response_storage = try arena.create(std.http.Client.FetchResponse);
    const fetch_result = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .extra_headers = &.{
            .{ .name = "x-api-key", .value = api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "content-type", .value = "application/json" },
        },
        .payload = body,
        .response_storage = response_storage,
        .max_append_size = max_response_bytes,
    });
    defer fetch_result.deinit();

    // 3. Read the body.
    var body_buf: std.array_list.Aligned(u8, null) = .empty;
    try body_buf.ensureTotalCapacity(arena, 4096);
    try fetch_result.reader.readAllArrayList(&body_buf, max_response_bytes);

    // 4. Parse the body as JSON.
    return try std.json.parseFromSlice(std.json.Value, arena, body_buf.items, .{});
}

fn buildRequestBody(arena: std.mem.Allocator, model: []const u8, conversation: *const Conversation) ![]u8 {
    var buf: std.array_list.Aligned(u8, null) = .empty;
    try buf.ensureTotalCapacity(arena, 1024);
    const w = buf.writer(arena);

    try w.writeAll("{");
    try std.json.stringify("model", .{}, w);
    try w.writeAll(":");
    try std.json.stringify(model, .{}, w);
    try w.writeAll(",");
    try std.json.stringify("max_tokens", .{}, w);
    try w.writeAll(":1024");
    try w.writeAll(",");
    try std.json.stringify("messages", .{}, w);
    try w.writeAll(":");
    try std.json.stringify(conversation.items, .{}, w);
    try w.writeAll(",");
    try std.json.stringify("tools", .{}, w);
    try w.writeAll(":[");
    for (tools, 0..) |t, i| {
        if (i != 0) try w.writeAll(",");
        // input_schema must be a JSON object, not a string — parse it.
        const schema_parsed = try std.json.parseFromSlice(std.json.Value, arena, t.schema, .{});
        try std.json.stringify(.{
            .name = t.name,
            .description = t.description,
            .input_schema = schema_parsed.value,
        }, .{}, w);
    }
    try w.writeAll("]}");
    return buf.items;
}

// ---- Response handling ------------------------------------------------------

const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
};

const Turn = struct {
    text: []const u8,
    tool_calls: []ToolCall,
};

/// Walks the response value, prints text blocks to stdout, and returns
/// the aggregated text + tool calls (owned by `arena`).
fn handleResponse(arena: std.mem.Allocator, response: std.json.Value) !Turn {
    var text: std.array_list.Aligned(u8, null) = .empty;
    var calls: std.array_list.Aligned(ToolCall, null) = .empty;

    const content = response.object.get("content") orelse return .{ .text = "", .tool_calls = &.{} };
    if (content != .array) return .{ .text = "", .tool_calls = &.{} };

    for (content.array.items) |block| {
        if (block != .object) continue;
        const obj = block.object;

        const type_str = obj.get("type") orelse continue;
        if (type_str != .string) continue;

        if (std.mem.eql(u8, type_str.string, "text")) {
            const t = obj.get("text") orelse continue;
            if (t == .string) {
                try text.appendSlice(arena, t.string);
                try text.append(arena, '\n');
            }
        } else if (std.mem.eql(u8, type_str.string, "tool_use")) {
            const id = obj.get("id") orelse continue;
            const name = obj.get("name") orelse continue;
            const input = obj.get("input") orelse continue;
            if (id != .string or name != .string) continue;
            try calls.append(arena, .{
                .id = id.string,
                .name = name.string,
                .input = input,
            });
        }
    }

    return .{ .text = text.items, .tool_calls = calls.items };
}

// ---- Conversation helpers ---------------------------------------------------

fn pushUserText(conv: *Conversation, arena: std.mem.Allocator, text: []const u8) !void {
    // Build a JSON content block: { "type": "text", "text": <text> }
    var block_object: std.json.ObjectMap = .empty;
    try block_object.put(arena, "type", std.json.Value{ .string = "text" });
    try block_object.put(arena, "text", std.json.Value{ .string = text });

    var content_array: std.json.Array = .init(arena);
    try content_array.append(std.json.Value{ .object = block_object });

    var msg_object: std.json.ObjectMap = .empty;
    try msg_object.put(arena, "role", std.json.Value{ .string = "user" });
    try msg_object.put(arena, "content", std.json.Value{ .array = content_array });

    try conv.append(arena, std.json.Value{ .object = msg_object });
}

fn pushAssistant(conv: *Conversation, arena: std.mem.Allocator, response: std.json.Value) !void {
    var msg_object: std.json.ObjectMap = .empty;
    try msg_object.put(arena, "role", std.json.Value{ .string = "assistant" });
    const content = response.object.get("content") orelse std.json.Value.null;
    try msg_object.put(arena, "content", content);
    try conv.append(arena, std.json.Value{ .object = msg_object });
}

fn pushToolResults(
    conv: *Conversation,
    arena: std.mem.Allocator,
    calls: []const ToolCall,
    results: []const ToolResult,
) !void {
    var blocks: std.json.Array = .init(arena);
    for (calls, results) |call, result| {
        var block_object: std.json.ObjectMap = .empty;
        try block_object.put(arena, "type", std.json.Value{ .string = "tool_result" });
        try block_object.put(arena, "tool_use_id", std.json.Value{ .string = call.id });
        try block_object.put(arena, "content", std.json.Value{ .string = result.content });
        try block_object.put(arena, "is_error", std.json.Value{ .bool = result.is_error });
        try blocks.append(std.json.Value{ .object = block_object });
    }

    var msg_object: std.json.ObjectMap = .empty;
    try msg_object.put(arena, "role", std.json.Value{ .string = "user" });
    try msg_object.put(arena, "content", std.json.Value{ .array = blocks });

    try conv.append(arena, std.json.Value{ .object = msg_object });
}

const ToolResult = struct {
    content: []const u8,
    is_error: bool,
};

// ---- Agent loop -------------------------------------------------------------

fn runAgent(
    arena: std.mem.Allocator,
    stdin: std.posix.fd_t,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
) !void {
    var conv = Conversation{};
    var read_user_input = true;

    try writeAll(stdout_fd, "Chat with AI (use 'ctrl-c' to quit)\n");

    while (true) {
        if (read_user_input) {
            try writeAll(stdout_fd, c_you ++ "You" ++ c_reset ++ ": ");
            const line = try readLineAlloc(arena, stdin);
            if (line == null) break;
            if (line.?.len == 0) continue; // empty prompt: do nothing, re-prompt
            try pushUserText(&conv, arena, line.?);
        }

        const parsed = sendMessage(arena, base_url, api_key, model, &conv) catch |err| {
            try printFd(stderr_fd, "Error: {s}\n", .{@errorName(err)});
            return;
        };
        defer parsed.deinit();
        const response = parsed.value;

        const turn = try handleResponse(arena, response);
        if (turn.text.len != 0) {
            try writeAll(stdout_fd, c_ai ++ "AI" ++ c_reset ++ ": ");
            try writeAll(stdout_fd, turn.text);
        }

        try pushAssistant(&conv, arena, response);

        if (turn.tool_calls.len == 0) {
            read_user_input = true;
            continue;
        }

        read_user_input = false;
        const results = try arena.alloc(ToolResult, turn.tool_calls.len);
        for (turn.tool_calls, results) |call, *slot| {
            if (findTool(call.name)) |tool| {
                // Print the tool call to the user.
                const input_str = try std.json.stringifyAlloc(arena, call.input, .{});
                try printFd(stdout_fd, c_tool ++ "tool" ++ c_reset ++ ": {s}({s})\n", .{ call.name, input_str });
                if (tool.func(call.input, arena)) |out| {
                    slot.* = .{ .content = out, .is_error = false };
                } else |err| {
                    slot.* = .{ .content = @errorName(err), .is_error = true };
                }
            } else {
                slot.* = .{ .content = "tool not found", .is_error = true };
            }
        }
        try pushToolResults(&conv, arena, turn.tool_calls, results);
    }
}

/// Reads one line from `fd` (delimited by '\n' or EOF). Returns null on EOF.
/// The returned slice is owned by `arena`.
fn readLineAlloc(arena: std.mem.Allocator, fd: std.posix.fd_t) !?[]u8 {
    var buf: std.array_list.Aligned(u8, null) = .empty;
    var one: [1]u8 = undefined;
    while (true) {
        const n = read(fd, &one, 1);
        if (n < 0) return error.ReadFailed;
        if (n == 0) {
            if (buf.items.len == 0) return null;
            return buf.items;
        }
        if (one[0] == '\n') return buf.items;
        try buf.append(arena, one[0]);
    }
}

// ---- main -------------------------------------------------------------------

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    var arena: std.heap.ArenaAllocator = .init(gpa_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // `c.getenv` returns a `?[*c]u8` (a nullable C many-pointer). A
    // `[*c]u8` has no `.len` field, so we must convert it to a `[]const u8`
    // slice (via `std.mem.span`) before we can check its length. The null
    // case is handled with a plain `if` statement rather than `orelse { ... }`
    // to sidestep any block-type-inference quirks in Zig 0.16.
    const api_key_ptr = c.getenv("API_KEY");
    if (api_key_ptr == null) {
        try writeAll(stderr_fd, "Error: API_KEY environment variable is not set\n");
        std.process.exit(1);
    }
    const api_key = std.mem.span(api_key_ptr.?);
    if (api_key.len == 0) {
        try writeAll(stderr_fd, "Error: API_KEY environment variable is empty\n");
        std.process.exit(1);
    }

    const base_url = try getEnvOr(arena_alloc, "ANTHROPIC_BASE_URL", "https://opencode.ai/zen/go");
    const model = try getEnvOr(arena_alloc, "MODEL", "minimax-m3");

    try runAgent(
        arena_alloc,
        stdin_fd,
        base_url,
        api_key,
        model,
    );
}
