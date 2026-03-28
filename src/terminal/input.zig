// VT sequence parser: reads raw bytes from stdin and produces InputEvents.

const std = @import("std");

pub const Key = union(enum) {
    char: u21,     // printable Unicode codepoint
    up, down, left, right,
    page_up, page_down,
    home, end,
    enter,
    backspace,
    delete,
    escape,
    tab,
    shift_tab,
    ctrl_c,
    ctrl_d,
    // Alt + key
    alt_left,
    alt_right,
    // Function keys
    f1, f2, f3, f4, f5, f6,
    // Unknown sequence (raw bytes stored externally)
    unknown,
};

pub const MouseButton = enum { left, middle, right, wheel_up, wheel_down };
pub const MouseAction = enum { press, release, move };

pub const MouseEvent = struct {
    button: MouseButton,
    action: MouseAction,
    col: u16,
    row: u16,
    mod_shift: bool = false,
    mod_ctrl: bool = false,
};

pub const InputEvent = union(enum) {
    key: Key,
    mouse: MouseEvent,
    paste: []const u8,  // bracketed paste content (caller owns memory)
    resize,             // SIGWINCH triggered
};

/// Read one input event from a reader (blocking). Returns null on EOF.
pub fn readEvent(reader: anytype, allocator: std.mem.Allocator) !?InputEvent {
    var first: [1]u8 = undefined;
    const n = reader.read(&first) catch return null;
    if (n == 0) return null;
    return readEventFromFirst(first[0], reader, allocator);
}

/// Parse an input event given an already-read first byte.
pub fn readEventFromFirst(b: u8, reader: anytype, allocator: std.mem.Allocator) !?InputEvent {
    return readEventByte(b, reader, allocator);
}

fn readEventByte(b: u8, reader: anytype, allocator: std.mem.Allocator) !?InputEvent {
    // ESC sequence
    if (b == 0x1b) {
        return parseEscSequence(reader, allocator) catch .{ .key = .escape };
    }

    // Ctrl-C
    if (b == 3) return .{ .key = .ctrl_c };
    // Ctrl-D
    if (b == 4) return .{ .key = .ctrl_d };
    // Enter
    if (b == '\r' or b == '\n') return .{ .key = .enter };
    // Backspace
    if (b == 127 or b == 8) return .{ .key = .backspace };
    // Tab
    if (b == '\t') return .{ .key = .tab };

    // UTF-8 multibyte
    if (b & 0x80 != 0) {
        const cp = try readUtf8(reader, b);
        return .{ .key = .{ .char = cp } };
    }

    // Printable ASCII
    if (b >= 0x20 and b < 0x7f) {
        return .{ .key = .{ .char = b } };
    }

    return .{ .key = .unknown };
}

fn readUtf8(reader: anytype, first: u8) !u21 {
    if (first & 0xE0 == 0xC0) {
        var buf: [1]u8 = undefined;
        _ = try reader.read(&buf);
        const cp: u21 = (@as(u21, first & 0x1F) << 6) | (buf[0] & 0x3F);
        return cp;
    } else if (first & 0xF0 == 0xE0) {
        var buf: [2]u8 = undefined;
        _ = try reader.read(&buf);
        const cp: u21 = (@as(u21, first & 0x0F) << 12) |
                        (@as(u21, buf[0] & 0x3F) << 6) |
                        (buf[1] & 0x3F);
        return cp;
    } else if (first & 0xF8 == 0xF0) {
        var buf: [3]u8 = undefined;
        _ = try reader.read(&buf);
        const cp: u21 = (@as(u21, first & 0x07) << 18) |
                        (@as(u21, buf[0] & 0x3F) << 12) |
                        (@as(u21, buf[1] & 0x3F) << 6) |
                        (buf[2] & 0x3F);
        return cp;
    }
    return first;
}

fn parseEscSequence(reader: anytype, allocator: std.mem.Allocator) !InputEvent {
    // Read next byte with a short timeout via non-blocking peek.
    // If nothing follows in ~50ms, it's a bare ESC keypress.
    var peek: [1]u8 = undefined;
    const n = reader.read(&peek) catch return .{ .key = .escape };
    if (n == 0) return .{ .key = .escape };

    switch (peek[0]) {
        '[' => return parseCsi(reader, allocator),
        'O' => return parseSs3(reader),
        // Alt + key: ESC followed by a regular key
        else => {
            const inner = peek[0];
            if (inner == 'D') return .{ .key = .alt_left };
            if (inner == 'C') return .{ .key = .alt_right };
            if (inner >= 0x20 and inner < 0x7f) {
                return .{ .key = .{ .char = inner } };
            }
            return .{ .key = .escape };
        },
    }
}

fn parseSs3(reader: anytype) !InputEvent {
    var b: [1]u8 = undefined;
    _ = try reader.read(&b);
    return switch (b[0]) {
        'A' => .{ .key = .up },
        'B' => .{ .key = .down },
        'C' => .{ .key = .right },
        'D' => .{ .key = .left },
        'H' => .{ .key = .home },
        'F' => .{ .key = .end },
        'P' => .{ .key = .f1 },
        'Q' => .{ .key = .f2 },
        'R' => .{ .key = .f3 },
        'S' => .{ .key = .f4 },
        else => .{ .key = .unknown },
    };
}

fn parseCsi(reader: anytype, allocator: std.mem.Allocator) !InputEvent {
    // Collect CSI parameter bytes (0x30–0x3f) and intermediate bytes (0x20–0x2f)
    var params_buf: [64]u8 = undefined;
    var params_len: usize = 0;

    while (true) {
        var b: [1]u8 = undefined;
        const n = try reader.read(&b);
        if (n == 0) break;
        const c = b[0];

        // Final byte: 0x40–0x7e
        if (c >= 0x40 and c <= 0x7e) {
            const params = params_buf[0..params_len];
            return parseCsiFinal(params, c, reader, allocator);
        }
        if (params_len < params_buf.len) {
            params_buf[params_len] = c;
            params_len += 1;
        }
    }
    return .{ .key = .unknown };
}

fn parseCsiFinal(params: []const u8, final: u8, reader: anytype, allocator: std.mem.Allocator) !InputEvent {
    switch (final) {
        'A' => return .{ .key = .up },
        'B' => return .{ .key = .down },
        'C' => return .{ .key = .right },
        'D' => return .{ .key = .left },
        'H' => return .{ .key = .home },
        'F' => return .{ .key = .end },
        'Z' => return .{ .key = .shift_tab },
        '~' => {
            const n = parseFirstNum(params);
            return switch (n) {
                1, 7  => .{ .key = .home },
                4, 8  => .{ .key = .end },
                5     => .{ .key = .page_up },
                6     => .{ .key = .page_down },
                3     => .{ .key = .delete },
                11    => .{ .key = .f1 },
                12    => .{ .key = .f2 },
                13    => .{ .key = .f3 },
                14    => .{ .key = .f4 },
                200   => blk: {
                    // Bracketed paste begin — read until ESC[201~
                    const text = try readPaste(reader, allocator);
                    break :blk .{ .paste = text };
                },
                else  => .{ .key = .unknown },
            };
        },
        // SGR mouse: ESC[<btn;col;rowM or m
        'M', 'm' => {
            if (params.len > 0 and params[0] == '<') {
                return parseSgrMouse(params[1..], final == 'M');
            }
            return .{ .key = .unknown };
        },
        else => return .{ .key = .unknown },
    }
}

fn parseFirstNum(params: []const u8) u32 {
    var n: u32 = 0;
    for (params) |c| {
        if (c >= '0' and c <= '9') {
            n = n * 10 + (c - '0');
        } else break;
    }
    return n;
}

fn parseSgrMouse(params: []const u8, pressed: bool) InputEvent {
    // Format: btn;col;row
    var nums: [3]u32 = .{0, 0, 0};
    var idx: usize = 0;
    for (params) |c| {
        if (c == ';') {
            idx += 1;
            if (idx >= 3) break;
        } else if (c >= '0' and c <= '9') {
            nums[idx] = nums[idx] * 10 + (c - '0');
        }
    }
    const btn_raw = nums[0];
    const col: u16 = @intCast(@max(1, nums[1]) - 1);
    const row: u16 = @intCast(@max(1, nums[2]) - 1);

    const is_move = (btn_raw & 32) != 0;
    const btn_base = btn_raw & ~@as(u32, 32 | 64);

    const button: MouseButton = switch (btn_base) {
        0 => .left,
        1 => .middle,
        2 => .right,
        64 => .wheel_up,
        65 => .wheel_down,
        else => .left,
    };

    return .{ .mouse = .{
        .button = button,
        .action = if (is_move) .move else if (pressed) .press else .release,
        .col = col,
        .row = row,
        .mod_shift = (btn_raw & 4) != 0,
        .mod_ctrl  = (btn_raw & 16) != 0,
    }};
}

fn readPaste(reader: anytype, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var state: u8 = 0;
    while (true) {
        var b: [1]u8 = undefined;
        const n = reader.read(&b) catch break;
        if (n == 0) break;
        const c = b[0];
        try buf.append(allocator, c);

        state = switch (state) {
            0 => if (c == 0x1b) 1 else 0,
            1 => if (c == '[') 2 else 0,
            2 => if (c == '2') 3 else 0,
            3 => if (c == '0') 4 else 0,
            4 => if (c == '1') 5 else 0,
            5 => if (c == '~') 6 else 0,
            else => 0,
        };
        if (state == 6) {
            const len = buf.items.len;
            if (len >= 6) buf.shrinkRetainingCapacity(len - 6);
            break;
        }
    }

    return buf.toOwnedSlice(allocator);
}
