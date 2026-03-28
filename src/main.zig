// TUI Browser — main entry point.

const std    = @import("std");
const term   = @import("terminal/term.zig");
const resize = @import("terminal/resize.zig");
const input  = @import("terminal/input.zig");
const caps   = @import("terminal/capabilities.zig");
const transport  = @import("ipc/transport.zig");
const compositor = @import("render/compositor.zig");
const app_mod    = @import("app.zig");

// ── Debug logging ─────────────────────────────────────────────────────────────

/// Override std.log to write to a file instead of stderr (which would corrupt the TUI).
pub const std_options: std.Options = .{
    .logFn = logFn,
};

var g_log_file: ?std.fs.File = null;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const file = g_log_file orelse return;
    var buf: [2048]u8 = undefined;
    const scope_str = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const msg = std.fmt.bufPrint(
        &buf,
        "[" ++ @tagName(level) ++ "] " ++ scope_str ++ format ++ "\n",
        args,
    ) catch return;
    _ = std.posix.write(file.handle, msg) catch {};
}

pub fn main() !void {
    // Require a real terminal on both stdin and stdout
    if (!std.posix.isatty(std.posix.STDOUT_FILENO)) {
        std.fs.File.stderr().writeAll("browser: stdout is not a terminal\n") catch {};
        std.process.exit(1);
    }
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
        std.fs.File.stderr().writeAll("browser: stdin is not a terminal\n") catch {};
        std.process.exit(1);
    }

    // Always open a log file and redirect stderr there — keeps both Zig log output and
    // Bun's stderr from corrupting the TUI. Print the path before raw mode starts.
    {
        const pid = std.os.linux.getpid();
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/browser-{d}.log", .{pid}) catch "/tmp/browser.log";
        g_log_file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch null;
        if (g_log_file) |lf| {
            const stderr = std.fs.File.stderr();
            stderr.writeAll("log: ") catch {};
            stderr.writeAll(path) catch {};
            stderr.writeAll("\n") catch {};
            // Redirect the stderr fd so the child process inherits it too
            std.posix.dup2(lf.handle, std.posix.STDERR_FILENO) catch {};
        }
    }
    defer if (g_log_file) |f| f.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // CLI args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const initial_url: ?[]const u8 = if (args.len > 1) args[1] else null;

    // Terminal capabilities
    _ = caps.detect();

    // SIGWINCH
    resize.installSigwinch();

    // Initial terminal size
    const init_size = resize.getSize() catch resize.Size{
        .cols = 80, .rows = 24, .px_width = 0, .px_height = 0,
    };

    // Find bun worker path: exe_dir/../../bun/index.ts
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&exe_buf) catch ".";
    const worker_path = try std.fs.path.join(allocator, &.{ exe_dir, "..", "..", "bun", "index.ts" });
    defer allocator.free(worker_path);

    // Spawn Bun subprocess
    var child = std.process.Child.init(&.{ "bun", "run", worker_path }, allocator);
    child.stdin_behavior  = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const bun_stdin  = child.stdin.?;
    const bun_stdout = child.stdout.?;

    // IPC reader thread
    var msg_queue = transport.MsgQueue.init(allocator);
    defer msg_queue.deinit();

    const reader_ctx = transport.ReaderContext{
        .pipe_fd   = bun_stdout.handle,
        .queue     = &msg_queue,
        .allocator = allocator,
    };
    const reader_thread = try std.Thread.spawn(.{}, transport.readerThread, .{reader_ctx});
    reader_thread.detach();

    // Terminal setup
    try term.setup();
    defer term.teardown();

    const stdout = std.fs.File.stdout();
    const stdin  = std.fs.File.stdin();

    // App
    var app = try app_mod.App.init(
        allocator,
        init_size.cols,
        init_size.rows,
        bun_stdin,
        stdout,
        &msg_queue,
    );
    defer app.deinit();
    app_mod.setGlobalApp(&app);

    // Initial resize notification to Bun
    try transport.sendMsg(bun_stdin, allocator, .{
        .type      = "resize",
        .cols      = init_size.cols,
        .rows      = init_size.rows,
        .px_width  = init_size.px_width,
        .px_height = init_size.px_height,
    });

    // Initial navigate
    if (initial_url) |url| try app.navigate(url);

    // Initial render
    try app.render();

    // ── Event loop ────────────────────────────────────────────────────────────

    // Stack buffer for stdin reading (raw mode, single bytes at a time)
    var stdin_buf: [1]u8 = undefined;
    var last_spinner_ms = std.time.milliTimestamp();

    while (app.running) {
        // Check SIGWINCH
        if (resize.resize_pending.swap(false, .acquire)) {
            try app.handleInput(.{ .resize = {} });
        }

        // Drain IPC messages — track state transitions to know when to re-render
        const pre_loading = app.state.loading;
        const pre_root    = app.state.root;
        app.processMessages();
        const had_msg = pre_loading != app.state.loading or pre_root != app.state.root;

        // Update spinner at a consistent 80ms/frame rate
        if (app.state.loading) {
            const now = std.time.milliTimestamp();
            if (now - last_spinner_ms >= 80) {
                app.state.spinner_frame +%= 1;
                last_spinner_ms = now;
            }
        }

        // Non-blocking stdin read (raw mode VTIME=1 → 100ms timeout)
        const n = stdin.read(&stdin_buf) catch 0;
        if (n > 0) {
            // Put byte back into a small parser
            const event_opt = parseOneByte(stdin_buf[0], stdin, allocator) catch null;
            if (event_opt) |ev| {
                try app.handleInput(ev);
            }
        }

        // Re-render if needed
        if (had_msg or app.state.loading or n > 0) {
            try app.render();
        }
    }

    // Cleanup — close bun_stdin so Bun receives EOF and exits, then wait
    if (child.stdin) |s| {
        s.close();
        child.stdin = null;
    }
    _ = child.kill() catch {};
    _ = child.wait() catch {};
}

/// Parse a single byte from stdin into an InputEvent, reading more bytes if needed.
fn parseOneByte(first: u8, stdin: std.fs.File, allocator: std.mem.Allocator) !?input.InputEvent {
    // Create a tiny reader that reads from stdin
    const reader = StdinByteReader{ .file = stdin };
    const reader_any = reader.reader();
    return input.readEventFromFirst(first, reader_any, allocator);
}

/// Minimal reader adaptor for stdin in raw mode.
const StdinByteReader = struct {
    file: std.fs.File,

    const Reader = std.io.GenericReader(*const StdinByteReader, std.fs.File.ReadError, readFn);

    fn readFn(self: *const StdinByteReader, buf: []u8) std.fs.File.ReadError!usize {
        return self.file.read(buf);
    }

    fn reader(self: *const StdinByteReader) Reader {
        return .{ .context = self };
    }
};
