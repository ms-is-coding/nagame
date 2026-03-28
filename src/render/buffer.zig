// Double-buffered cell grid with minimal-diff rendering.

const std = @import("std");
const Cell  = @import("cell.zig").Cell;
const Color = @import("cell.zig").Color;
const escape = @import("../terminal/escape.zig");

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    front: []Cell,
    back:  []Cell,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Buffer {
        const size = @as(usize, cols) * @as(usize, rows);
        const front = try allocator.alloc(Cell, size);
        const back  = try allocator.alloc(Cell, size);
        @memset(front, Cell{});
        @memset(back,  Cell{});
        return .{ .allocator = allocator, .cols = cols, .rows = rows, .front = front, .back = back };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.front);
        self.allocator.free(self.back);
    }

    pub fn resize(self: *Buffer, cols: u16, rows: u16) !void {
        self.allocator.free(self.front);
        self.allocator.free(self.back);
        const size = @as(usize, cols) * @as(usize, rows);
        self.front = try self.allocator.alloc(Cell, size);
        self.back  = try self.allocator.alloc(Cell, size);
        @memset(self.front, Cell{});
        @memset(self.back,  Cell{});
        self.cols = cols;
        self.rows = rows;
    }

    pub fn clearBack(self: *Buffer) void {
        @memset(self.back, Cell{});
    }

    pub fn setBack(self: *Buffer, col: u16, row: u16, cell: Cell) void {
        if (col >= self.cols or row >= self.rows) return;
        self.back[@as(usize, row) * self.cols + col] = cell;
    }

    pub fn getBack(self: *Buffer, col: u16, row: u16) Cell {
        if (col >= self.cols or row >= self.rows) return Cell{};
        return self.back[@as(usize, row) * self.cols + col];
    }

    /// Emit minimal escape sequences to sync the terminal with `back`, then swap.
    /// Uses an Allocating writer to batch all output, then writes it in one syscall.
    pub fn flush(self: *Buffer, stdout: std.fs.File) !void {
        var aw: std.io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try self.renderDiff(w);
        try stdout.writeAll(aw.written());
    }

    fn renderDiff(self: *Buffer, w: *std.io.Writer) !void {
        var current_row: u16 = 0xFFFF;
        var current_col: u16 = 0xFFFF;

        var cur_fg            = Color{};
        var cur_bg            = Color{};
        var cur_bold          = false;
        var cur_italic        = false;
        var cur_underline     = false;
        var cur_reverse       = false;
        var cur_strikethrough = false;
        var needs_reset       = false;

        for (0..self.rows) |ri| {
            const row: u16 = @intCast(ri);
            for (0..self.cols) |ci| {
                const col: u16 = @intCast(ci);
                const idx = @as(usize, row) * self.cols + col;
                const bc = self.back[idx];
                const fc = self.front[idx];

                if (bc.eql(fc)) continue;
                if (bc.image) continue;

                if (row != current_row or col != current_col) {
                    try escape.cursorMove(w, row + 1, col + 1);
                    current_row = row;
                    current_col = col;
                }

                const need_reset = (cur_bold          and !bc.attrs.bold) or
                    (cur_italic        and !bc.attrs.italic) or
                    (cur_underline     and !bc.attrs.underline) or
                    (cur_reverse       and !bc.attrs.reverse) or
                    (cur_strikethrough and !bc.attrs.strikethrough);

                if (need_reset or needs_reset) {
                    try escape.sgrReset(w);
                    cur_fg = .{}; cur_bg = .{};
                    cur_bold = false; cur_italic = false;
                    cur_underline = false; cur_reverse = false;
                    cur_strikethrough = false;
                    needs_reset = false;
                }

                if (bc.attrs.bold          and !cur_bold)          { try escape.sgrBold(w);          cur_bold = true; }
                if (bc.attrs.italic        and !cur_italic)        { try escape.sgrItalic(w);        cur_italic = true; }
                if (bc.attrs.underline     and !cur_underline)     { try escape.sgrUnderline(w);     cur_underline = true; }
                if (bc.attrs.reverse       and !cur_reverse)       { try escape.sgrReverse(w);       cur_reverse = true; }
                if (bc.attrs.strikethrough and !cur_strikethrough) { try escape.sgrStrikethrough(w); cur_strikethrough = true; }

                if (!colorEql(bc.fg, cur_fg)) {
                    if (bc.fg.set) try escape.sgrFg(w, bc.fg.r, bc.fg.g, bc.fg.b)
                    else try w.writeAll("\x1b[39m");
                    cur_fg = bc.fg;
                }
                if (!colorEql(bc.bg, cur_bg)) {
                    if (bc.bg.set) try escape.sgrBg(w, bc.bg.r, bc.bg.g, bc.bg.b)
                    else try w.writeAll("\x1b[49m");
                    cur_bg = bc.bg;
                }

                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(bc.codepoint, &utf8_buf) catch 1;
                try w.writeAll(utf8_buf[0..len]);

                current_col += bc.width;
                self.front[idx] = bc;
            }
        }

        try escape.sgrReset(w);
    }

    /// Force full redraw on next flush.
    pub fn invalidate(self: *Buffer) void {
        for (self.front) |*c| c.codepoint = 0xFFFFF;
    }
};

fn colorEql(a: Color, b: Color) bool {
    if (a.set != b.set) return false;
    if (!a.set) return true;
    return a.r == b.r and a.g == b.g and a.b == b.b;
}
