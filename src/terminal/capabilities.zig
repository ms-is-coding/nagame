// Terminal capability detection: image protocols, true color, Unicode width.

const std = @import("std");

pub const ImageProtocol = enum {
    kitty,
    sixel,
    halfblock, // Unicode half-block fallback
};

pub const TermCaps = struct {
    image_protocol: ImageProtocol = .halfblock,
    true_color: bool = false,
    unicode_wide: bool = true,
};

/// Detect capabilities from environment variables.
/// DA1/DA2 query detection is deferred to a future enhancement.
pub fn detect() TermCaps {
    var caps = TermCaps{};

    // True color detection
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLORTERM")) |v| {
        defer std.heap.page_allocator.free(v);
        if (std.mem.eql(u8, v, "truecolor") or std.mem.eql(u8, v, "24bit")) {
            caps.true_color = true;
        }
    } else |_| {}

    // Image protocol detection via $TERM_PROGRAM and $TERM
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "TERM_PROGRAM")) |v| {
        defer std.heap.page_allocator.free(v);
        if (std.mem.eql(u8, v, "kitty")) {
            caps.image_protocol = .kitty;
            caps.true_color = true;
        } else if (std.mem.eql(u8, v, "WezTerm")) {
            caps.image_protocol = .kitty;
            caps.true_color = true;
        } else if (std.mem.eql(u8, v, "iTerm.app")) {
            caps.image_protocol = .sixel;
            caps.true_color = true;
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(std.heap.page_allocator, "TERM")) |v| {
        defer std.heap.page_allocator.free(v);
        if (std.mem.eql(u8, v, "xterm-kitty")) {
            caps.image_protocol = .kitty;
            caps.true_color = true;
        } else if (std.mem.startsWith(u8, v, "xterm")) {
            // xterm generally supports sixel when compiled with it
            if (caps.image_protocol == .halfblock) {
                caps.image_protocol = .sixel;
            }
            caps.true_color = true;
        }
    } else |_| {}

    return caps;
}
