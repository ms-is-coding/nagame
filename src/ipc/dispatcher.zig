// Dispatch incoming IPC messages to typed handlers.

const std = @import("std");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

pub const Handler = struct {
    on_ready: *const fn () void = noopVoid,
    on_dom_ready: *const fn (msg: protocol.DomReadyMsg, arena: *std.heap.ArenaAllocator) void = noopDomReady,
    on_error: *const fn (msg: protocol.ErrorMsg) void = noopError,
    on_navigate_request: *const fn (msg: protocol.NavigateRequestMsg) void = noopNavigateRequest,
    on_title_changed: *const fn (msg: protocol.TitleChangedMsg) void = noopTitleChanged,
};

fn noopVoid() void {}
fn noopDomReady(_: protocol.DomReadyMsg, _: *std.heap.ArenaAllocator) void {}
fn noopError(_: protocol.ErrorMsg) void {}
fn noopNavigateRequest(_: protocol.NavigateRequestMsg) void {}
fn noopTitleChanged(_: protocol.TitleChangedMsg) void {}

/// Parse and dispatch a raw JSON message from the queue.
/// Uses `arena` for all allocations; caller resets the arena after each call.
pub fn dispatch(json: []const u8, arena: *std.heap.ArenaAllocator, h: Handler) void {
    const allocator = arena.allocator();

    // Parse into a generic JSON value to inspect the "type" field
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        std.log.err("ipc: JSON parse error: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    const type_val = root.object.get("type") orelse return;
    if (type_val != .string) return;
    const msg_type = type_val.string;

    if (std.mem.eql(u8, msg_type, "ready")) {
        h.on_ready();
    } else if (std.mem.eql(u8, msg_type, "dom_ready")) {
        if (parseDomReady(root, allocator)) |msg| {
            h.on_dom_ready(msg, arena);
        } else |err| {
            std.log.err("ipc: dom_ready parse error: {}", .{err});
        }
    } else if (std.mem.eql(u8, msg_type, "error")) {
        if (parseError(root, allocator)) |msg| {
            h.on_error(msg);
        } else |err| {
            std.log.err("ipc: error parse error: {}", .{err});
        }
    } else if (std.mem.eql(u8, msg_type, "navigate_request")) {
        if (parseNavigateRequest(root, allocator)) |msg| {
            h.on_navigate_request(msg);
        } else |err| {
            std.log.err("ipc: navigate_request parse error: {}", .{err});
        }
    } else if (std.mem.eql(u8, msg_type, "title_changed")) {
        if (parseTitleChanged(root, allocator)) |msg| {
            h.on_title_changed(msg);
        } else |err| {
            std.log.err("ipc: title_changed parse error: {}", .{err});
        }
    }
}

fn getString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getInt(obj: std.json.Value, key: []const u8) ?i64 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

fn parseDomReady(root: std.json.Value, allocator: std.mem.Allocator) !protocol.DomReadyMsg {
    const id_v = getInt(root, "id") orelse return error.MissingField;
    const url_v = getString(root, "url") orelse return error.MissingField;
    const title_v = getString(root, "title") orelse return error.MissingField;

    const root_node_v = root.object.get("root") orelse return error.MissingField;
    const root_node = try parseNode(root_node_v, allocator);

    return .{
        .id    = @intCast(id_v),
        .url   = try allocator.dupe(u8, url_v),
        .title = try allocator.dupe(u8, title_v),
        .root  = root_node,
    };
}

fn parseNode(v: std.json.Value, allocator: std.mem.Allocator) !protocol.WireNode {
    if (v != .object) return error.InvalidNode;

    const id_v  = getInt(v, "id") orelse return error.MissingId;
    const type_s = getString(v, "type") orelse "element";

    const node_type: protocol.NodeType = blk: {
        if (std.mem.eql(u8, type_s, "text")) break :blk .text;
        if (std.mem.eql(u8, type_s, "comment")) break :blk .comment;
        if (std.mem.eql(u8, type_s, "doctype")) break :blk .doctype;
        break :blk .element;
    };

    var node = protocol.WireNode{
        .id   = @intCast(id_v),
        .type = node_type,
        .tag  = if (getString(v, "tag")) |t| try allocator.dupe(u8, t) else null,
        .text = if (getString(v, "text")) |t| try allocator.dupe(u8, t) else null,
        .href = if (getString(v, "href")) |h| try allocator.dupe(u8, h) else null,
        .style = parseStyle(v.object.get("style") orelse .null),
    };

    if (v.object.get("children")) |children_v| {
        if (children_v == .array) {
            const children = try allocator.alloc(protocol.WireNode, children_v.array.items.len);
            for (children_v.array.items, 0..) |child, i| {
                children[i] = try parseNode(child, allocator);
            }
            node.children = children;
        }
    }

    return node;
}

fn parseStyle(v: std.json.Value) protocol.WireStyle {
    var s = protocol.WireStyle{};
    if (v != .object) return s;

    if (getString(v, "display")) |d| s.display = d;
    if (getString(v, "font_weight")) |fw| s.font_weight = fw;
    if (getString(v, "font_style")) |fs| s.font_style = fs;
    if (getString(v, "text_decoration")) |td| s.text_decoration = td;
    if (getString(v, "text_align")) |ta| s.text_align = ta;
    if (getString(v, "white_space")) |ws| s.white_space = ws;
    if (getString(v, "visibility")) |vis| s.visibility = vis;

    // Parse RGBA color arrays
    s.color = parseRgba(v.object.get("color"));
    s.background_color = parseRgba(v.object.get("background_color"));

    if (v.object.get("font_size")) |fs| {
        s.font_size = jsonFloat(fs);
    }
    if (v.object.get("opacity")) |op| {
        s.opacity = jsonFloat(op);
    }
    if (v.object.get("line_height")) |lh| {
        s.line_height = jsonFloat(lh);
    }

    // Flex fields
    if (getString(v, "flex_direction"))  |d| s.flex_direction  = d;
    if (getString(v, "flex_wrap"))       |d| s.flex_wrap        = d;
    if (getString(v, "justify_content")) |d| s.justify_content  = d;
    if (getString(v, "align_items"))     |d| s.align_items      = d;
    if (v.object.get("flex_grow"))   |n| s.flex_grow   = jsonFloat(n);
    if (v.object.get("flex_shrink")) |n| s.flex_shrink  = jsonFloat(n);
    if (v.object.get("flex_basis"))  |n| s.flex_basis   = jsonFloat(n);
    if (v.object.get("width"))       |n| switch (n) {
        .float, .integer => s.width = jsonFloat(n),
        else => {},
    };

    return s;
}

fn parseRgba(v_opt: ?std.json.Value) [4]f64 {
    const v = v_opt orelse return .{255, 255, 255, 255};
    if (v != .array or v.array.items.len < 4) return .{255, 255, 255, 255};
    return .{
        jsonFloat(v.array.items[0]),
        jsonFloat(v.array.items[1]),
        jsonFloat(v.array.items[2]),
        jsonFloat(v.array.items[3]),
    };
}

fn jsonFloat(v: std.json.Value) f64 {
    return switch (v) {
        .float   => |f| f,
        .integer => |n| @floatFromInt(n),
        else => 0,
    };
}

fn parseError(root: std.json.Value, allocator: std.mem.Allocator) !protocol.ErrorMsg {
    const id_v  = getInt(root, "id") orelse 0;
    const code_v = getInt(root, "code") orelse 0;
    const msg_v = getString(root, "message") orelse "unknown error";
    return .{
        .id      = @intCast(id_v),
        .code    = @intCast(code_v),
        .message = try allocator.dupe(u8, msg_v),
    };
}

fn parseNavigateRequest(root: std.json.Value, allocator: std.mem.Allocator) !protocol.NavigateRequestMsg {
    const url_v = getString(root, "url") orelse return error.MissingField;
    const push_v = root.object.get("push_history");
    return .{
        .url = try allocator.dupe(u8, url_v),
        .push_history = if (push_v) |pv| pv == .bool and pv.bool else true,
    };
}

fn parseTitleChanged(root: std.json.Value, allocator: std.mem.Allocator) !protocol.TitleChangedMsg {
    const title_v = getString(root, "title") orelse "";
    return .{ .title = try allocator.dupe(u8, title_v) };
}
