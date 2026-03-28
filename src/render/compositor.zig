// Layer compositor: merge chrome and page content into the back buffer.

const std      = @import("std");
const Buffer   = @import("buffer.zig").Buffer;
const chrome   = @import("../ui/chrome.zig");
const painter  = @import("painter.zig");
const dom      = @import("dom.zig");
const Cell     = @import("cell.zig").Cell;
const Color    = @import("cell.zig").Color;
const protocol = @import("../ipc/protocol.zig");

pub const CompositorState = struct {
    title:        []const u8 = "",
    url:          []const u8 = "",
    status:       []const u8 = "",
    text_content: []const u8 = "",   // fallback for painter (loading / error)
    root:         ?*const protocol.WireNode = null, // DOM tree (set after dom_ready)
    scroll_row:   u32 = 0,
    total_lines:  u32 = 0,
    loading:      bool = false,
    spinner_frame: u8 = 0,
    focused_link_id:  ?u32 = null,
    focused_link_row: ?u32 = null,
};

/// compose takes a mutable state so it can update total_lines after painting.
pub fn compose(buf: *Buffer, state: *CompositorState) void {
    buf.clearBack();

    const fg = Color{ .r = 204, .g = 204, .b = 204, .set = true };
    const bg = Color{ .r = 13,  .g = 13,  .b = 26,  .set = true };

    if (state.root) |root| {
        var focused_row: ?u32 = null;
        state.total_lines = dom.paintDom(buf, root, state.scroll_row, fg, bg,
                                         state.focused_link_id, &focused_row);
        state.focused_link_row = focused_row;
        // Auto-scroll to keep focused link in view
        if (focused_row) |fr| {
            const content_rows = buf.rows -| (2 + 1);
            if (fr < state.scroll_row) {
                state.scroll_row = fr;
            } else if (fr >= state.scroll_row + content_rows) {
                state.scroll_row = fr -| (content_rows -| 1);
            }
        }
    } else {
        painter.paintText(buf, state.text_content, state.scroll_row, fg, bg);
    }

    chrome.renderChrome(
        buf,
        state.title,
        state.url,
        state.status,
        state.loading,
        state.spinner_frame,
        state.scroll_row,
        state.total_lines,
    );
}
