// Escape sequence builders — write directly to a buffered writer.
// All sequences target VT100/ANSI/xterm-256/truecolor terminals.

const std = @import("std");

// ── Alternate screen ─────────────────────────────────────────────────────────

pub fn enterAltScreen(w: anytype) !void {
    try w.writeAll("\x1b[?1049h");
}

pub fn leaveAltScreen(w: anytype) !void {
    try w.writeAll("\x1b[?1049l");
}

// ── Cursor ───────────────────────────────────────────────────────────────────

pub fn cursorHide(w: anytype) !void {
    try w.writeAll("\x1b[?25l");
}

pub fn cursorShow(w: anytype) !void {
    try w.writeAll("\x1b[?25h");
}

/// Move cursor to 1-indexed (row, col).
pub fn cursorMove(w: anytype, row: u16, col: u16) !void {
    try w.print("\x1b[{d};{d}H", .{ row, col });
}

pub fn cursorMoveHome(w: anytype) !void {
    try w.writeAll("\x1b[H");
}

// ── Erase ────────────────────────────────────────────────────────────────────

pub fn eraseScreen(w: anytype) !void {
    try w.writeAll("\x1b[2J");
}

pub fn eraseLine(w: anytype) !void {
    try w.writeAll("\x1b[2K");
}

pub fn eraseToEndOfLine(w: anytype) !void {
    try w.writeAll("\x1b[K");
}

// ── SGR (Select Graphic Rendition) ──────────────────────────────────────────

pub fn sgrReset(w: anytype) !void {
    try w.writeAll("\x1b[m");
}

pub fn sgrBold(w: anytype) !void {
    try w.writeAll("\x1b[1m");
}

pub fn sgrItalic(w: anytype) !void {
    try w.writeAll("\x1b[3m");
}

pub fn sgrUnderline(w: anytype) !void {
    try w.writeAll("\x1b[4m");
}

pub fn sgrReverse(w: anytype) !void {
    try w.writeAll("\x1b[7m");
}

/// Set foreground to 24-bit RGB.
pub fn sgrFg(w: anytype, r: u8, g: u8, b: u8) !void {
    try w.print("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
}

/// Set background to 24-bit RGB.
pub fn sgrBg(w: anytype, r: u8, g: u8, b: u8) !void {
    try w.print("\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
}

/// Set foreground to 256-color palette index.
pub fn sgrFg256(w: anytype, idx: u8) !void {
    try w.print("\x1b[38;5;{d}m", .{idx});
}

/// Set background to 256-color palette index.
pub fn sgrBg256(w: anytype, idx: u8) !void {
    try w.print("\x1b[48;5;{d}m", .{idx});
}

// ── Mouse ────────────────────────────────────────────────────────────────────

pub fn mouseEnable(w: anytype) !void {
    // SGR extended mouse (supports >223 cols), button+move events
    try w.writeAll("\x1b[?1000h\x1b[?1006h");
}

pub fn mouseDisable(w: anytype) !void {
    try w.writeAll("\x1b[?1006l\x1b[?1000l");
}

// ── Bracketed paste ──────────────────────────────────────────────────────────

pub fn bracketedPasteEnable(w: anytype) !void {
    try w.writeAll("\x1b[?2004h");
}

pub fn bracketedPasteDisable(w: anytype) !void {
    try w.writeAll("\x1b[?2004l");
}
