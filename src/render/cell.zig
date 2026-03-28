// Terminal cell: holds one display character with its attributes.

pub const Attrs = packed struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    _pad: u4 = 0,
};

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    /// true = truecolor RGB, false = default terminal color
    set: bool = false,
};

pub const Cell = struct {
    /// Unicode codepoint. 0 = empty / continuation of wide char.
    codepoint: u21 = ' ',
    fg: Color = .{},
    bg: Color = .{},
    attrs: Attrs = .{},
    /// If true, this cell is occupied by an image; skip text rendering.
    image: bool = false,
    /// Width in columns (1 = normal, 2 = wide CJK/emoji).
    width: u2 = 1,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.codepoint == other.codepoint and
            std.meta.eql(self.fg, other.fg) and
            std.meta.eql(self.bg, other.bg) and
            std.meta.eql(self.attrs, other.attrs) and
            self.image == other.image;
    }
};

const std = @import("std");
