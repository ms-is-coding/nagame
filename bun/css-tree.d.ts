// Minimal type declarations for css-tree v2 (no official @types package).
declare module "css-tree" {
  interface CssNode { type: string; }
  interface Declaration extends CssNode { type: "Declaration"; property: string; value: CssNode; }
  interface Rule extends CssNode { type: "Rule"; prelude: CssNode; block: CssNode; }
  interface Selector extends CssNode { type: "Selector"; }
  type WalkOptions = { visit?: string; enter?: (node: any) => void; leave?: (node: any) => void };
  export function parse(css: string, options?: { context?: string }): CssNode;
  export function walk(ast: CssNode, options: WalkOptions | ((node: any) => void)): void;
  export function generate(ast: CssNode): string;
}
