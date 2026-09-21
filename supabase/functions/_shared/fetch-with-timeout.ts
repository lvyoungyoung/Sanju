// Keep the deadline active through body consumption, not just response headers.
export async function fetchWithTimeout(
  input: string | URL | Request,
  init: RequestInit | undefined,
  timeoutMs: number,
  fetcher: typeof fetch = fetch,
): Promise<Response> {
  const controller = new AbortController();
  const parentSignal = init?.signal ??
    (input instanceof Request ? input.signal : undefined);
  let timer: ReturnType<typeof setTimeout> | undefined;
  let cancel: () => void = () => {};
  const interrupted = new Promise<never>((_, reject) => {
    const stop = (reason: unknown) => {
      controller.abort(reason);
      reject(reason);
    };
    cancel = () =>
      stop(
        parentSignal?.reason ??
          new DOMException("Request aborted", "AbortError"),
      );
    if (parentSignal?.aborted) {
      cancel();
    } else {
      parentSignal?.addEventListener("abort", cancel, { once: true });
    }
    timer = setTimeout(
      () => stop(new DOMException("Request timed out", "AbortError")),
      Math.max(0, timeoutMs),
    );
  });

  try {
    return await Promise.race([
      interrupted,
      (async () => {
        if (controller.signal.aborted) throw controller.signal.reason;
        const response = await fetcher(input, {
          ...init,
          signal: controller.signal,
        });
        const body = await response.arrayBuffer();
        return new Response(
          [204, 205, 304].includes(response.status) ? null : body,
          {
            status: response.status,
            statusText: response.statusText,
            headers: response.headers,
          },
        );
      })(),
    ]);
  } finally {
    clearTimeout(timer);
    parentSignal?.removeEventListener("abort", cancel);
  }
}

export function fetchWithinDeadline(
  deadline: number,
  fetcher: typeof fetch = fetch,
): typeof fetch {
  return (input, init) => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      return Promise.reject(
        new DOMException("Request timed out", "AbortError"),
      );
    }
    return fetchWithTimeout(input, init, remaining, fetcher);
  };
}
