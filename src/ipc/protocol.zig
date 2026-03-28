// IPC message types. Zig → Bun messages are serialized with std.json.Stringify.

const std = @import("std");

// ── Wire DOM types ────────────────────────────────────────────────────────────

pub const WireStyle = struct {
    display: []const u8 = "block",
    position: []const u8 = "static",
    width: ?f64 = null,
    height: ?f64 = null,
    margin:          [4]f64 = .{0, 0, 0, 0},
    padding:         [4]f64 = .{0, 0, 0, 0},
    border_width:    [4]f64 = .{0, 0, 0, 0},
    border_style:    []const u8 = "none",
    border_color:    [4]f64 = .{0, 0, 0, 0},
    color:           [4]f64 = .{255, 255, 255, 255},
    background_color:[4]f64 = .{0, 0, 0, 0},
    font_size:        f64 = 16,
    font_weight:      []const u8 = "normal",
    font_style:       []const u8 = "normal",
    text_decoration:  []const u8 = "none",
    text_align:       []const u8 = "left",
    white_space:      []const u8 = "normal",
    line_height:      f64 = 1.4,
    overflow_x:       []const u8 = "visible",
    overflow_y:       []const u8 = "visible",
    visibility:       []const u8 = "visible",
    opacity:          f64 = 1,
    // Flex container
    flex_direction:  []const u8 = "row",
    flex_wrap:       []const u8 = "nowrap",
    justify_content: []const u8 = "flex-start",
    align_items:     []const u8 = "stretch",
    // Flex item
    flex_grow:   f64 = 0,
    flex_shrink: f64 = 1,
    flex_basis:  f64 = -1,  // -1=auto, >=0=px, <-1=percent (e.g. -50.0=50%)
};

pub const NodeType = enum { element, text, comment, doctype };

pub const WireNode = struct {
    id:       u32,
    type:     NodeType,
    tag:      ?[]const u8 = null,
    text:     ?[]const u8 = null,
    href:     ?[]const u8 = null,
    style:    WireStyle   = .{},
    children: ?[]WireNode = null,
};

// ── Bun → Zig message types ───────────────────────────────────────────────────

pub const DomReadyMsg = struct {
    id:    u32,
    url:   []const u8,
    title: []const u8,
    root:  WireNode,
};

pub const ErrorMsg = struct {
    id:      u32,
    code:    i32,
    message: []const u8,
};

pub const NavigateRequestMsg = struct {
    url:          []const u8,
    push_history: bool,
};

pub const TitleChangedMsg = struct {
    title: []const u8,
};
