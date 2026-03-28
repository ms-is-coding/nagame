// Bun worker entry point — IPC message router
// Spawned by Zig as a child process; communicates via stdin/stdout pipes.

import { readMessages, sendMessage } from "./transport.ts";
import type { ZigToBun, NavigateMsg, ResizeMsg, EvalMsg } from "./protocol.ts";

const DEBUG = !!process.env.ZIG_BROWSER_DEBUG;

function dbg(msg: string) {
  if (DEBUG) process.stderr.write(`[bun] ${msg}\n`);
}

// ── Handler registry ─────────────────────────────────────────────────────────

const handlers = new Map<string, (msg: any) => Promise<void> | void>();

function on<T extends ZigToBun>(type: T["type"], handler: (msg: T) => Promise<void> | void) {
  handlers.set(type as string, handler as (msg: any) => Promise<void> | void);
}

// ── Handlers ─────────────────────────────────────────────────────────────────

on<NavigateMsg>("navigate", async (msg) => {
  dbg(`navigate id=${msg.id} url=${msg.url}`);

  const { navigate } = await import("./fetch/client.ts");
  const { buildDomReady } = await import("./html/pipeline.ts");

  try {
    const { url, html } = await navigate(msg.url, msg.method ?? "GET", msg.body);
    const domReady = await buildDomReady(msg.id, url, html);
    sendMessage(domReady);
  } catch (e: any) {
    sendMessage({ type: "error", id: msg.id, code: 0, message: String(e?.message ?? e) });
  }
});

on<ResizeMsg>("resize", (msg) => {
  dbg(`resize ${msg.cols}x${msg.rows}`);
  process.env.BROWSER_COLS = String(msg.cols);
  process.env.BROWSER_ROWS = String(msg.rows);
  process.env.BROWSER_PX_W = String(msg.px_width);
  process.env.BROWSER_PX_H = String(msg.px_height);
});

on<EvalMsg>("eval", async (msg) => {
  dbg(`eval id=${msg.id}`);
  sendMessage({ type: "error", id: msg.id, code: 0, message: "JS eval not yet implemented" });
});

// ── Main loop ─────────────────────────────────────────────────────────────────

async function main() {
  dbg("starting");
  sendMessage({ type: "ready" });
  dbg("sent ready");

  for await (const msg of readMessages()) {
    dbg(`recv type=${msg.type}`);
    const handler = handlers.get(msg.type);
    if (handler) {
      try {
        await handler(msg);
      } catch (e) {
        process.stderr.write(`[bun] error in ${msg.type}: ${e}\n`);
      }
    }
  }
}

main().catch((e) => {
  process.stderr.write(`[bun] fatal: ${e}\n`);
  process.exit(1);
});
