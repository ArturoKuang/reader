import type { BookIdentity, IdentityMatch } from "./types";

const FINGERPRINT = /^sha256:[0-9a-f]{64}$/;

/** True when the value is `sha256:` plus 64 lowercase hex digits. */
export function isSha256Fingerprint(value: string): boolean {
  return FINGERPRINT.test(value);
}

/**
 * SidecarStore.matchIdentity. Equal fingerprints win. Otherwise a non-empty
 * shared pdfId or epubId is the same book after a small edit. Anything else
 * is a different file and must be reanchored by quote + prefix + suffix.
 */
export function matchBookIdentity(
  current: BookIdentity,
  other: BookIdentity,
): IdentityMatch {
  if (other.fingerprint.length > 0 && current.fingerprint === other.fingerprint) {
    return "exact";
  }
  if (current.pdfId && other.pdfId && current.pdfId === other.pdfId) {
    return "stableID";
  }
  if (current.epubId && other.epubId && current.epubId === other.epubId) {
    return "stableID";
  }
  return "different";
}

/**
 * PDFIdentity.scan. ISO-Latin-1, last `/ID`, first `<…>` after it, hex
 * digits only, lowercased. The second id in a pair is ignored.
 */
export function scanPdfId(data: Uint8Array): string | undefined {
  let text = "";
  for (let index = 0; index < data.length; index += 1) {
    text += String.fromCharCode(data[index]);
  }
  const idAt = text.lastIndexOf("/ID");
  if (idAt < 0) return undefined;
  const tail = text.slice(idAt + "/ID".length);
  const open = tail.indexOf("<");
  if (open < 0) return undefined;
  const close = tail.indexOf(">", open + 1);
  if (close < 0) return undefined;
  const hex = tail
    .slice(open + 1, close)
    .replace(/[^0-9a-fA-F]/g, "")
    .toLowerCase();
  return hex.length === 0 ? undefined : hex;
}

/**
 * First `dc:identifier` text in an OPF document, trimmed. Empty means
 * absent. This is the field EPUBBook stores as `identifier`.
 */
export function readEpubIdentifier(opf: string): string | undefined {
  const match = opf.match(/<dc:identifier\b[^>]*>([\s\S]*?)<\/dc:identifier>/i);
  if (!match) return undefined;
  const text = match[1].replace(/<[^>]+>/g, "").trim();
  return text.length === 0 ? undefined : text;
}
