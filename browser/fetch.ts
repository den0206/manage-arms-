import { PAGE_LIMIT } from "../core/limits.js";

/** JSON 応答を 2 MB まで読む。上限超過・通信失敗・壊れた JSON は同じく読めなかった扱い。 */
export async function fetchJson(url: string, fetchImpl: typeof fetch = fetch): Promise<unknown | null> {
  const response = await fetchImpl(url, { cache: "no-store" }).catch(() => null);
  if (response === null || !response.ok || response.body === null) return null;
  if (Number(response.headers.get("content-length") ?? 0) > PAGE_LIMIT) {
    await response.body.cancel();
    return null;
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let size = 0;
  let text = "";
  try {
    for (;;) {
      const next = await reader.read();
      if (next.done) break;
      size += next.value.length;
      if (size > PAGE_LIMIT) {
        await reader.cancel();
        return null;
      }
      text += decoder.decode(next.value, { stream: true });
    }
  } catch {
    return null;
  } finally {
    reader.releaseLock();
  }
  try {
    return JSON.parse(text + decoder.decode());
  } catch {
    return null;
  }
}
