// Application state and event processing.

const std = @import("std");
const resize_mod  = @import("terminal/resize.zig");
const input_mod   = @import("terminal/input.zig");
const kb          = @import("ui/keybindings.zig");
const compositor  = @import("render/compositor.zig");
const Buffer      = @import("render/buffer.zig").Buffer;
const transport   = @import("ipc/transport.zig");
const dispatcher  = @import("ipc/dispatcher.zig");
const protocol    = @import("ipc/protocol.zig");

const SCROLL_STEP      = 3;
const SCROLL_HALF_STEP = 15;

pub const AppMode = enum { normal, address_bar };

const LinkInfo = struct {
    id:   u32,
    href: []const u8,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    buf:       Buffer,
    state:     compositor.CompositorState,
    mode:      AppMode,

    addr_buf: [2048]u8,
    addr_len: usize,

    next_id:     u32,
    total_lines: u32,

    bun_stdin: std.fs.File,  // write navigate/resize commands to Bun
    stdout:    std.fs.File,  // write rendered output

    msg_queue:  *transport.MsgQueue,
    msg_arena:  std.heap.ArenaAllocator,
    page_arena: std.heap.ArenaAllocator, // lifetime: one page; reset on new navigate

    running: bool,

    links:        []LinkInfo = &.{},
    focused_link: ?usize    = null,

    // Storage for strings owned by this App (freed on deinit)
    owned_title:  ?[]u8 = null,
    owned_url:    ?[]u8 = null,
    owned_status: ?[]u8 = null,
    owned_text:   ?[]u8 = null,
    owned_root:   ?protocol.WireNode = null,

    pub fn init(
        allocator: std.mem.Allocator,
        cols:      u16,
        rows:      u16,
        bun_stdin: std.fs.File,
        stdout:    std.fs.File,
        msg_queue: *transport.MsgQueue,
    ) !App {
        return .{
            .allocator   = allocator,
            .buf         = try Buffer.init(allocator, cols, rows),
            .state       = .{},
            .mode        = .normal,
            .addr_buf    = undefined,
            .addr_len    = 0,
            .next_id     = 1,
            .total_lines = 1,
            .bun_stdin   = bun_stdin,
            .stdout      = stdout,
            .msg_queue   = msg_queue,
            .msg_arena   = std.heap.ArenaAllocator.init(allocator),
            .page_arena  = std.heap.ArenaAllocator.init(allocator),
            .running     = true,
        };
    }

    pub fn deinit(self: *App) void {
        self.buf.deinit();
        self.msg_arena.deinit();
        self.page_arena.deinit();
        if (self.owned_title)  |s| self.allocator.free(s);
        if (self.owned_url)    |s| self.allocator.free(s);
        if (self.owned_status) |s| self.allocator.free(s);
        if (self.owned_text)   |s| self.allocator.free(s);
    }

    // ── Render ───────────────────────────────────────────────────────────────

    pub fn render(self: *App) !void {
        compositor.compose(&self.buf, &self.state);
        try self.buf.flush(self.stdout);

        // Cursor: visible and positioned in address bar, hidden during page view
        var esc: [32]u8 = undefined;
        if (self.mode == .address_bar) {
            // Protocol indicator width (cols before the URL text)
            const url = self.state.url;
            const indicator: u16 = if (std.mem.startsWith(u8, url, "https://")) 4 else 3;
            const addr_cols = @min(@as(u16, @intCast(self.addr_len)), self.buf.cols -| indicator -| 1);
            const cur_col = indicator + addr_cols; // 0-indexed column
            const seq = std.fmt.bufPrint(&esc, "\x1b[?25h\x1b[2;{d}H", .{ cur_col + 1 }) catch return;
            try self.stdout.writeAll(seq);
        } else {
            try self.stdout.writeAll("\x1b[?25l");
        }
    }

    // ── Input ────────────────────────────────────────────────────────────────

    pub fn handleInput(self: *App, event: input_mod.InputEvent) !void {
        switch (event) {
            .resize => try self.handleResize(),
            .key    => |k| switch (self.mode) {
                .normal      => try self.handleNormalKey(k),
                .address_bar => try self.handleAddressKey(k),
            },
            .mouse  => |m| self.handleMouse(m),
            .paste  => |text| {
                if (self.mode == .address_bar) self.appendAddr(text);
                self.allocator.free(text);
            },
        }
    }

    fn handleNormalKey(self: *App, key: input_mod.Key) !void {
        switch (kb.keyToAction(key)) {
            .quit              => self.running = false,
            .scroll_down       => self.scroll(SCROLL_STEP),
            .scroll_up         => self.scroll(-SCROLL_STEP),
            .scroll_half_down  => self.scroll(SCROLL_HALF_STEP),
            .scroll_half_up    => self.scroll(-SCROLL_HALF_STEP),
            .scroll_top        => self.state.scroll_row = 0,
            .scroll_bottom     => { if (self.total_lines > 0) self.state.scroll_row = self.total_lines - 1; },
            .open_address_bar  => {
                self.mode = .address_bar;
                const url = self.state.url;
                const n = @min(url.len, self.addr_buf.len);
                @memcpy(self.addr_buf[0..n], url[0..n]);
                self.addr_len = n;
            },
            .next_link => {
                if (self.links.len > 0) {
                    self.focused_link = if (self.focused_link) |i| (i + 1) % self.links.len else 0;
                    self.state.focused_link_id = self.links[self.focused_link.?].id;
                }
            },
            .prev_link => {
                if (self.links.len > 0) {
                    self.focused_link = if (self.focused_link) |i|
                        if (i == 0) self.links.len - 1 else i - 1
                    else
                        self.links.len - 1;
                    self.state.focused_link_id = self.links[self.focused_link.?].id;
                }
            },
            .activate_link => {
                if (self.focused_link) |i| {
                    const href = self.links[i].href;
                    std.log.info("URL {s}", .{ href });
                    try self.navigate(resolveUrl(self.state.url, href));
                }
            },
            else => {},
        }
    }

    fn handleAddressKey(self: *App, key: input_mod.Key) !void {
        switch (key) {
            .enter => {
                self.mode = .normal;
                try self.navigate(self.addr_buf[0..self.addr_len]);
            },
            .escape => self.mode = .normal,
            .backspace => {
                if (self.addr_len > 0) self.addr_len -= 1;
                self.state.url = self.addr_buf[0..self.addr_len];
            },
            .char => |cp| {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &tmp) catch 1;
                self.appendAddr(tmp[0..n]);
            },
            else => {},
        }
    }

    fn handleMouse(self: *App, m: input_mod.MouseEvent) void {
        switch (m.action) {
            .press => switch (m.button) {
                .wheel_up   => self.scroll(-SCROLL_STEP),
                .wheel_down => self.scroll(SCROLL_STEP),
                else => {},
            },
            else => {},
        }
    }

    fn handleResize(self: *App) !void {
        const size = resize_mod.getSize() catch return;
        try self.buf.resize(size.cols, size.rows);
        self.buf.invalidate();
        try transport.sendMsg(self.bun_stdin, self.allocator, .{
            .type      = "resize",
            .cols      = size.cols,
            .rows      = size.rows,
            .px_width  = size.px_width,
            .px_height = size.px_height,
        });
    }

    // ── IPC ──────────────────────────────────────────────────────────────────

    pub fn processMessages(self: *App) void {
        while (self.msg_queue.tryPop()) |item| {
            defer self.allocator.free(item.json);
            _ = self.msg_arena.reset(.retain_capacity);
            const h = dispatcher.Handler{
                .on_ready            = onReady,
                .on_dom_ready        = onDomReadyGlobal,
                .on_error            = onErrorGlobal,
                .on_navigate_request = onNavigateRequestGlobal,
                .on_title_changed    = onTitleChangedGlobal,
            };
            dispatcher.dispatch(item.json, &self.msg_arena, h);
        }
    }

    fn onReady() void {
        std.log.debug("bun worker ready", .{});
    }

    // ── Navigation ───────────────────────────────────────────────────────────

    pub fn navigate(self: *App, url: []const u8) !void {
        var scheme_buf: [2048]u8 = undefined;
        var full_url = url;
        if (!std.mem.startsWith(u8, url, "http://") and
            !std.mem.startsWith(u8, url, "https://") and
            !std.mem.startsWith(u8, url, "about:"))
        {
            full_url = try std.fmt.bufPrint(&scheme_buf, "https://{s}", .{url});
        }

        const id = self.next_id;
        self.next_id +%= 1;

        // Clear previous page DOM
        _ = self.page_arena.reset(.retain_capacity);
        self.owned_root = null;
        self.state.root = null;
        self.links = &.{};
        self.focused_link = null;
        self.state.focused_link_id = null;

        self.setStatus("Loading…");
        self.setUrl(full_url);
        self.state.loading = true;

        try transport.sendMsg(self.bun_stdin, self.allocator, .{
            .type = "navigate",
            .id   = id,
            .url  = full_url,
        });
    }

    // ── String ownership ──────────────────────────────────────────────────────

    fn setTitle(self: *App, s: []const u8) void {
        if (self.owned_title) |old| self.allocator.free(old);
        self.owned_title = self.allocator.dupe(u8, s) catch null;
        self.state.title = self.owned_title orelse s;
    }

    fn setUrl(self: *App, s: []const u8) void {
        if (self.owned_url) |old| self.allocator.free(old);
        self.owned_url = self.allocator.dupe(u8, s) catch null;
        self.state.url = self.owned_url orelse s;
    }

    fn setStatus(self: *App, s: []const u8) void {
        if (self.owned_status) |old| self.allocator.free(old);
        self.owned_status = self.allocator.dupe(u8, s) catch null;
        self.state.status = self.owned_status orelse s;
    }

    fn setText(self: *App, s: []const u8) void {
        if (self.owned_text) |old| self.allocator.free(old);
        self.owned_text = self.allocator.dupe(u8, s) catch null;
        self.state.text_content = self.owned_text orelse s;
        self.total_lines = @intCast(std.mem.count(u8, self.state.text_content, "\n") + 1);
        self.state.total_lines = self.total_lines;
    }

    fn setRoot(self: *App, root: protocol.WireNode) void {
        _ = self.page_arena.reset(.retain_capacity);
        self.focused_link = null;
        self.state.focused_link_id = null;
        const cloned = cloneNode(self.page_arena.allocator(), root) catch null;
        self.owned_root = cloned;
        self.state.root = if (self.owned_root) |*r| r else null;
        self.extractLinks();
    }

    fn extractLinks(self: *App) void {
        self.links = &.{};
        if (self.owned_root) |*root| {
            var list = std.ArrayListUnmanaged(LinkInfo){};
            collectLinks(root, &list, self.page_arena.allocator());
            self.links = list.toOwnedSlice(self.page_arena.allocator()) catch &.{};
        }
    }

    // ── Scroll ────────────────────────────────────────────────────────────────

    fn scroll(self: *App, delta: i32) void {
        if (delta < 0) {
            const abs: u32 = @intCast(-delta);
            self.state.scroll_row = self.state.scroll_row -| abs;
        } else {
            const total = self.state.total_lines;
            const max: u32 = if (total > 0) total - 1 else 0;
            self.state.scroll_row = @min(self.state.scroll_row + @as(u32, @intCast(delta)), max);
        }
    }

    fn appendAddr(self: *App, text: []const u8) void {
        const n = @min(text.len, self.addr_buf.len - self.addr_len);
        @memcpy(self.addr_buf[self.addr_len..][0..n], text[0..n]);
        self.addr_len += n;
        self.state.url = self.addr_buf[0..self.addr_len];
    }
};

// ── Global app pointer for callbacks (Zig has no closures) ────────────────────

var g_app: ?*App = null;

fn onDomReadyGlobal(msg: protocol.DomReadyMsg, _: *std.heap.ArenaAllocator) void {
    const app = g_app orelse return;
    app.state.loading = false;
    app.state.scroll_row = 0;
    app.setTitle(msg.title);
    app.setUrl(msg.url);
    app.setStatus("");
    app.setRoot(msg.root);
    app.state.text_content = ""; // clear fallback text
}

fn onErrorGlobal(msg: protocol.ErrorMsg) void {
    const app = g_app orelse return;
    app.state.loading = false;
    app.setStatus(msg.message);
    app.setText(msg.message);
}

fn onNavigateRequestGlobal(msg: protocol.NavigateRequestMsg) void {
    const app = g_app orelse return;
    app.navigate(msg.url) catch {};
}

fn onTitleChangedGlobal(msg: protocol.TitleChangedMsg) void {
    const app = g_app orelse return;
    app.setTitle(msg.title);
}

/// Must be called before processMessages to bind the global.
pub fn setGlobalApp(app: *App) void {
    g_app = app;
}

// ── Link helpers ──────────────────────────────────────────────────────────────

fn collectLinks(node: *const protocol.WireNode, out: *std.ArrayListUnmanaged(LinkInfo), alloc: std.mem.Allocator) void {
    if (node.href) |href| {
        out.append(alloc, .{ .id = node.id, .href = href }) catch {};
    }
    if (node.children) |children| {
        for (children) |*child| collectLinks(child, out, alloc);
    }
}

fn resolveUrl(base: []const u8, href: []const u8) []const u8 {
    if (std.mem.startsWith(u8, href, "http://") or
        std.mem.startsWith(u8, href, "https://") or
        std.mem.startsWith(u8, href, "about:")) return href;
    _ = base;
    return href; // navigate() will prepend https:// for bare hrefs
}

// ── DOM tree deep-copy helpers ────────────────────────────────────────────────

fn cloneNode(alloc: std.mem.Allocator, src: protocol.WireNode) !protocol.WireNode {
    var n = src;
    if (src.tag)  |t| n.tag  = try alloc.dupe(u8, t);
    if (src.text) |t| n.text = try alloc.dupe(u8, t);
    if (src.href) |h| n.href = try alloc.dupe(u8, h);
    n.style = try cloneStyle(alloc, src.style);
    if (src.children) |children| {
        const cs = try alloc.alloc(protocol.WireNode, children.len);
        for (children, 0..) |child, i| cs[i] = try cloneNode(alloc, child);
        n.children = cs;
    }
    return n;
}

fn cloneStyle(alloc: std.mem.Allocator, s: protocol.WireStyle) !protocol.WireStyle {
    var ns = s;
    ns.display         = try alloc.dupe(u8, s.display);
    ns.position        = try alloc.dupe(u8, s.position);
    ns.border_style    = try alloc.dupe(u8, s.border_style);
    ns.font_weight     = try alloc.dupe(u8, s.font_weight);
    ns.font_style      = try alloc.dupe(u8, s.font_style);
    ns.text_decoration = try alloc.dupe(u8, s.text_decoration);
    ns.text_align      = try alloc.dupe(u8, s.text_align);
    ns.white_space     = try alloc.dupe(u8, s.white_space);
    ns.overflow_x      = try alloc.dupe(u8, s.overflow_x);
    ns.overflow_y      = try alloc.dupe(u8, s.overflow_y);
    ns.visibility      = try alloc.dupe(u8, s.visibility);
    return ns;
}
