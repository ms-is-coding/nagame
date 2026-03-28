// HTML processing pipeline: parse5 DOM parsing + css-tree cascade → WireNode tree.
// Phase 2: real HTML parser, CSS cascade, structured DOM output.

import { parse, defaultTreeAdapter as adapter } from "parse5";
import type { DefaultTreeAdapterMap } from "parse5";
import * as csstree from "css-tree";

type Document  = DefaultTreeAdapterMap["document"];
type Element   = DefaultTreeAdapterMap["element"];
type TextNode  = DefaultTreeAdapterMap["textNode"];
type ChildNode = DefaultTreeAdapterMap["childNode"];
import type { DomReadyMsg, WireNode, WireStyle } from "../protocol.ts";

// ── Default styles ────────────────────────────────────────────────────────────

const DEFAULT_STYLE: WireStyle = {
  display: "block",
  position: "static",
  margin: [0, 0, 0, 0],
  padding: [0, 0, 0, 0],
  border_width: [0, 0, 0, 0],
  border_style: "none",
  border_color: [0, 0, 0, 0],
  color: [204, 204, 204, 255],
  background_color: [0, 0, 0, 0],
  font_size: 16,
  font_weight: "normal",
  font_style: "normal",
  text_decoration: "none",
  text_align: "left",
  white_space: "normal",
  line_height: 1.4,
  overflow_x: "visible",
  overflow_y: "visible",
  visibility: "visible",
  opacity: 1,
  flex_direction: "row",
  flex_wrap: "nowrap",
  justify_content: "flex-start",
  align_items: "stretch",
  flex_grow: 0,
  flex_shrink: 1,
  flex_basis: -1,
};

const BROWSER_DEFAULTS: Record<string, Partial<WireStyle>> = {
  body:       { margin: [8, 8, 8, 8] },
  h1:         { font_weight: "bold", font_size: 32, margin: [16, 0, 8, 0], color: [230, 230, 255, 255] },
  h2:         { font_weight: "bold", font_size: 24, margin: [14, 0, 6, 0], color: [210, 210, 245, 255] },
  h3:         { font_weight: "bold", font_size: 20, margin: [12, 0, 4, 0], color: [195, 195, 230, 255] },
  h4:         { font_weight: "bold", font_size: 16, margin: [10, 0, 4, 0], color: [180, 180, 215, 255] },
  h5:         { font_weight: "bold", font_size: 13, margin: [8,  0,  2, 0] },
  h6:         { font_weight: "bold", font_size: 11, margin: [8,  0,  2, 0] },
  p:          { margin: [16, 0, 16, 0] },
  a:          { display: "inline", color: [100, 149, 237, 255], text_decoration: "underline" },
  strong:     { display: "inline", font_weight: "bold" },
  b:          { display: "inline", font_weight: "bold" },
  em:         { display: "inline", font_style: "italic" },
  i:          { display: "inline", font_style: "italic" },
  cite:       { display: "inline", font_style: "italic" },
  dfn:        { display: "inline", font_style: "italic" },
  code:       { display: "inline", color: [255, 185, 80, 255], background_color: [28, 28, 38, 255], font_size: 14 },
  kbd:        { display: "inline", color: [200, 240, 200, 255], background_color: [35, 50, 35, 255] },
  samp:       { display: "inline", color: [255, 165, 0, 255], background_color: [30, 30, 30, 255] },
  tt:         { display: "inline", color: [255, 165, 0, 255] },
  pre:        { white_space: "pre", background_color: [16, 16, 28, 255], margin: [12, 0, 12, 0], padding: [12, 16, 12, 16] },
  blockquote: { margin: [8, 0, 8, 32], padding: [4, 0, 4, 8], color: [180, 180, 200, 255] },
  ul:         { margin: [8, 0, 8, 0], padding: [0, 0, 0, 24] },
  ol:         { margin: [8, 0, 8, 0], padding: [0, 0, 0, 24] },
  li:         { margin: [2, 0, 2, 0] },
  dt:         { display: "inline", font_weight: "bold" },
  dd:         { margin: [0, 0, 4, 32] },
  table:      { margin: [8, 0, 8, 0] },
  th:         { font_weight: "bold", background_color: [30, 30, 50, 255] },
  td:         { padding: [4, 8, 4, 8] },
  caption:    { font_weight: "bold", text_align: "center" },
  hr:         { margin: [8, 0, 8, 0] },
  figure:     { margin: [16, 0, 16, 0] },
  figcaption: { font_style: "italic", color: [160, 160, 180, 255], text_align: "center" },
  small:      { display: "inline", font_size: 13, color: [150, 150, 170, 255] },
  mark:       { display: "inline", background_color: [255, 220, 0, 255], color: [0, 0, 0, 255] },
  del:        { display: "inline", text_decoration: "line-through", color: [140, 140, 160, 255] },
  ins:        { display: "inline", text_decoration: "underline", color: [100, 220, 100, 255] },
  s:          { display: "inline", text_decoration: "line-through", color: [140, 140, 160, 255] },
  // Form elements
  button:     { display: "inline", padding: [4, 8, 4, 8], background_color: [50, 80, 130, 255], color: [220, 230, 255, 255] },
  input:      { display: "inline" },
  select:     { display: "inline" },
  textarea:   { display: "block", white_space: "pre", padding: [8, 8, 8, 8], background_color: [20, 20, 30, 255] },
  // Semantic layout elements
  nav:        { display: "flex", flex_wrap: "wrap", padding: [8, 16, 8, 16] },
  header:     { display: "flex", align_items: "center", padding: [8, 16, 8, 16] },
  footer:     { display: "flex", flex_wrap: "wrap", padding: [8, 16, 8, 16] },
  main:       { display: "block" },
  section:    { display: "block" },
  article:    { display: "block" },
  aside:      { display: "block" },
  details:    { display: "block", margin: [8, 0, 8, 0] },
  summary:    { display: "block", font_weight: "bold", color: [180, 210, 255, 255] },
  // Hidden elements
  head:       { display: "none" },
  script:     { display: "none" },
  style:      { display: "none" },
  meta:       { display: "none" },
  link:       { display: "none" },
  noscript:   { display: "none" },
  template:   { display: "none" },
  iframe:     { display: "none" },
  svg:        { display: "none" },
  // Inline elements (override display default)
  span:       { display: "inline" },
  abbr:       { display: "inline" },
  acronym:    { display: "inline" },
  sub:        { display: "inline" },
  sup:        { display: "inline" },
  q:          { display: "inline" },
  br:         { display: "inline" },
  img:        { display: "inline" },
};

const INHERITED_PROPS: (keyof WireStyle)[] = [
  "color", "font_size", "font_weight", "font_style",
  "text_align", "white_space", "line_height", "visibility",
];

// ── CSS cascade ───────────────────────────────────────────────────────────────

interface StyleSheet {
  byTag:   Map<string, Map<string, string>>;
  byClass: Map<string, Map<string, string>>;
}

function parseStylesheet(css: string): StyleSheet {
  const result: StyleSheet = { byTag: new Map(), byClass: new Map() };
  try {
    const ast = csstree.parse(css);
    csstree.walk(ast, {
      visit: "Rule",
      enter(rule: any) {
        if (rule.type !== "Rule") return;
        const decls = new Map<string, string>();
        csstree.walk(rule.block, {
          visit: "Declaration",
          enter(d: any) {
            if (d.type !== "Declaration") return;
            decls.set(d.property, csstree.generate(d.value));
          },
        });
        if (decls.size === 0) return;
        csstree.walk(rule.prelude, {
          visit: "Selector",
          enter(sel: any) {
            if (sel.type !== "Selector") return;
            const s = csstree.generate(sel).trim();
            if (/^[a-z][a-z0-9]*$/i.test(s)) {
              const tag = s.toLowerCase();
              const existing = result.byTag.get(tag) ?? new Map();
              decls.forEach((v, k) => existing.set(k, v));
              result.byTag.set(tag, existing);
            } else if (/^\.[a-z_-][a-z0-9_-]*$/i.test(s)) {
              const cls = s.slice(1);
              const existing = result.byClass.get(cls) ?? new Map();
              decls.forEach((v, k) => existing.set(k, v));
              result.byClass.set(cls, existing);
            }
          },
        });
      },
    });
  } catch { /* silently ignore parse errors */ }
  return result;
}

function parseDeclarationList(css: string): Map<string, string> {
  const result = new Map<string, string>();
  try {
    const ast = csstree.parse(css, { context: "declarationList" });
    csstree.walk(ast, {
      visit: "Declaration",
      enter(d: any) {
        if (d.type !== "Declaration") return;
        result.set(d.property, csstree.generate(d.value));
      },
    });
  } catch { /* ignore */ }
  return result;
}

// ── Color parsing ─────────────────────────────────────────────────────────────

type RGBA = [number, number, number, number];

const NAMED_COLORS: Record<string, RGBA> = {
  transparent:  [0,   0,   0,   0],
  black:        [0,   0,   0,   255],
  white:        [255, 255, 255, 255],
  red:          [255, 0,   0,   255],
  green:        [0,   128, 0,   255],
  lime:         [0,   255, 0,   255],
  blue:         [0,   0,   255, 255],
  yellow:       [255, 255, 0,   255],
  orange:       [255, 165, 0,   255],
  purple:       [128, 0,   128, 255],
  fuchsia:      [255, 0,   255, 255],
  magenta:      [255, 0,   255, 255],
  cyan:         [0,   255, 255, 255],
  aqua:         [0,   255, 255, 255],
  pink:         [255, 192, 203, 255],
  gray:         [128, 128, 128, 255],
  grey:         [128, 128, 128, 255],
  silver:       [192, 192, 192, 255],
  maroon:       [128, 0,   0,   255],
  navy:         [0,   0,   128, 255],
  olive:        [128, 128, 0,   255],
  teal:         [0,   128, 128, 255],
  brown:        [165, 42,  42,  255],
  coral:        [255, 127, 80,  255],
  salmon:       [250, 128, 114, 255],
  gold:         [255, 215, 0,   255],
  violet:       [238, 130, 238, 255],
  indigo:       [75,  0,   130, 255],
  turquoise:    [64,  224, 208, 255],
  darkgray:     [169, 169, 169, 255],
  darkgrey:     [169, 169, 169, 255],
  lightgray:    [211, 211, 211, 255],
  lightgrey:    [211, 211, 211, 255],
  darkblue:     [0,   0,   139, 255],
  darkgreen:    [0,   100, 0,   255],
  darkred:      [139, 0,   0,   255],
  crimson:      [220, 20,  60,  255],
  tomato:       [255, 99,  71,  255],
  hotpink:      [255, 105, 180, 255],
  deepskyblue:  [0,   191, 255, 255],
  dodgerblue:   [30,  144, 255, 255],
  royalblue:    [65,  105, 225, 255],
  steelblue:    [70,  130, 180, 255],
  slategray:    [112, 128, 144, 255],
  slategrey:    [112, 128, 144, 255],
  dimgray:      [105, 105, 105, 255],
  dimgrey:      [105, 105, 105, 255],
  whitesmoke:   [245, 245, 245, 255],
  gainsboro:    [220, 220, 220, 255],
  snow:         [255, 250, 250, 255],
  ivory:        [255, 255, 240, 255],
  beige:        [245, 245, 220, 255],
  wheat:        [245, 222, 179, 255],
  tan:          [210, 180, 140, 255],
  sienna:       [160, 82,  45,  255],
  peru:         [205, 133, 63,  255],
  chocolate:    [210, 105, 30,  255],
  saddlebrown:  [139, 69,  19,  255],
};

function parseColorValue(value: string): RGBA {
  const v = value.trim().toLowerCase();

  // Named colors
  if (v in NAMED_COLORS) return NAMED_COLORS[v]!;

  // rgb() / rgba()
  const rgbMatch = v.match(/^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([\d.]+))?\s*\)$/);
  if (rgbMatch) {
    const a = rgbMatch[4] !== undefined ? Math.round(parseFloat(rgbMatch[4]) * 255) : 255;
    return [parseInt(rgbMatch[1]!), parseInt(rgbMatch[2]!), parseInt(rgbMatch[3]!), a];
  }

  // #rgb / #rrggbb / #rrggbbaa
  const hexMatch = v.match(/^#([0-9a-f]+)$/);
  if (hexMatch) {
    const h = hexMatch[1]!;
    if (h.length === 3) {
      return [
        parseInt(h[0]! + h[0], 16), parseInt(h[1]! + h[1], 16),
        parseInt(h[2]! + h[2], 16), 255,
      ];
    }
    if (h.length === 6) {
      return [
        parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16),
        parseInt(h.slice(4, 6), 16), 255,
      ];
    }
    if (h.length === 8) {
      return [
        parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16),
        parseInt(h.slice(4, 6), 16), parseInt(h.slice(6, 8), 16),
      ];
    }
  }

  return [204, 204, 204, 255]; // fallback: default fg
}

// ── Declaration application ───────────────────────────────────────────────────

// Returns: null=auto/none, negative=percent (-50.0=50%), positive=px
function parseWireLength(value: string, base = 16): number | null {
  const v = value.trim().toLowerCase();
  if (v === "auto" || v === "none" || v === "") return null;
  if (v.endsWith("%")) {
    const pct = parseFloat(v);
    return isNaN(pct) ? null : -pct;
  }
  const px = parseLengthPx(v, base);
  return px > 0 ? px : null;
}

function parseLengthPx(value: string, base = 16): number {
  const n = parseFloat(value);
  if (isNaN(n)) return 0;
  if (value.endsWith("em") || value.endsWith("rem")) return n * base;
  if (value.endsWith("pt"))  return n * 1.333;
  if (value.endsWith("%"))   return (n / 100) * base;
  return n; // px or unitless
}

function normalizeFontWeight(value: string): string {
  const n = parseInt(value);
  if (!isNaN(n)) return n >= 600 ? "bold" : "normal";
  if (value === "bold" || value === "bolder") return "bold";
  return "normal";
}

function parseShorthand4(value: string): [number, number, number, number] {
  const parts = value.trim().split(/\s+/);
  const px = (s: string) => parseLengthPx(s);
  if (parts.length === 1) { const v = px(parts[0]!); return [v, v, v, v]; }
  if (parts.length === 2) { const [t, r] = [px(parts[0]!), px(parts[1]!)]; return [t, r, t, r]; }
  if (parts.length === 3) { return [px(parts[0]!), px(parts[1]!), px(parts[2]!), px(parts[1]!)]; }
  return [px(parts[0]!), px(parts[1]!), px(parts[2]!), px(parts[3]!)];
}

function applyDeclaration(style: WireStyle, prop: string, value: string): void {
  switch (prop) {
    case "display":           style.display = value; break;
    case "visibility":        style.visibility = value; break;
    case "color":             style.color = parseColorValue(value); break;
    case "background-color":
    case "background":        style.background_color = parseColorValue(value); break;
    case "font-weight":       style.font_weight = normalizeFontWeight(value); break;
    case "font-style":        style.font_style = value.includes("italic") ? "italic" : "normal"; break;
    case "text-decoration":
    case "text-decoration-line": style.text_decoration = value; break;
    case "text-align":        style.text_align = value; break;
    case "white-space":       style.white_space = value; break;
    case "font-size":         style.font_size = parseLengthPx(value, style.font_size); break;
    case "line-height":       style.line_height = parseLengthPx(value, 1) || parseFloat(value) || 1.4; break;
    case "opacity":           style.opacity = parseFloat(value) || 1; break;
    case "margin":            style.margin = parseShorthand4(value); break;
    case "margin-top":        style.margin = [parseLengthPx(value), style.margin[1], style.margin[2], style.margin[3]]; break;
    case "margin-right":      style.margin = [style.margin[0], parseLengthPx(value), style.margin[2], style.margin[3]]; break;
    case "margin-bottom":     style.margin = [style.margin[0], style.margin[1], parseLengthPx(value), style.margin[3]]; break;
    case "margin-left":       style.margin = [style.margin[0], style.margin[1], style.margin[2], parseLengthPx(value)]; break;
    case "padding":           style.padding = parseShorthand4(value); break;
    case "padding-top":       style.padding = [parseLengthPx(value), style.padding[1], style.padding[2], style.padding[3]]; break;
    case "padding-right":     style.padding = [style.padding[0], parseLengthPx(value), style.padding[2], style.padding[3]]; break;
    case "padding-bottom":    style.padding = [style.padding[0], style.padding[1], parseLengthPx(value), style.padding[3]]; break;
    case "padding-left":      style.padding = [style.padding[0], style.padding[1], style.padding[2], parseLengthPx(value)]; break;
    case "flex-direction":    style.flex_direction  = value; break;
    case "flex-wrap":         style.flex_wrap        = value; break;
    case "justify-content":   style.justify_content  = value; break;
    case "align-items":       style.align_items      = value; break;
    case "flex-grow":         style.flex_grow        = parseFloat(value) || 0; break;
    case "flex-shrink":       style.flex_shrink      = parseFloat(value) || 1; break;
    case "flex-basis":        style.flex_basis       = parseWireLength(value) ?? -1; break;
    case "flex": {
      const parts = value.trim().split(/\s+/);
      if (parts.length === 1) {
        style.flex_grow = parseFloat(parts[0]!) || 0;
        style.flex_shrink = 1; style.flex_basis = 0;
      } else if (parts.length >= 2) {
        style.flex_grow   = parseFloat(parts[0]!) || 0;
        style.flex_shrink = parseFloat(parts[1]!) || 1;
        if (parts.length >= 3) style.flex_basis = parseWireLength(parts[2]!) ?? -1;
      }
      break;
    }
    case "width":             style.width = parseWireLength(value, style.font_size) ?? undefined; break;
  }
}

function applyDeclarations(style: WireStyle, decls: Map<string, string>): void {
  for (const [prop, value] of decls) {
    applyDeclaration(style, prop, value);
  }
}

// ── Style computation ─────────────────────────────────────────────────────────

function computeStyle(
  tag: string,
  attrMap: Record<string, string>,
  parentStyle: WireStyle,
  authorRules: StyleSheet,
): WireStyle {
  const style: WireStyle = { ...DEFAULT_STYLE };

  // 1. Inherit from parent
  for (const prop of INHERITED_PROPS) {
    (style as Record<string, unknown>)[prop] = (parentStyle as Record<string, unknown>)[prop];
  }

  // 2. Browser defaults for this tag
  const browserDef = BROWSER_DEFAULTS[tag];
  if (browserDef) Object.assign(style, browserDef);

  // 3. Author stylesheet — tag rules
  const tagRules = authorRules.byTag.get(tag);
  if (tagRules) applyDeclarations(style, tagRules);

  // 4. Author stylesheet — class rules
  const classes = (attrMap["class"] ?? "").split(/\s+/).filter(Boolean);
  for (const cls of classes) {
    const clsRules = authorRules.byClass.get(cls);
    if (clsRules) applyDeclarations(style, clsRules);
  }

  // 5. Inline style attribute
  if (attrMap["style"]) {
    applyDeclarations(style, parseDeclarationList(attrMap["style"]));
  }

  return style;
}

// ── parse5 tree walk ──────────────────────────────────────────────────────────

let nodeIdCounter = 1;
function nextId(): number { return nodeIdCounter++; }

function attrsToRecord(attrs: { name: string; value: string }[]): Record<string, string> {
  const r: Record<string, string> = {};
  for (const { name, value } of attrs) r[name] = value;
  return r;
}

interface ListCtx {
  type: "ul" | "ol";
  counter: number;
}

function walkNode(
  node: ChildNode,
  parentStyle: WireStyle,
  authorRules: StyleSheet,
  listCtx?: ListCtx,
): WireNode | null {
  if (adapter.isTextNode(node)) {
    const raw = (node as TextNode).value;
    const isPreContext = parentStyle.white_space === "pre";
    if (!isPreContext) {
      const normalized = raw.replace(/[\n\r\t ]+/g, " ");
      if (!normalized.trim()) return null;
      return {
        id: nextId(), type: "text",
        text: normalized,
        style: { ...parentStyle, display: "inline" },
      };
    }
    // pre context: preserve as-is
    return { id: nextId(), type: "text", text: raw, style: { ...parentStyle, display: "inline", white_space: "pre" } };
  }

  if (!adapter.isElementNode(node)) return null;

  const el = node as Element;
  const tag = el.tagName.toLowerCase();
  const attrMap = attrsToRecord(el.attrs);
  const style = computeStyle(tag, attrMap, parentStyle, authorRules);

  if (style.display === "none") return null;

  // <br> → newline text node
  if (tag === "br") {
    return { id: nextId(), type: "text", text: "\n", style: { ...style, display: "inline", white_space: "pre" } };
  }

  // <hr> → empty block element with tag preserved for Zig renderer
  if (tag === "hr") {
    return { id: nextId(), type: "element", tag: "hr", style, children: [] };
  }

  // <img> → placeholder element with alt text as text child
  if (tag === "img") {
    const alt = attrMap["alt"] ?? "";
    const children: WireNode[] = alt
      ? [{ id: nextId(), type: "text", text: alt, style: { ...style, display: "inline" } }]
      : [];
    return { id: nextId(), type: "element", tag: "img", style, children };
  }

  // <details> → show summary + optionally rest of children
  if (tag === "details") {
    const isOpen = "open" in attrMap;
    const children: WireNode[] = [];
    // Add a ▶/▼ triangle to the summary indicator
    const triangle = isOpen ? "▼ " : "▶ ";
    for (const child of el.childNodes) {
      const childEl = adapter.isElementNode(child) ? (child as Element) : null;
      const childTag = childEl?.tagName.toLowerCase() ?? "";
      if (childTag === "summary") {
        const summaryStyle = computeStyle("summary", {}, style, authorRules);
        const summaryChildren: WireNode[] = [
          { id: nextId(), type: "text", text: triangle, style: { ...summaryStyle, display: "inline" } },
        ];
        for (const summaryChild of (childEl?.childNodes ?? [])) {
          const wn = walkNode(summaryChild, summaryStyle, authorRules, undefined);
          if (wn) summaryChildren.push(wn);
        }
        children.push({ id: nextId(), type: "element", tag: "summary", style: summaryStyle, children: summaryChildren });
      } else if (isOpen) {
        const wn = walkNode(child, style, authorRules, undefined);
        if (wn) children.push(wn);
      }
    }
    return { id: nextId(), type: "element", tag: "details", style, children };
  }

  // Determine list context for children
  const childListCtx: ListCtx | undefined =
    tag === "ul" ? { type: "ul", counter: 1 } :
    tag === "ol" ? { type: "ol", counter: 1 } :
    undefined;

  const children: WireNode[] = [];

  // <li> — prepend list marker as first child
  if (tag === "li" && listCtx) {
    const marker = listCtx.type === "ul"
      ? "• "
      : `${listCtx.counter}. `;
    if (listCtx.type === "ol") listCtx.counter++;
    children.push({
      id: nextId(), type: "text",
      text: marker,
      style: { ...style, display: "inline", font_weight: listCtx.type === "ol" ? "normal" : style.font_weight },
    });
  }

  for (const child of el.childNodes) {
    const wn = walkNode(child, style, authorRules, childListCtx ?? listCtx);
    if (wn) children.push(wn);
  }

  const wn: WireNode = { id: nextId(), type: "element", tag, style, children };
  if (tag === "a" && attrMap["href"]) wn.href = attrMap["href"];
  return wn;
}

// ── Document helpers ──────────────────────────────────────────────────────────

function findTag(node: any, tag: string): Element | null {
  if (adapter.isElementNode(node) && (node as Element).tagName.toLowerCase() === tag) {
    return node as Element;
  }
  const children: any[] = node.childNodes ?? [];
  for (const child of children) {
    const found = findTag(child, tag);
    if (found) return found;
  }
  return null;
}

function extractStyleBlocks(document: Document): string {
  const parts: string[] = [];
  function walkDoc(node: any): void {
    if (adapter.isElementNode(node)) {
      const el = node as Element;
      if (el.tagName.toLowerCase() === "style") {
        for (const child of el.childNodes) {
          if (adapter.isTextNode(child)) parts.push((child as TextNode).value);
        }
      }
      for (const child of el.childNodes) walkDoc(child);
    } else if (node.childNodes) {
      for (const child of node.childNodes) walkDoc(child);
    }
  }
  walkDoc(document);
  return parts.join("\n");
}

function extractTitle(document: Document): string {
  const titleEl = findTag(document, "title");
  if (!titleEl) return "Untitled";
  const text = titleEl.childNodes
    .filter(adapter.isTextNode)
    .map((n) => (n as TextNode).value)
    .join("");
  return text.trim() || "Untitled";
}

function emptyBody(): WireNode {
  return { id: nextId(), type: "element", tag: "body", style: { ...DEFAULT_STYLE }, children: [] };
}

// ── Entry point ───────────────────────────────────────────────────────────────

export async function buildDomReady(
  id: number,
  url: string,
  html: string,
): Promise<DomReadyMsg> {
  nodeIdCounter = 1;

  const document = parse(html);
  const styleText = extractStyleBlocks(document);
  const authorRules = parseStylesheet(styleText);
  const title = extractTitle(document);

  const bodyEl = findTag(document, "body");
  const root: WireNode = bodyEl
    ? (walkNode(bodyEl as unknown as ChildNode, DEFAULT_STYLE, authorRules) ?? emptyBody())
    : emptyBody();

  return { type: "dom_ready", id, url, title, root };
}
