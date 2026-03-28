// Terminal initialization: raw mode, alternate screen, cleanup.

const std = @import("std");
const posix = std.posix;

var original_termios: posix.termios = undefined;
var raw_mode_active = false;

/// Enter raw mode: disable echo, canonical mode, signals from special keys.
pub fn enableRawMode() !void {
    const fd = posix.STDIN_FILENO;
    original_termios = try posix.tcgetattr(fd);

    var raw = original_termios;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL  = false;
    raw.iflag.INPCK  = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON   = false;
    raw.oflag.OPOST  = false;
    raw.cflag.CSIZE  = .CS8;
    raw.lflag.ECHO   = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG   = false;
    raw.cc[@intFromEnum(posix.V.MIN)]  = 0; // do not require a byte before returning
    raw.cc[@intFromEnum(posix.V.TIME)] = 1; // return after 100ms even with no input

    try posix.tcsetattr(fd, .FLUSH, raw);
    raw_mode_active = true;
}

pub fn disableRawMode() void {
    if (!raw_mode_active) return;
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original_termios) catch {};
    raw_mode_active = false;
}

/// Enter alternate screen buffer and hide cursor.
pub fn enterAltScreen() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h\x1b[?2004h");
}

/// Leave alternate screen, restore cursor.
pub fn leaveAltScreen() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll("\x1b[?2004l\x1b[?1006l\x1b[?1000l\x1b[?1049l\x1b[?25h") catch {};
}

/// Full terminal setup.
pub fn setup() !void {
    try enableRawMode();
    try enterAltScreen();
}

/// Full terminal teardown. Safe to call multiple times.
pub fn teardown() void {
    leaveAltScreen();
    disableRawMode();
}
