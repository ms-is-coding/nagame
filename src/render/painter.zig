// Phase 1: simple text painter — word-wraps text content into the cell buffer.
// Phase 3 will replace this with a full layout-tree walker.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Cell = @import("cell.zig").Cell;
const Color = @import("cell.zig").Color;

pub const CHROME_TOP_ROWS: u16 = 2;    // tab bar + address bar
pub const CHROME_BOTTOM_ROWS: u16 = 1; // status bar

/// Fill the content area of the buffer with plain text, word-wrapped.
/// `text` is the raw page text content.
/// `scroll_row` is the first visible line (0-indexed).
pub fn paintText(
    buf: *Buffer,
    text: []const u8,
    scroll_row: u32,
    fg: Color,
    bg: Color,
) void {
    if (buf.rows <= CHROME_TOP_ROWS + CHROME_BOTTOM_ROWS or buf.cols == 0) return;
    const content_rows = buf.rows - (CHROME_TOP_ROWS + CHROME_BOTTOM_ROWS);
    const content_cols = buf.cols;

    // Fill background
    for (CHROME_TOP_ROWS..buf.rows - CHROME_BOTTOM_ROWS) |ri| {
        for (0..buf.cols) |ci| {
            buf.setBack(@intCast(ci), @intCast(ri), .{
                .codepoint = ' ',
                .fg = fg,
                .bg = bg,
            });
        }
    }

    // Word-wrap text into lines
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.heap.page_allocator);

    var line_start: usize = 0;
    var col_count: u16 = 0;
    var last_space: ?usize = null;

    var i: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch ' ';
        if (cp == '\n') {
            lines.append(std.heap.page_allocator, text[line_start..i]) catch break;
            i += slice.len;
            line_start = i;
            col_count = 0;
            last_space = null;
            continue;
        }
        const w: u16 = if (cp == ' ' or cp == '\t') 1 else charWidth(cp);
        i += slice.len;
        if (cp == ' ') last_space = i;

        col_count += w;
        if (col_count >= content_cols) {
            // Wrap at last space if available
            const wrap_at = last_space orelse i - slice.len;
            lines.append(std.heap.page_allocator, text[line_start..wrap_at]) catch break;
            line_start = if (last_space != null) wrap_at else wrap_at;
            col_count = 0;
            last_space = null;
        }
    }
    // Last line
    if (line_start < text.len) {
        lines.append(std.heap.page_allocator, text[line_start..]) catch {};
    }

    // Render visible lines
    const first_line = scroll_row;
    for (0..content_rows) |screen_ri| {
        const line_idx = first_line + screen_ri;
        if (line_idx >= lines.items.len) break;
        const line = lines.items[line_idx];

        const row: u16 = @intCast(CHROME_TOP_ROWS + screen_ri);
        var col: u16 = 0;
        var it = std.unicode.Utf8Iterator{ .bytes = line, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (col >= content_cols) break;
            const w: u16 = @max(1, charWidth(cp));
            buf.setBack(col, row, .{
                .codepoint = cp,
                .fg = fg,
                .bg = bg,
                .width = @intCast(w),
            });
            col += w;
        }
    }
}

fn charWidth(cp: u21) u16 {
    // Very simplified: CJK unified ideographs + fullwidth = 2, else 1
    if (cp >= 0x1100 and cp <= 0x115F) return 2;
    if (cp >= 0x2E80 and cp <= 0xA4CF) return 2;
    if (cp >= 0xAC00 and cp <= 0xD7AF) return 2;
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    if (cp >= 0xFF01 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
    if (cp >= 0x1F300 and cp <= 0x1FBFF) return 2;
    return 1;
}
