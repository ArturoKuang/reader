import { isSha256Fingerprint } from "../contract/book";
import { normalizeWord, wordId } from "../contract/wordId";
import type { ClientKind } from "./wire";

export { normalizeWord, wordId };

const HEX_32 = /^[0-9a-f]{32}$/;

/**
 * Spec rev 3 says a note reuses its highlight's id, and also that note ids
 * are `n_` plus 32 hex. The phone contract stores two records: `h_` and
 * `n_` are different strings, and `highlight.noteId` is the link of record.
 * A note minted for a highlight therefore keeps the highlight's 32 hex
 * digits and switches the prefix to `n_`. Callers that already have a note
 * id (the highlight spike uses short ids) keep that id; the wire rule for
 * any id is 1–512 bytes and no control characters.
 */
export function noteIdForHighlight(highlightId: string): string | null {
  const match = /^h_([0-9a-f]{32})$/.exec(highlightId);
  if (!match) return null;
  return `n_${match[1]}`;
}

export function randomHexId(prefix: "h" | "n" | "l"): string {
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

export function isCanonicalPrefixedId(id: string, prefix: "h" | "n" | "l"): boolean {
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
