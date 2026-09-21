import { rejects, strictEqual } from "node:assert";
import {
  fetchWithinDeadline,
  fetchWithTimeout,
} from "../../supabase/functions/_shared/fetch-with-timeout.ts";

Deno.test("HTTP deadline includes stalled response bodies and aborts the transport", async () => {
  let aborted = false;
  const fetcher = ((_input: unknown, init: RequestInit) =>
    Promise.resolve(
      new Response(
        new ReadableStream({
          start(controller) {
            init.signal?.addEventListener("abort", () => {
              aborted = true;
              controller.error(init.signal?.reason);
            }, { once: true });
            controller.enqueue(new TextEncoder().encode('{"partial":'));
          },
        }),
      ),
    )) as typeof fetch;
  await rejects(
    () => fetchWithTimeout("https://example.invalid", {}, 10, fetcher),
    (error: unknown) =>
      error instanceof DOMException && error.name === "AbortError",
  );
  strictEqual(aborted, true);
});

Deno.test("HTTP deadline also handles slow headers, parent cancellation and expired total budgets", async () => {
  const fetcher =
    ((_input: unknown, init: RequestInit) =>
      new Promise((_resolve, reject) => {
        init.signal?.addEventListener("abort", () =>
          reject(init.signal?.reason), { once: true });
      })) as typeof fetch;
  await rejects(
    () => fetchWithTimeout("https://example.invalid", {}, 10, fetcher),
    /timed out/,
  );
  const parent = new AbortController();
  const waiting = fetchWithTimeout(
    "https://example.invalid",
    { signal: parent.signal },
    1000,
    fetcher,
  );
  parent.abort();
  await rejects(
    () => waiting,
    (error: unknown) =>
      error instanceof DOMException && error.name === "AbortError",
  );
  let calls = 0;
  const expired = fetchWithinDeadline(
    Date.now() - 1,
    (() => {
      calls++;
      return Promise.resolve(new Response());
    }) as typeof fetch,
  );
  await rejects(() => expired("https://example.invalid"), /timed out/);
  strictEqual(calls, 0);
});

Deno.test("buffered responses retain status, headers, JSON and no-content semantics", async () => {
  for (const status of [200, 403, 500]) {
    const response = await fetchWithTimeout(
      "https://example.invalid",
      {},
      1000,
      (() =>
        Promise.resolve(
          Response.json({ status }, {
            status,
            headers: { "x-test": "preserved" },
          }),
        )) as typeof fetch,
    );
    strictEqual(response.status, status);
    strictEqual(response.headers.get("x-test"), "preserved");
    strictEqual((await response.json()).status, status);
  }
  const empty = await fetchWithTimeout(
    "https://example.invalid",
    {},
    1000,
    (() =>
      Promise.resolve(new Response(null, { status: 204 }))) as typeof fetch,
  );
  strictEqual(await empty.text(), "");
});
