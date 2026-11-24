import { isSha256Fingerprint } from "../contract/book";
import { normalizeWord, wordId } from "../contract/wordId";
import type { ClientKind } from "./wire";

export { normalizeWord, wordId };

const HEX_32 = /^[0-9a-f]{32}$/;

export function randomHexId(prefix: "h" | "l"): string {
  const hex = globalThis.crypto.randomUUID().replace(/-/g, "");
  return `${prefix}_${hex}`;
}

export function positionId(bookId: string, deviceId: string): string {
  return `p_${bookId}_${deviceId}`;
}

export function bookIdForSha(sha256: string): string {
  return `sha256:${sha256.toLowerCase()}`;
}

/** Control characters and the length cap. Comparison stays byte-exact. */
export function invalidRecordId(id: string): string | null {
  const bytes = new TextEncoder().encode(id);
  if (bytes.length < 1 || bytes.length > 512) return "id must be 1 to 512 UTF-8 bytes";
  for (let index = 0; index < id.length; ) {
    const codePoint = id.codePointAt(index) ?? 0;
    if (codePoint <= 0x1f || (codePoint >= 0x7f && codePoint <= 0x9f)) {
      return "id must not contain control characters";
    }
    index += codePoint > 0xffff ? 2 : 1;
  }
  return null;
}

export function isCanonicalPrefixedId(id: string, prefix: "h" | "l"): boolean {
  return id.startsWith(`${prefix}_`) && HEX_32.test(id.slice(2));
}

export function expectedPositionId(bookId: string, deviceId: string): string {
  return positionId(bookId, deviceId);
}

export function assertBookId(bookId: string): boolean {
  return isSha256Fingerprint(bookId);
}

export function kindOfClient(kind: string): kind is ClientKind {
  return kind === "highlight" || kind === "note" || kind === "word" || kind === "lookup" || kind === "position";
}
