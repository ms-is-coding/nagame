// Terminal resize handling via SIGWINCH + ioctl TIOCGWINSZ.

const std = @import("std");
const posix = std.posix;

pub const Size = struct {
    cols: u16,
    rows: u16,
    px_width: u16,
    px_height: u16,
};

/// Atomic flag set by SIGWINCH handler; main loop checks and resets.
pub var resize_pending = std.atomic.Value(bool).init(false);

/// Query current terminal dimensions via ioctl.
pub fn getSize() !Size {
    var ws: posix.winsize = undefined;
    const rc = std.c.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, &ws);
    if (rc != 0) return error.IoctlFailed;
    return .{
        .cols      = ws.col,
        .rows      = ws.row,
        .px_width  = ws.xpixel,
        .px_height = ws.ypixel,
    };
}

fn sigwinchHandler(_: c_int) callconv(.c) void {
    resize_pending.store(true, .release);
}

pub fn installSigwinch() void {
    var sa = posix.Sigaction{
        .handler = .{ .handler = sigwinchHandler },
        .mask    = posix.sigemptyset(),
        .flags   = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
}
