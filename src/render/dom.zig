// DOM layout engine: walk WireNode tree, render to terminal cell buffer.
// Handles block/inline/flex layout, margin/padding, text wrapping, styles,
// background color fill, and width constraints.

const std     = @import("std");
const Buffer  = @import("buffer.zig").Buffer;
const Cell    = @import("cell.zig").Cell;
const Color   = @import("cell.zig").Color;
const Attrs   = @import("cell.zig").Attrs;
const protocol = @import("../ipc/protocol.zig");

const WireNode  = protocol.WireNode;
const WireStyle = protocol.WireStyle;
const NodeType  = protocol.NodeType;

const CHROME_TOP_ROWS    : u16 = 2;
const CHROME_BOTTOM_ROWS : u16 = 1;

// ── Layout context ────────────────────────────────────────────────────────────

const TextAlign = enum(u2) { left = 0, center = 1, right = 2 };

const LayoutCtx = struct {
    buf:            *Buffer,
    doc_row:        u32,
    col:            u16,
    indent:         u16,
    pending_margin: u32,
    scroll_row:     u32,
    content_rows:   u16,
    max_col:        u16,
    default_fg:     Color,
    default_bg:     Color,
    cur_fg:         Color,
    cur_bg:         Color,
    cur_attrs:      Attrs,
    text_align:     TextAlign,
    focused_link_id:  ?u32,
    focused_row_out:  *?u32,
    // Background fill region — filled on every emitNewline when cur_bg.set
    bg_fill_left:   u16,
    bg_fill_right:  u16,
};

// ── Public entry point ────────────────────────────────────────────────────────

pub fn paintDom(
    buf:             *Buffer,
    root:            *const WireNode,
    scroll_row:      u32,
    fg:              Color,
    bg:              Color,
    focused_link_id: ?u32,
    focused_row_out: *?u32,
) u32 {
    const content_rows: u16 = buf.rows -| (CHROME_TOP_ROWS + CHROME_BOTTOM_ROWS);
    if (content_rows == 0 or buf.cols == 0) return 1;

    for (CHROME_TOP_ROWS..buf.rows - CHROME_BOTTOM_ROWS) |row| {
        for (0..buf.cols) |c| {
            buf.setBack(@intCast(c), @intCast(row), .{ .codepoint = ' ', .fg = fg, .bg = bg });
        }
    }

    focused_row_out.* = null;
    var ctx = LayoutCtx{
        .buf             = buf,
        .doc_row         = 0,
        .col             = 0,
        .indent          = 0,
        .pending_margin  = 0,
        .scroll_row      = scroll_row,
        .content_rows    = content_rows,
        .max_col         = buf.cols,
        .default_fg      = fg,
        .default_bg      = bg,
        .cur_fg          = fg,
        .cur_bg          = .{},
        .cur_attrs       = .{},
        .text_align      = .left,
        .focused_link_id = focused_link_id,
        .focused_row_out = focused_row_out,
        .bg_fill_left    = 0,
        .bg_fill_right   = buf.cols,
    };

    renderNode(&ctx, root);
    return ctx.doc_row + 1;
}

// ── Node dispatch ─────────────────────────────────────────────────────────────

fn renderNode(ctx: *LayoutCtx, node: *const WireNode) void {
    if (std.mem.eql(u8, node.style.visibility, "hidden")) return;
    if (std.mem.eql(u8, node.style.display,    "none"))   return;
    switch (node.type) {
        .text    => renderText(ctx, node),
        .element => renderElement(ctx, node),
        else     => {},
    }
}

// ── Element rendering ─────────────────────────────────────────────────────────

fn renderElement(ctx: *LayoutCtx, node: *const WireNode) void {
    const tag = node.tag orelse "";

    if (std.mem.eql(u8, tag, "hr")) {
        renderHr(ctx, &node.style);
        return;
    }

    // Special inline-only elements
    if (std.mem.eql(u8, tag, "img")) {
        renderImgPlaceholder(ctx, node);
        return;
    }
    if (std.mem.eql(u8, tag, "input") or std.mem.eql(u8, tag, "textarea") or
        std.mem.eql(u8, tag, "select") or std.mem.eql(u8, tag, "button"))
    {
        renderFormElement(ctx, node);
        return;
    }

    const saved_fg       = ctx.cur_fg;
    const saved_bg       = ctx.cur_bg;
    const saved_attrs    = ctx.cur_attrs;
    const saved_indent   = ctx.indent;
    const saved_max_col  = ctx.max_col;
    const saved_bg_left  = ctx.bg_fill_left;
    const saved_bg_right = ctx.bg_fill_right;
    const saved_align    = ctx.text_align;

    const is_focused = if (ctx.focused_link_id) |fid| node.id == fid else false;
    if (is_focused) ctx.focused_row_out.* = ctx.doc_row;

    const elem_fg = wireColor(node.style.color);
    if (elem_fg.set) ctx.cur_fg = elem_fg;
    const elem_bg = wireColor(node.style.background_color);
    if (elem_bg.set) ctx.cur_bg = elem_bg;
    ctx.cur_attrs = .{
        .bold          = std.mem.eql(u8, node.style.font_weight, "bold"),
        .italic        = std.mem.eql(u8, node.style.font_style, "italic"),
        .underline     = std.mem.indexOf(u8, node.style.text_decoration, "underline") != null,
        .reverse       = is_focused,
        .strikethrough = std.mem.indexOf(u8, node.style.text_decoration, "line-through") != null,
    };

    const is_inline = std.mem.eql(u8, node.style.display, "inline") or
                      std.mem.eql(u8, node.style.display, "inline-block");
    const is_flex   = std.mem.eql(u8, node.style.display, "flex") or
                      std.mem.eql(u8, node.style.display, "inline-flex");

    if (is_inline) {
        if (node.children) |children| {
            for (children) |*child| renderNode(ctx, child);
        }
    } else if (is_flex) {
        renderFlex(ctx, node);
    } else {
        // Block layout
        if (ctx.col > ctx.indent) emitNewline(ctx);

        const mt = marginLines(node.style.margin[0]);
        requestMargin(ctx, mt);

        const extra_indent = marginCols(node.style.margin[3] + node.style.padding[3]);
        ctx.indent += extra_indent;
        if (ctx.col < ctx.indent) ctx.col = ctx.indent;

        // Apply text-align from computed style
        ctx.text_align = parseTextAlign(node.style.text_align);

        // Apply explicit absolute (px) width constraint.
        // Percentage widths are ignored here — they are consumed by flex layout
        // when the element is a flex item, and block-relative % isn't trackable.
        const avail = ctx.max_col -| ctx.indent;
        if (node.style.width) |sw| {
            if (sw >= 0) { // px only
                const cols = resolveWidth(sw, avail) orelse avail;
                ctx.max_col = ctx.indent + cols;
            }
        }

        // Apply padding_right
        const pr = marginCols(node.style.padding[1]);
        if (pr > 0) ctx.max_col -|= pr;

        // Setup background fill and paint initial row
        if (elem_bg.set) {
            ctx.bg_fill_left  = saved_indent;
            ctx.bg_fill_right = ctx.max_col + pr;
            fillRow(ctx, ctx.col, ctx.bg_fill_right, elem_bg);
            fillRow(ctx, saved_indent, ctx.indent, elem_bg);
        }

        // For blockquote: record start row for border painting
        const content_start_row = ctx.doc_row;
        const is_blockquote = std.mem.eql(u8, tag, "blockquote");
        const is_heading = isHeadingTag(tag);

        if (node.children) |children| {
            for (children) |*child| renderNode(ctx, child);
        }

        if (ctx.col > ctx.indent) emitNewline(ctx);

        // After children rendered: add heading decoration
        if (is_heading) {
            renderHeadingDecoration(ctx, tag, elem_fg);
        }

        // After children rendered: paint blockquote left border
        if (is_blockquote and extra_indent > 0) {
            paintBlockquoteBorder(ctx, content_start_row, ctx.indent -| 1);
        }

        ctx.indent        = saved_indent;
        ctx.col           = ctx.indent;
        ctx.max_col       = saved_max_col;
        ctx.bg_fill_left  = saved_bg_left;
        ctx.bg_fill_right = saved_bg_right;

        const mb = marginLines(node.style.margin[2]);
        requestMargin(ctx, mb);
    }

    ctx.cur_fg    = saved_fg;
    ctx.cur_bg    = saved_bg;
    ctx.cur_attrs = saved_attrs;
    ctx.text_align = saved_align;
    ctx.indent    = saved_indent;
}

// ── Flex layout ───────────────────────────────────────────────────────────────

fn renderFlex(ctx: *LayoutCtx, node: *const WireNode) void {
    const style = &node.style;

    if (ctx.col > ctx.indent) emitNewline(ctx);
    requestMargin(ctx, marginLines(style.margin[0]));
    flushPendingMargin(ctx);

    const is_col_dir = std.mem.eql(u8, style.flex_direction, "column") or
                       std.mem.eql(u8, style.flex_direction, "column-reverse");

    const saved_indent  = ctx.indent;
    const saved_max_col = ctx.max_col;
    const saved_fg      = ctx.cur_fg;
    const saved_bg      = ctx.cur_bg;
    const saved_bg_l    = ctx.bg_fill_left;
    const saved_bg_r    = ctx.bg_fill_right;

    const ml = marginCols(style.margin[3]);
    const mr = marginCols(style.margin[1]);
    const pl = marginCols(style.padding[3]);
    const pr = marginCols(style.padding[1]);
    const pt = marginLines(style.padding[0]);
    const pb = marginLines(style.padding[2]);

    const inner_left: u16  = ctx.indent + ml + pl;
    const inner_right: u16 = ctx.max_col -| (mr + pr);

    var eff_right: u16 = inner_right;
    if (resolveWidth(style.width, inner_right -| inner_left)) |w|
        eff_right = inner_left + w;

    const container_bg = wireColor(style.background_color);
    const container_fg = wireColor(style.color);
    if (container_bg.set) {
        ctx.cur_bg        = container_bg;
        ctx.bg_fill_left  = inner_left -| pl;
        ctx.bg_fill_right = eff_right + pr;
    }
    if (container_fg.set) ctx.cur_fg = container_fg;

    ctx.indent  = inner_left;
    ctx.col     = inner_left;
    ctx.max_col = eff_right;

    for (0..pt) |_| {
        if (container_bg.set) fillRow(ctx, inner_left -| pl, eff_right + pr, container_bg);
        emitNewline(ctx);
    }

    if (node.children) |children| {
        if (is_col_dir) {
            for (children) |*child| renderNode(ctx, child);
            if (ctx.col > ctx.indent) emitNewline(ctx);
        } else {
            renderFlexRow(ctx, children, inner_left, eff_right, container_bg);
        }
    }

    for (0..pb) |_| {
        if (container_bg.set) fillRow(ctx, inner_left -| pl, eff_right + pr, container_bg);
        emitNewline(ctx);
    }

    ctx.cur_fg        = saved_fg;
    ctx.cur_bg        = saved_bg;
    ctx.bg_fill_left  = saved_bg_l;
    ctx.bg_fill_right = saved_bg_r;
    ctx.indent        = saved_indent;
    ctx.max_col       = saved_max_col;
    ctx.col           = saved_indent;

    requestMargin(ctx, marginLines(style.margin[2]));
}

fn renderFlexRow(
    ctx:          *LayoutCtx,
    children:     []const WireNode,
    inner_left:   u16,
    inner_right:  u16,
    container_bg: Color,
) void {
    const avail_cols = inner_right -| inner_left;
    const MAX_ITEMS = 64;
    var widths:      [MAX_ITEMS]u16 = @splat(0);
    var grows:       [MAX_ITEMS]f64 = @splat(0.0);
    var n: usize    = 0;
    var fixed_total: u16 = 0;
    var total_grow:  f64 = 0;

    // Pass 1: compute base widths
    for (children) |*child| {
        if (child.type == .text) continue;
        if (std.mem.eql(u8, child.style.display, "none")) continue;
        if (n >= MAX_ITEMS) break;

        const basis = child.style.flex_basis;
        const base: u16 = if (basis != -1)
            resolveWidth(basis, avail_cols) orelse 0
        else
            resolveWidth(child.style.width, avail_cols) orelse 0;

        widths[n]     = base;
        grows[n]      = child.style.flex_grow;
        fixed_total  +|= base;
        total_grow   += child.style.flex_grow;
        n += 1;
    }

    // Distribute free space to flex-grow items
    if (total_grow > 0 and avail_cols > fixed_total) {
        const free: f64 = @floatFromInt(avail_cols - fixed_total);
        var given: u16 = 0;
        var first_grow: usize = n;
        for (0..n) |i| {
            if (grows[i] > 0) {
                const share: u16 = @intFromFloat(@floor(free * grows[i] / total_grow));
                widths[i]   +|= share;
                given       +|= share;
                if (first_grow == n) first_grow = i;
            }
        }
        if (first_grow < n) widths[first_grow] +|= (avail_cols - fixed_total) -| given;
    } else if (total_grow == 0 and fixed_total == 0 and n > 0) {
        // No explicit sizes: distribute equally
        const each: u16 = avail_cols / @as(u16, @intCast(n));
        for (0..n) |i| widths[i] = each;
        widths[n - 1] +|= avail_cols -| (each * @as(u16, @intCast(n)));
    }

    const flex_start_row = ctx.doc_row;
    var max_end_row: u32 = flex_start_row;
    var item_x: u16      = inner_left;
    var item_idx: usize  = 0;

    for (children) |*child| {
        if (child.type == .text) continue;
        if (std.mem.eql(u8, child.style.display, "none")) continue;
        if (item_idx >= n) break;

        const w = widths[item_idx];
        item_idx += 1;
        if (w == 0) { item_x +|= w; continue; }

        const saved_indent  = ctx.indent;
        const saved_max_col = ctx.max_col;
        const saved_col     = ctx.col;
        const saved_fg      = ctx.cur_fg;
        const saved_bg      = ctx.cur_bg;
        const saved_bg_l    = ctx.bg_fill_left;
        const saved_bg_r    = ctx.bg_fill_right;

        ctx.doc_row = flex_start_row;
        ctx.indent  = item_x;
        ctx.col     = item_x;
        ctx.max_col = item_x +| w;

        const item_bg = wireColor(child.style.background_color);
        if (item_bg.set) {
            ctx.cur_bg        = item_bg;
            ctx.bg_fill_left  = item_x;
            ctx.bg_fill_right = item_x +| w;
            fillRow(ctx, item_x, item_x +| w, item_bg);
        } else if (container_bg.set) {
            ctx.bg_fill_left  = item_x;
            ctx.bg_fill_right = item_x +| w;
        }

        renderNode(ctx, child);

        if (ctx.col > ctx.indent) {
            if (ctx.cur_bg.set) fillRow(ctx, ctx.col, item_x +| w, ctx.cur_bg);
            ctx.doc_row += 1;
        }
        if (ctx.doc_row > max_end_row) max_end_row = ctx.doc_row;

        ctx.indent        = saved_indent;
        ctx.max_col       = saved_max_col;
        ctx.col           = saved_col;
        ctx.cur_fg        = saved_fg;
        ctx.cur_bg        = saved_bg;
        ctx.bg_fill_left  = saved_bg_l;
        ctx.bg_fill_right = saved_bg_r;

        item_x +|= w;
    }

    ctx.doc_row = max_end_row;
    ctx.col     = ctx.indent;
}

// ── Text rendering ────────────────────────────────────────────────────────────

fn renderText(ctx: *LayoutCtx, node: *const WireNode) void {
    const text = node.text orelse return;
    if (text.len == 0) return;
    flushPendingMargin(ctx);

    const is_pre = std.mem.eql(u8, node.style.white_space, "pre");

    const fg = blk: {
        const c = wireColor(node.style.color);
        break :blk if (c.set) c else ctx.cur_fg;
    };
    const bg = blk: {
        const c = wireColor(node.style.background_color);
        break :blk if (c.set) c else ctx.cur_bg;
    };
    const attrs = ctx.cur_attrs;

    if (is_pre) {
        renderPre(ctx, text, fg, bg, attrs);
    } else if (ctx.text_align != .left and ctx.col == ctx.indent) {
        renderWrappedAligned(ctx, text, fg, bg, attrs, ctx.text_align);
    } else {
        renderWrapped(ctx, text, fg, bg, attrs);
    }
}

fn renderPre(ctx: *LayoutCtx, text: []const u8, fg: Color, bg: Color, attrs: Attrs) void {
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        if (cp == '\n') {
            emitNewline(ctx);
        } else if (cp == '\r') {
            // skip
        } else if (cp == '\t') {
            const next_stop = (ctx.col / 8 + 1) * 8;
            while (ctx.col < next_stop and ctx.col < ctx.max_col) {
                emitChar(ctx, ' ', fg, bg, attrs);
            }
        } else {
            emitChar(ctx, cp, fg, bg, attrs);
        }
    }
}

/// Render word-wrapped text with center or right alignment.
/// Words are collected into lines, then each line is rendered with an x-offset.
fn renderWrappedAligned(ctx: *LayoutCtx, text: []const u8, fg: Color, bg: Color, attrs: Attrs, align_mode: TextAlign) void {
    const avail: u16 = ctx.max_col -| ctx.indent;
    if (avail == 0) return;

    // Collect words: up to 128 words, each up to 128 bytes
    const MAX_WORDS = 128;
    const MAX_WORD_BYTES = 128;
    var word_store: [MAX_WORDS][MAX_WORD_BYTES]u8 = undefined;
    var word_byte_lens: [MAX_WORDS]u8 = @splat(0);
    var word_col_widths: [MAX_WORDS]u16 = @splat(0);
    var word_count: usize = 0;

    var wbuf: [MAX_WORD_BYTES]u8 = undefined;
    var wlen: usize = 0;
    var wcols: u16 = 0;

    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const is_space = cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r';
        if (is_space) {
            if (wcols > 0 and word_count < MAX_WORDS) {
                const copy_len = @min(wlen, MAX_WORD_BYTES);
                @memcpy(word_store[word_count][0..copy_len], wbuf[0..copy_len]);
                word_byte_lens[word_count] = @intCast(copy_len);
                word_col_widths[word_count] = wcols;
                word_count += 1;
                wlen = 0;
                wcols = 0;
            }
        } else {
            const w = charWidth(cp);
            var seq: [4]u8 = undefined;
            const seq_len = std.unicode.utf8Encode(cp, &seq) catch continue;
            if (wlen + seq_len <= MAX_WORD_BYTES) {
                @memcpy(wbuf[wlen..][0..seq_len], seq[0..seq_len]);
                wlen += seq_len;
                wcols += w;
            }
        }
    }
    if (wcols > 0 and word_count < MAX_WORDS) {
        const copy_len = @min(wlen, MAX_WORD_BYTES);
        @memcpy(word_store[word_count][0..copy_len], wbuf[0..copy_len]);
        word_byte_lens[word_count] = @intCast(copy_len);
        word_col_widths[word_count] = wcols;
        word_count += 1;
    }

    // Layout words into lines and render each line with alignment offset
    var line_start: usize = 0;
    while (line_start < word_count) {
        // Find how many words fit on this line
        var line_end = line_start;
        var line_width: u16 = 0;
        while (line_end < word_count) {
            const space: u16 = if (line_end > line_start) 1 else 0;
            const w = word_col_widths[line_end];
            if (line_width + space + w > avail) break;
            line_width += space + w;
            line_end += 1;
        }
        // If no word fits (word wider than avail), force at least one
        if (line_end == line_start and line_start < word_count) {
            line_end = line_start + 1;
            line_width = @min(word_col_widths[line_start], avail);
        }

        // Calculate alignment offset
        const offset: u16 = switch (align_mode) {
            .center => (avail -| line_width) / 2,
            .right  => avail -| line_width,
            .left   => 0,
        };

        // Move to indented position + offset
        ctx.col = ctx.indent + offset;

        // Render words on this line
        var wi = line_start;
        while (wi < line_end) : (wi += 1) {
            if (wi > line_start) emitChar(ctx, ' ', fg, bg, attrs);
            const bytes = word_store[wi][0..word_byte_lens[wi]];
            emitWordBytes(ctx, bytes, fg, bg, attrs);
        }

        line_start = line_end;
        if (line_start < word_count) emitNewline(ctx);
    }
}

fn renderWrapped(ctx: *LayoutCtx, text: []const u8, fg: Color, bg: Color, attrs: Attrs) void {
    var word_bytes: [512]u8 = undefined;
    var word_end: usize = 0;
    var word_cols: u16 = 0;

    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const is_space = cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r';
        if (is_space) {
            if (word_cols > 0) {
                flushWord(ctx, word_bytes[0..word_end], word_cols, fg, bg, attrs);
                word_end = 0;
                word_cols = 0;
            }
        } else {
            const w = charWidth(cp);
            var seq: [4]u8 = undefined;
            const seq_len = std.unicode.utf8Encode(cp, &seq) catch continue;
            if (word_end + seq_len <= word_bytes.len) {
                @memcpy(word_bytes[word_end..][0..seq_len], seq[0..seq_len]);
                word_end  += seq_len;
                word_cols += w;
            }
        }
    }
    if (word_cols > 0) flushWord(ctx, word_bytes[0..word_end], word_cols, fg, bg, attrs);
}

fn flushWord(ctx: *LayoutCtx, word: []const u8, word_cols: u16, fg: Color, bg: Color, attrs: Attrs) void {
    if (word_cols == 0) return;
    const space: u16 = if (ctx.col > ctx.indent) 1 else 0;
    if (ctx.col + space + word_cols <= ctx.max_col) {
        if (space > 0) emitChar(ctx, ' ', fg, bg, attrs);
        emitWordBytes(ctx, word, fg, bg, attrs);
        return;
    }
    if (ctx.col > ctx.indent) emitNewline(ctx);
    emitWordBytes(ctx, word, fg, bg, attrs);
}

fn emitWordBytes(ctx: *LayoutCtx, bytes: []const u8, fg: Color, bg: Color, attrs: Attrs) void {
    var iter = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
    while (iter.nextCodepoint()) |cp| emitChar(ctx, cp, fg, bg, attrs);
}

// ── Special element renderers ─────────────────────────────────────────────────

fn isHeadingTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "h1") or std.mem.eql(u8, tag, "h2") or
           std.mem.eql(u8, tag, "h3") or std.mem.eql(u8, tag, "h4");
}

fn parseTextAlign(s: []const u8) TextAlign {
    if (std.mem.eql(u8, s, "center")) return .center;
    if (std.mem.eql(u8, s, "right"))  return .right;
    return .left;
}

/// Render a decoration underline after a heading element.
fn renderHeadingDecoration(ctx: *LayoutCtx, tag: []const u8, elem_fg: Color) void {
    const deco_char: u21 = if (std.mem.eql(u8, tag, "h1")) 0x2550   // ═ double horizontal
                           else if (std.mem.eql(u8, tag, "h2")) 0x2500  // ─ single horizontal
                           else 0; // h3, h4 get no underline (they already have bold)
    if (deco_char == 0) return;

    const deco_fg = if (elem_fg.set) blk: {
        // Dim the heading color slightly for the underline
        break :blk Color{
            .r = @intFromFloat(@as(f32, @floatFromInt(elem_fg.r)) * 0.6),
            .g = @intFromFloat(@as(f32, @floatFromInt(elem_fg.g)) * 0.6),
            .b = @intFromFloat(@as(f32, @floatFromInt(elem_fg.b)) * 0.6),
            .set = true,
        };
    } else Color{ .r = 80, .g = 80, .b = 100, .set = true };

    var c: u16 = ctx.indent;
    while (c < ctx.max_col) : (c += 1) {
        emitChar(ctx, deco_char, deco_fg, ctx.default_bg, .{});
    }
    if (ctx.col > ctx.indent) emitNewline(ctx);
}

/// Paint a vertical bar (│) at `border_col` for every document row in [start_row, end_row).
fn paintBlockquoteBorder(ctx: *LayoutCtx, start_row: u32, border_col: u16) void {
    const border_fg = Color{ .r = 90, .g = 130, .b = 210, .set = true };
    var r: u32 = start_row;
    while (r < ctx.doc_row) : (r += 1) {
        if (r < ctx.scroll_row) continue;
        const vrow = r - ctx.scroll_row;
        if (vrow >= ctx.content_rows) break;
        const brow: u16 = @intCast(vrow + CHROME_TOP_ROWS);
        ctx.buf.setBack(border_col, brow, .{
            .codepoint = 0x2502, // │
            .fg        = border_fg,
            .bg        = ctx.default_bg,
        });
    }
}

/// Render an <img> element as a text placeholder.
fn renderImgPlaceholder(ctx: *LayoutCtx, node: *const WireNode) void {
    flushPendingMargin(ctx);
    const placeholder_fg = Color{ .r = 100, .g = 180, .b = 100, .set = true };
    const placeholder_bg = Color{ .r = 20,  .g = 30,  .b = 20,  .set = true };
    const attrs = Attrs{};

    emitChar(ctx, '[', placeholder_fg, placeholder_bg, attrs);
    emitChar(ctx, 0x1F5BC, placeholder_fg, placeholder_bg, attrs); // 🖼
    const alt = getImgAlt(node);
    if (alt.len > 0) {
        emitChar(ctx, ' ', placeholder_fg, placeholder_bg, attrs);
        var iter = std.unicode.Utf8Iterator{ .bytes = alt, .i = 0 };
        var n: u16 = 0;
        while (iter.nextCodepoint()) |cp| {
            if (n >= 30) {
                emitChar(ctx, 0x2026, placeholder_fg, placeholder_bg, attrs); // …
                break;
            }
            emitChar(ctx, cp, placeholder_fg, placeholder_bg, attrs);
            n += 1;
        }
    }
    emitChar(ctx, ']', placeholder_fg, placeholder_bg, attrs);
}

fn getImgAlt(node: *const WireNode) []const u8 {
    // Pipeline encodes alt as first text child
    if (node.children) |children| {
        for (children) |*child| {
            if (child.type == .text) {
                return child.text orelse "";
            }
        }
    }
    return "";
}

/// Render an interactive form element with a visual placeholder.
fn renderFormElement(ctx: *LayoutCtx, node: *const WireNode) void {
    flushPendingMargin(ctx);
    const tag = node.tag orelse "";
    const elem_bg = Color{ .r = 40, .g = 40, .b = 60, .set = true };
    const elem_fg = Color{ .r = 200, .g = 200, .b = 220, .set = true };
    const bracket_fg = Color{ .r = 120, .g = 120, .b = 160, .set = true };
    const attrs = Attrs{};

    if (std.mem.eql(u8, tag, "button")) {
        emitChar(ctx, '[', bracket_fg, elem_bg, attrs);
        emitChar(ctx, ' ', elem_fg, elem_bg, attrs);
        // Render button children (label text)
        const saved_fg  = ctx.cur_fg;
        const saved_bg  = ctx.cur_bg;
        const saved_att = ctx.cur_attrs;
        ctx.cur_fg  = elem_fg;
        ctx.cur_bg  = elem_bg;
        ctx.cur_attrs = .{ .bold = true };
        if (node.children) |children| {
            for (children) |*child| renderNode(ctx, child);
        }
        ctx.cur_fg  = saved_fg;
        ctx.cur_bg  = saved_bg;
        ctx.cur_attrs = saved_att;
        emitChar(ctx, ' ', elem_fg, elem_bg, attrs);
        emitChar(ctx, ']', bracket_fg, elem_bg, attrs);
    } else if (std.mem.eql(u8, tag, "select")) {
        // [▾ Option ]
        const avail: u16 = @min(20, ctx.max_col -| ctx.col);
        emitChar(ctx, '[', bracket_fg, elem_bg, attrs);
        emitChar(ctx, 0x25BE, elem_fg, elem_bg, attrs); // ▾
        emitChar(ctx, ' ', elem_fg, elem_bg, attrs);
        var i: u16 = 3;
        while (i < avail -| 1) : (i += 1) {
            emitChar(ctx, '_', elem_fg, elem_bg, attrs);
        }
        emitChar(ctx, ']', bracket_fg, elem_bg, attrs);
    } else {
        // input / textarea: render as [__________]
        const is_text = isInputText(node);
        const avail: u16 = @min(24, ctx.max_col -| ctx.col);
        emitChar(ctx, '[', bracket_fg, elem_bg, attrs);
        if (!is_text) {
            emitChar(ctx, 0x25A0, elem_fg, elem_bg, attrs); // ■ checkbox/radio placeholder
        } else {
            var i: u16 = 1;
            while (i < avail -| 1) : (i += 1) {
                emitChar(ctx, '_', elem_fg, elem_bg, attrs);
            }
        }
        emitChar(ctx, ']', bracket_fg, elem_bg, attrs);
    }
}

fn isInputText(node: *const WireNode) bool {
    // Check for non-text input types (checkbox, radio, submit, etc.)
    _ = node;
    return true; // default: text input
}

// ── Horizontal rule ───────────────────────────────────────────────────────────

fn renderHr(ctx: *LayoutCtx, style: *const WireStyle) void {
    flushPendingMargin(ctx);
    if (ctx.col > ctx.indent) emitNewline(ctx);
    const mt = marginLines(style.margin[0]);
    for (0..mt) |_| emitNewline(ctx);
    const line_fg = Color{ .r = 80, .g = 80, .b = 80, .set = true };
    var c: u16 = ctx.indent;
    while (c < ctx.max_col) : (c += 1) {
        emitChar(ctx, 0x2500, line_fg, ctx.default_bg, .{});
    }
    if (ctx.col > ctx.indent) emitNewline(ctx);
    const mb = marginLines(style.margin[2]);
    for (0..mb) |_| emitNewline(ctx);
}

// ── Emit primitives ───────────────────────────────────────────────────────────

fn fillRow(ctx: *const LayoutCtx, from_col: u16, to_col: u16, bg: Color) void {
    if (!bg.set or from_col >= to_col) return;
    if (ctx.doc_row < ctx.scroll_row) return;
    const vrow = ctx.doc_row - ctx.scroll_row;
    if (vrow >= ctx.content_rows) return;
    const brow: u16 = @intCast(vrow + CHROME_TOP_ROWS);
    var c = from_col;
    while (c < to_col) : (c += 1) {
        ctx.buf.setBack(c, brow, .{ .codepoint = ' ', .fg = ctx.default_fg, .bg = bg });
    }
}

fn emitChar(ctx: *LayoutCtx, cp: u21, fg: Color, bg: Color, attrs: Attrs) void {
    const w = charWidth(cp);
    if (ctx.doc_row >= ctx.scroll_row) {
        const vrow = ctx.doc_row - ctx.scroll_row;
        if (vrow < ctx.content_rows) {
            const brow: u16 = @intCast(vrow + CHROME_TOP_ROWS);
            ctx.buf.setBack(ctx.col, brow, .{
                .codepoint = cp,
                .fg        = fg,
                .bg        = bg,
                .attrs     = attrs,
                .width     = @intCast(w),
            });
        }
    }
    ctx.col += w;
    if (ctx.col >= ctx.max_col) emitNewline(ctx);
}

fn emitNewline(ctx: *LayoutCtx) void {
    if (ctx.cur_bg.set) {
        fillRow(ctx, ctx.col,          ctx.bg_fill_right, ctx.cur_bg);
        fillRow(ctx, ctx.bg_fill_left, ctx.indent,        ctx.cur_bg);
    }
    ctx.doc_row += 1;
    ctx.col = ctx.indent;
}

// ── Margin collapsing ─────────────────────────────────────────────────────────

fn requestMargin(ctx: *LayoutCtx, lines: usize) void {
    const n: u32 = @intCast(lines);
    if (n > ctx.pending_margin) ctx.pending_margin = n;
}

fn flushPendingMargin(ctx: *LayoutCtx) void {
    for (0..ctx.pending_margin) |_| emitNewline(ctx);
    ctx.pending_margin = 0;
}

// ── Style helpers ─────────────────────────────────────────────────────────────

fn wireColor(rgba: [4]f64) Color {
    return .{
        .r   = @intFromFloat(@max(0, @min(255, rgba[0]))),
        .g   = @intFromFloat(@max(0, @min(255, rgba[1]))),
        .b   = @intFromFloat(@max(0, @min(255, rgba[2]))),
        .set = rgba[3] > 0.5,
    };
}

fn marginLines(px: f64) usize {
    if (px <= 0) return 0;
    return @intFromFloat(@floor(px / 16.0));
}

fn marginCols(px: f64) u16 {
    if (px <= 0) return 0;
    return @intFromFloat(@floor(px / 8.0));
}

/// Resolve a WireStyle width value to terminal columns.
/// null=auto, >=0=px (÷8), <0=percent (e.g. -50.0 = 50%).
fn resolveWidth(w: ?f64, avail_cols: u16) ?u16 {
    const v = w orelse return null;
    if (v >= 0) {
        const cols: f64 = @max(1, @floor(v / 8.0));
        return @min(avail_cols, @as(u16, @intFromFloat(cols)));
    } else {
        const pct = (-v) / 100.0;
        const cols: f64 = @floor(@as(f64, @floatFromInt(avail_cols)) * pct);
        return @max(1, @min(avail_cols, @as(u16, @intFromFloat(cols))));
    }
}

// ── Character width ───────────────────────────────────────────────────────────

fn charWidth(cp: u21) u16 {
    if (cp < 0x20) return 0;
    if (cp >= 0x1100 and cp <= 0x115F) return 2;
    if (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) return 2;
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    if (cp >= 0xFE10 and cp <= 0xFE1F) return 2;
    if (cp >= 0xFE30 and cp <= 0xFE6F) return 2;
    if (cp >= 0xFF01 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
    if (cp >= 0x1F300 and cp <= 0x1FBFF) return 2;
    return 1;
}
