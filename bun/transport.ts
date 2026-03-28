// Length-prefix framed IPC transport over stdin/stdout.
// Frame format: [4 bytes big-endian uint32 length][N bytes UTF-8 JSON]

import type { BunToZig, ZigToBun } from "./protocol.ts";

const HEADER_SIZE = 4;

// Write a message to stdout
export function sendMessage(msg: BunToZig): void {
  const json = JSON.stringify(msg);
  const body = Buffer.from(json, "utf8");
  const header = Buffer.allocUnsafe(HEADER_SIZE);
  header.writeUInt32BE(body.byteLength, 0);
  const frame = Buffer.concat([header, body]);
  // Bun's process.stdout.write is synchronous for Buffer
  Bun.stdout.write(frame);
}

// Async generator that reads length-prefixed messages from stdin
export async function* readMessages(): AsyncGenerator<ZigToBun> {
  const chunks: Buffer[] = [];
  let buffered = 0;

  for await (const chunk of Bun.stdin.stream()) {
    chunks.push(Buffer.from(chunk));
    buffered += chunk.byteLength;

    // Process all complete messages in the buffer
    while (true) {
      // Need at least a header
      if (buffered < HEADER_SIZE) break;

      // Compute total buffered size as a single flat buffer (lazy concat)
      const flat = Buffer.concat(chunks);
      // Replace chunks with the flat buffer to avoid repeated concat
      chunks.length = 0;
      chunks.push(flat);

      const msgLen = flat.readUInt32BE(0);
      const frameLen = HEADER_SIZE + msgLen;

      if (buffered < frameLen) break;

      const json = flat.subarray(HEADER_SIZE, frameLen).toString("utf8");
      // Advance: keep remainder
      const remainder = flat.subarray(frameLen);
      chunks.length = 0;
      if (remainder.byteLength > 0) chunks.push(remainder);
      buffered = remainder.byteLength;

      try {
        yield JSON.parse(json) as ZigToBun;
      } catch (e) {
        process.stderr.write(`[transport] JSON parse error: ${e}\n`);
      }
    }
  }
}
