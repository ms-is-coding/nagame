// HTTP client using Bun.fetch with redirect following and basic headers.

const USER_AGENT = "TUI-Browser/0.1";
const MAX_REDIRECTS = 10;
const TIMEOUT_MS = 30_000;

export type FetchResult = {
  url: string;
  html: string;
  status: number;
};

export async function navigate(
  url: string,
  method = "GET",
  body?: string,
): Promise<FetchResult> {
  let currentUrl = url;

  for (let redirect = 0; redirect < MAX_REDIRECTS; redirect++) {
    const res = await fetch(currentUrl, {
      method,
      body: body ?? undefined,
      headers: {
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.9",
        "Accept-Language": "en",
      },
      redirect: "manual",
      // @ts-ignore — Bun supports signal via AbortController
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });

    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      if (!loc) throw new Error(`Redirect ${res.status} with no Location header`);
      currentUrl = new URL(loc, currentUrl).href;
      continue;
    }

    const html = await res.text();
    return { url: currentUrl, html, status: res.status };
  }

  throw new Error(`Too many redirects for ${url}`);
}
