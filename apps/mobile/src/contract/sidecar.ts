import type { HighlightRecord, JsonValue, LookupRecord, NoteRecord } from "./types";

/**
 * Compact JSON for `<!-- reader {…} -->`. Keys are sorted. `--` inside a
 * string is written as `\u002d\u002d` so the comment cannot close early
 * (`JSONValue.escape`).
 */

function escapeString(value: string): string {
  let out = "";
  let previousDash = false;
  for (const char of value) {
    if (previousDash && char === "-") {
      out = out.slice(0, -1);
      out += "\\u002d\\u002d";
      previousDash = false;
      continue;
    }
    previousDash = char === "-";
    switch (char) {
      case '"':
        out += '\\"';
        break;
      case "\\":
        out += "\\\\";
        break;
      case "\n":
        out += "\\n";
        break;
      case "\r":
        out += "\\r";
        break;
      case "\t":
        out += "\\t";
        break;
      case "\b":
        out += "\\b";
        break;
      case "\f":
        out += "\\f";
        break;
      default: {
        const code = char.codePointAt(0) ?? 0;
        if (code < 0x20) {
          out += `\\u${code.toString(16).padStart(4, "0")}`;
        } else {
          out += char;
        }
      }
    }
  }
  return out;
}

function encodeNumber(number: number): string {
  if (!Number.isFinite(number)) return "0";
  if (Number.isInteger(number) && Math.abs(number) < 1e15) return String(number);
  return JSON.stringify(number);
}

export function compactJson(value: JsonValue): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return encodeNumber(value);
  if (typeof value === "string") return `"${escapeString(value)}"`;
  if (Array.isArray(value)) return `[${value.map((item) => compactJson(item)).join(",")}]`;
  const keys = Object.keys(value).sort();
  const pairs = keys.map((key) => `"${escapeString(key)}":${compactJson(value[key] ?? null)}`);
  return `{${pairs.join(",")}}`;
}

export function readerComment(value: JsonValue): string {
  return `<!-- reader ${compactJson(value)} -->`;
}

/** Sidecar object for a highlight. `noteId` is written under the key `note`. */
export function highlightSidecarObject(highlight: HighlightRecord): { [key: string]: JsonValue } {
  const object: { [key: string]: JsonValue } = { ...highlight.extras };
  object.id = highlight.id;
  object.color = highlight.color;
  if (highlight.page !== undefined) object.page = highlight.page;
  if (highlight.cfi !== undefined) object.cfi = highlight.cfi;
  object.quote = highlight.quote;
  object.prefix = highlight.prefix;
  object.suffix = highlight.suffix;
  if (highlight.section !== undefined) object.section = highlight.section;
  if (highlight.rects.length > 0) object.rects = highlight.rects;
  if (highlight.noteId !== undefined) object.note = highlight.noteId;
  return object;
}

/** Sidecar object for a note. The body stays in the markdown prose, not the comment. */
export function noteSidecarObject(note: NoteRecord): { [key: string]: JsonValue } {
  const object: { [key: string]: JsonValue } = { ...note.extras };
  object.id = note.id;
  if (note.page !== undefined) object.page = note.page;
  if (note.cfi !== undefined) object.cfi = note.cfi;
  object.quote = note.quote;
  object.prefix = note.prefix;
  object.suffix = note.suffix;
  if (note.section !== undefined) object.section = note.section;
  if (note.created !== undefined) object.created = note.created;
  if (note.updated !== undefined) object.updated = note.updated;
  if (note.ai) object.ai = true;
  if (note.provider !== undefined) object.provider = note.provider;
  if (note.scope !== "passage") object.scope = note.scope;
  return object;
}

/** Sidecar object for one lookup. The id is stored under `lookup`. */
export function lookupSidecarObject(lookup: LookupRecord): { [key: string]: JsonValue } {
  const object: { [key: string]: JsonValue } = { ...lookup.extras };
  object.lookup = lookup.id;
  if (lookup.page !== undefined) object.page = lookup.page;
  if (lookup.cfi !== undefined) object.cfi = lookup.cfi;
  object.quote = lookup.quote;
  object.prefix = lookup.prefix;
  object.suffix = lookup.suffix;
  if (lookup.section !== undefined) object.section = lookup.section;
  if (lookup.sentence.length > 0) object.sentence = lookup.sentence;
  if (lookup.date.length > 0) object.date = lookup.date;
  return object;
}
