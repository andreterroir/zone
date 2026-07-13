### 1. `std.mem.replaceOwned` — single call, not a loop

`replaceOwned` already replaces **all** occurrences internally (delegates to `replace` which loops). The plan's "loop of `replaceOwned` calls" is wrong — it's just one call.

### 2. `std.json.stringify` → `std.json.Stringify.value`

The top-level `std.json.stringify` convenience function is gone. The new signature is:
```zig
std.json.Stringify.value(allocator, value, .{}, writer)
```
Note the **allocator is the first argument**. The plan's `buildRequestBody` helper must be updated to pass `gpa` / `arena.allocator()`.

### 3. `FetchOptions` has no size-limiting field

Confirmed: `FetchOptions` has no `max_append_size`, `max_chunk_size`, or `max_size`. The only way to cap the response body through `fetch` is via a custom `response_writer`.

Practical fix: use the lower-level API instead:
```zig
var req = try client.request(.POST, uri, .{ ... });
defer req.deinit();
try req.sendBodyComplete(body);
var response = try req.receiveHead(&redirect_buffer);
var reader = response.reader(&transfer_buffer);
// read with your own cap here
```

### 4. Every FS operation now requires `io: std.Io`

This is the biggest structural change. `std.fs.Dir`, `std.fs.File`, and all operations (`openFile`, `iterate`, `read`, `write`, `reader()`, `writer()`) now require an explicit `io: std.Io` parameter.

For a CLI tool, initialize once in `main`:
```zig
const io = try std.Io.Threaded.init(allocator);
defer io.deinit();
```
Then pass `io` to every FS call:
```zig
const dir = std.Io.Dir.cwd();
var file = try dir.openFile(io, path, .{});
defer file.close(io);
var reader = file.reader(io, &buf);
var writer = file.writer(io, &buf);
```

### 5. `std.json.Value` and `parseFromValueLeaky` are correct

These exist and work as the plan describes. `Value` has `.object` (with `.iterator()`) and `.array` (with `.items`).

### 6. `std.process.exit(status: u8) noreturn`

Exists and works as the plan describes.

### 7. ANSI codes on stdout

`std.Io.File.stdout()` exists. To safely write ANSI color codes, you'd write raw bytes via the file's writer or use `std.Io.lockStderr`/`std.Io.lockStdout` equivalents. Since there's no `lockStdout`, just write directly to `std.Io.File.stdout()` using a writer.

---

### Updated Plan Sections

**HTTP body cap:**
> Remove `max_append_size` from `FetchOptions`. Instead, use `client.request()` + `req.sendBodyComplete()` + `req.receiveHead()` + manual body read via `response.reader()` with an `Io.Limit` cap. This is the only way to bound response size in 0.16.0.

**`buildRequestBody`:**
> Use `std.json.Stringify.value(arena.allocator(), value, .{}, writer)` instead of the removed `std.json.stringify`.

**`edit_file` tool:**
> Call `std.mem.replaceOwned(allocator, content, old_str, new_str)` once — it replaces all occurrences.

**`main` function:**
> Initialize `io = std.Io.Threaded.init(allocator)` (or `.failing` for testing). Pass `io` to every FS call (`openFile(io, ...)`, `close(io)`, `reader(io, &buf)`, `writer(io, &buf)`, `iterate(io)`, etc.).

**File operations summary:**
| Old | New (0.16.0) |
|-----|-------------|
| `file.reader()` | `file.reader(io, &buf)` |
| `file.writer()` | `file.writer(io, &buf)` |
| `dir.iterate()` | `dir.iterate(io)` (returns `Iterator` with `.next(io)`) |
| `file.close()` | `file.close(io)` |
| `dir.openFile(path, opts)` | `dir.openFile(io, path, opts)` |
