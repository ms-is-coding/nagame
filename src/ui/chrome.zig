// Tab bar, address bar, and status bar rendering.

const std = @import("std");
const Buffer = @import("../render/buffer.zig").Buffer;
const Cell = @import("../render/cell.zig").Cell;
const Color = @import("../render/cell.zig").Color;

const SPINNER_FRAMES = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
// const SPINNER_FRAMES = [_][]const u8{ "⠋", "⠙", "⠚", "⠖", "⠦", "⠴", "⠲", "⠓" };

// Color palette — deep navy theme
const COL_CHROME_BG   = Color{ .r = 26,  .g = 26,  .b = 46,  .set = true }; // deep navy
const COL_CHROME_FG   = Color{ .r = 224, .g = 224, .b = 224, .set = true }; // light gray
const COL_ADDR_BG     = Color{ .r = 15,  .g = 52,  .b = 96,  .set = true }; // dark blue
const COL_ADDR_FG     = Color{ .r = 224, .g = 224, .b = 224, .set = true };
const COL_STATUS_BG   = Color{ .r = 10,  .g = 10,  .b = 26,  .set = true }; // near-black
const COL_STATUS_FG   = Color{ .r = 136, .g = 136, .b = 136, .set = true }; // medium gray
const COL_ACCENT_LOAD = Color{ .r = 245, .g = 166, .b = 35,  .set = true }; // amber (loading)
const COL_ACCENT_DONE = Color{ .r = 233, .g = 69,  .b = 96,  .set = true }; // red-pink (loaded)
const COL_ACCENT_HTTPS= Color{ .r = 78,  .g = 204, .b = 163, .set = true }; // teal-green (https)
const COL_ACCENT_HTTP = Color{ .r = 233, .g = 69,  .b = 96,  .set = true }; // red-pink (http warning)

pub fn renderChrome(
    buf: *Buffer,
    title: []const u8,
    url: []const u8,
    status: []const u8,
    loading: bool,
    spinner_frame: u8,
    scroll_row: u32,
    total_lines: u32,
) void {
    renderTabBar(buf, title, loading, spinner_frame);
    renderAddressBar(buf, url, loading);
    renderStatusBar(buf, status, scroll_row, total_lines);
}

fn renderTabBar(buf: *Buffer, title: []const u8, loading: bool, spinner_frame: u8) void {
    fillRow(buf, 0, ' ', COL_CHROME_FG, COL_CHROME_BG);

    var col: u16 = 1; // left padding

    // Spinner or bullet
    if (loading) {
        const frame = SPINNER_FRAMES[spinner_frame % SPINNER_FRAMES.len];
        col = writeStr(buf, 0, col, frame, COL_ACCENT_LOAD, COL_CHROME_BG);
        col = writeStr(buf, 0, col, " ", COL_CHROME_FG, COL_CHROME_BG);
    } else {
        col = writeStr(buf, 0, col, "● ", COL_ACCENT_DONE, COL_CHROME_BG);
    }

    // Title (truncated)
    const max_title = buf.cols -| (col + 2);
    const display_title = truncate(title, max_title);
    _ = writeStr(buf, 0, col, display_title, COL_CHROME_FG, COL_CHROME_BG);
}

fn renderAddressBar(buf: *Buffer, url: []const u8, loading: bool) void {
    fillRow(buf, 1, ' ', COL_ADDR_FG, COL_ADDR_BG);

    var col: u16 = 1;

    // Protocol security indicator
    const is_https = std.mem.startsWith(u8, url, "https://");
    const is_http  = std.mem.startsWith(u8, url, "http://");
    if (is_https) {
        col = writeStr(buf, 1, col, "🔒", COL_ACCENT_HTTPS, COL_ADDR_BG);
        col = writeStr(buf, 1, col, " ", COL_ADDR_FG, COL_ADDR_BG);
    } else if (is_http) {
        col = writeStr(buf, 1, col, "⚠ ", COL_ACCENT_HTTP, COL_ADDR_BG);
    } else if (loading) {
        col = writeStr(buf, 1, col, "  ", COL_ADDR_FG, COL_ADDR_BG);
    } else {
        col = writeStr(buf, 1, col, "  ", COL_ADDR_FG, COL_ADDR_BG);
    }

    // Display URL or placeholder
    const display = if (url.len > 0) url else "about:blank";
    const max = buf.cols -| (col + 1);
    _ = writeStr(buf, 1, col, truncate(display, max), COL_ADDR_FG, COL_ADDR_BG);
}

fn renderStatusBar(buf: *Buffer, status: []const u8, scroll_row: u32, total_lines: u32) void {
    if (buf.rows == 0) return;
    const row = buf.rows - 1;
    fillRow(buf, row, ' ', COL_STATUS_FG, COL_STATUS_BG);

    // Left: status message or hint
    if (status.len > 0) {
        const max = buf.cols -| 20;
        _ = writeStr(buf, row, 1, truncate(status, max), COL_STATUS_FG, COL_STATUS_BG);
    } else {
        _ = writeStr(buf, row, 1, "q:quit  o:open  j/k:scroll", COL_STATUS_FG, COL_STATUS_BG);
    }

    // Right: scroll position
    if (total_lines > 0 and buf.cols >= 12) {
        var pos_buf: [24]u8 = undefined;
        const pos = std.fmt.bufPrint(&pos_buf, "↕{d}/{d} ", .{ scroll_row + 1, total_lines }) catch return;
        const pos_col = buf.cols -| @as(u16, @intCast(pos.len));
        _ = writeStr(buf, row, pos_col, pos, COL_STATUS_FG, COL_STATUS_BG);
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn fillRow(buf: *Buffer, row: u16, cp: u21, fg: Color, bg: Color) void {
    for (0..buf.cols) |c| {
        buf.setBack(@intCast(c), row, .{ .codepoint = cp, .fg = fg, .bg = bg });
    }
}

/// Write a UTF-8 string into the buffer at (row, start_col), return next col.
fn writeStr(buf: *Buffer, row: u16, start_col: u16, s: []const u8, fg: Color, bg: Color) u16 {
    var col = start_col;
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        if (col >= buf.cols) break;
        buf.setBack(col, row, .{ .codepoint = cp, .fg = fg, .bg = bg });
        col += 1;
    }
    return col;
}

/// Truncate UTF-8 string to at most `max_cols` display columns.
fn truncate(s: []const u8, max_cols: u16) []const u8 {
    var cols: u16 = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var last_valid: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        cols += 1;
        if (cols > max_cols) return s[0..last_valid];
        last_valid += slice.len;
    }
    return s;
}
