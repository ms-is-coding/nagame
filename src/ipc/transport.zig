// IPC transport: length-prefix framed JSON over pipes.
// Frame format: [4-byte big-endian uint32 length][N bytes UTF-8 JSON]

const std = @import("std");

pub const MAX_MSG_SIZE = 16 * 1024 * 1024; // 16 MiB

// ── Thread-safe message queue ─────────────────────────────────────────────────

pub const MsgQueue = struct {
    const Self = @This();

    mutex:    std.Thread.Mutex     = .{},
    cond:     std.Thread.Condition = .{},
    items:    std.ArrayList(QueueItem) = .empty,
    allocator: std.mem.Allocator,
    closed:   bool = false,

    pub const QueueItem = struct {
        json: []u8, // freed by consumer with the queue's allocator
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.items.items) |item| {
            self.allocator.free(item.json);
        }
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *Self, json: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.items.append(self.allocator, .{ .json = json }) catch return;
        self.cond.signal();
    }

    /// Block until a message is available or the queue is closed.
    pub fn pop(self: *Self) ?QueueItem {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.items.items.len == 0 and !self.closed) {
            self.cond.wait(&self.mutex);
        }
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// Non-blocking pop. Returns null if empty.
    pub fn tryPop(self: *Self) ?QueueItem {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    pub fn close(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }
};

// ── Reader thread ─────────────────────────────────────────────────────────────

pub const ReaderContext = struct {
    pipe_fd:   std.posix.fd_t,
    queue:     *MsgQueue,
    allocator: std.mem.Allocator,
};

pub fn readerThread(ctx: ReaderContext) void {
    while (true) {
        // Read 4-byte big-endian length prefix
        var header: [4]u8 = undefined;
        readExact(ctx.pipe_fd, &header) catch break;
        const msg_len = std.mem.readInt(u32, &header, .big);

        if (msg_len == 0 or msg_len > MAX_MSG_SIZE) break;

        const json = ctx.allocator.alloc(u8, msg_len) catch break;
        readExact(ctx.pipe_fd, json) catch {
            ctx.allocator.free(json);
            break;
        };

        ctx.queue.push(json);
    }

    ctx.queue.close();
}

fn readExact(fd: std.posix.fd_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch |err| return err;
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}

// ── Writer helpers ────────────────────────────────────────────────────────────

/// Send a length-prefixed JSON frame to a file descriptor.
pub fn sendFrame(file: std.fs.File, json: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(json.len), .big);
    try file.writeAll(&header);
    try file.writeAll(json);
}

/// Serialize `value` to JSON and send as a framed message.
pub fn sendMsg(file: std.fs.File, allocator: std.mem.Allocator, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    try sendFrame(file, json);
}
