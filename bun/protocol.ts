// IPC message types — canonical TypeScript spec for both sides

// ── Wire DOM types ──────────────────────────────────────────────────────────

export type WireStyle = {
  display: string;
  position: string;
  width?: number;
  height?: number;
  margin: [number, number, number, number];
  padding: [number, number, number, number];
  border_width: [number, number, number, number];
  border_style: string;
  border_color: [number, number, number, number];
  color: [number, number, number, number];
  background_color: [number, number, number, number];
  font_size: number;
  font_weight: string;
  font_style: string;
  text_decoration: string;
  text_align: string;
  white_space: string;
  line_height: number;
  flex_direction?: string;
  flex_wrap?: string;
  justify_content?: string;
  align_items?: string;
  flex_grow?: number;
  flex_shrink?: number;
  flex_basis?: number;
  overflow_x: string;
  overflow_y: string;
  visibility: string;
  opacity: number;
};

export type WireNode = {
  id: number;
  type: "element" | "text" | "comment" | "doctype";
  tag?: string;
  attrs?: Record<string, string>;
  text?: string;
  href?: string;
  style: WireStyle;
  children?: WireNode[];
};

export type DomPatch =
  | { op: "insert"; parent_id: number; before_id: number | null; node: WireNode }
  | { op: "remove"; node_id: number }
  | { op: "set_attr"; node_id: number; name: string; value: string }
  | { op: "remove_attr"; node_id: number; name: string }
  | { op: "set_text"; node_id: number; text: string }
  | { op: "set_style"; node_id: number; style: Partial<WireStyle> };

// ── Zig → Bun messages ──────────────────────────────────────────────────────

export type NavigateMsg   = { type: "navigate"; id: number; url: string; method?: string; body?: string };
export type ClickMsg      = { type: "click";    id: number; node_id: number };
export type SubmitMsg     = { type: "submit";   id: number; form_node_id: number; fields: Record<string, string> };
export type ScrollMsg     = { type: "scroll";   id: number; x: number; y: number };
export type EvalMsg       = { type: "eval";     id: number; code: string };
export type ResizeMsg     = { type: "resize";   cols: number; rows: number; px_width: number; px_height: number };
export type HistoryMsg    = { type: "history";  direction: "back" | "forward" };

export type ZigToBun =
  | NavigateMsg | ClickMsg | SubmitMsg | ScrollMsg | EvalMsg | ResizeMsg | HistoryMsg;

// ── Bun → Zig messages ──────────────────────────────────────────────────────

export type DomReadyMsg       = { type: "dom_ready";       id: number; url: string; title: string; root: WireNode };
export type DomPatchMsg       = { type: "dom_patch";       patches: DomPatch[] };
export type ImageReadyMsg     = { type: "image_ready";     image_id: number; node_id: number; width_px: number; height_px: number; format: string; data_b64: string };
export type ErrorMsg          = { type: "error";           id: number; code: number; message: string };
export type NavigateRequestMsg= { type: "navigate_request";url: string; push_history: boolean };
export type TitleChangedMsg   = { type: "title_changed";   title: string };
export type ConsoleMsg        = { type: "console";         level: "log" | "warn" | "error"; args: string[] };
export type ReadyMsg          = { type: "ready" };

export type BunToZig =
  | DomReadyMsg | DomPatchMsg | ImageReadyMsg | ErrorMsg
  | NavigateRequestMsg | TitleChangedMsg | ConsoleMsg | ReadyMsg;
