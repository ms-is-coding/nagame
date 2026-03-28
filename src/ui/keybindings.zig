// Key → AppAction dispatch table.

const input = @import("../terminal/input.zig");

pub const AppAction = union(enum) {
    none,
    quit,
    scroll_up,
    scroll_down,
    scroll_half_up,
    scroll_half_down,
    scroll_top,
    scroll_bottom,
    open_address_bar,
    navigate_back,
    navigate_forward,
    next_link,
    prev_link,
    activate_link,
    new_tab,
    close_tab,
    find_in_page,
    type_char: u21,
    backspace,
    enter,
    escape,
};

pub fn keyToAction(key: input.Key) AppAction {
    return switch (key) {
        .ctrl_c, .ctrl_d => .quit,
        .char => |cp| switch (cp) {
            'q'  => .quit,
            'j'  => .scroll_down,
            'k'  => .scroll_up,
            'd'  => .scroll_half_down,
            'u'  => .scroll_half_up,
            'g'  => .scroll_top,
            'G'  => .scroll_bottom,
            'o'  => .open_address_bar,
            't'  => .new_tab,
            'x'  => .close_tab,
            '/'  => .find_in_page,
            else => .{ .type_char = cp },
        },
        .up       => .scroll_up,
        .down     => .scroll_down,
        .page_up  => .scroll_half_up,
        .page_down=> .scroll_half_down,
        .home     => .scroll_top,
        .end      => .scroll_bottom,
        .tab      => .next_link,
        .shift_tab=> .prev_link,
        .enter    => .activate_link,
        .backspace=> .backspace,
        .escape   => .escape,
        .alt_left => .navigate_back,
        .alt_right=> .navigate_forward,
        else => .none,
    };
}
