import { isHighlightColor, type HighlightRecord, type JsonValue, type LookupRecord, type NoteRecord, type WordRecord } from "../contract/types";
import { asJsonObject } from "./canonical";
import { wordId } from "./ids";
import type { JsonObject, Locator, PositionPayload } from "./wire";

function copyExtras(extras: { [key: string]: JsonValue } | undefined): { [key: string]: JsonValue } {
  return { ...(extras ?? {}) };
}

function withOptionals(target: Record<string, unknown>, source: object): void {
  for (const [key, value] of Object.entries(source)) {
    if (value !== undefined) target[key] = value;
  }
}

export function highlightToPayload(highlight: HighlightRecord): JsonObject {
  const payload: Record<string, unknown> = {
    color: highlight.color,
    quote: highlight.quote,
    prefix: highlight.prefix,
    suffix: highlight.suffix,
    extras: copyExtras(highlight.extras),
  };
  withOptionals(payload, {
    page: highlight.page,
    cfi: highlight.cfi,
    section: highlight.section,
    rects: highlight.rects,
  });
  return asJsonObject(payload);
}

export function noteToPayload(note: NoteRecord): JsonObject {
  const payload: Record<string, unknown> = {
    quote: note.quote,
    prefix: note.prefix,
    suffix: note.suffix,
    ai: note.ai,
    scope: note.scope,
    body: note.body,
    extras: copyExtras(note.extras),
  };
  withOptionals(payload, {
    page: note.page,
    cfi: note.cfi,
    section: note.section,
    created: note.created,
    updated: note.updated,
    provider: note.provider,
  });
  return asJsonObject(payload);
}

/** Lookups stay separate records. They are not nested in the word payload. */
export function wordToPayload(word: WordRecord): JsonObject {
  const payload: Record<string, unknown> = {
    word: word.word,
    definition: word.definition,
    learned: word.learned,
    extras: copyExtras(word.extras),
  };
  withOptionals(payload, {
    explanation: word.explanation,
    explanationProvider: word.explanationProvider,
    pronunciation: word.pronunciation,
    partOfSpeech: word.partOfSpeech,
  });
  const expectedId = wordId(word.word);
  if (expectedId === null || word.id !== expectedId) {
    throw new Error("word id must be w_ plus normalizeWord(word)");
  }
  return asJsonObject(payload);
}

export function lookupToPayload(wordIdValue: string, lookup: LookupRecord): JsonObject {
  const payload: Record<string, unknown> = {
    wordId: wordIdValue,
    quote: lookup.quote,
    prefix: lookup.prefix,
    suffix: lookup.suffix,
    sentence: lookup.sentence,
    date: lookup.date,
    extras: copyExtras(lookup.extras),
  };
  withOptionals(payload, {
    page: lookup.page,
    cfi: lookup.cfi,
    section: lookup.section,
  });
  return asJsonObject(payload);
}

export function positionToPayload(bookId: string, deviceId: string, locator: Locator): PositionPayload {
  return {
    bookId,
    deviceId,
    locator,
    extras: {},
  };
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function asRects(value: unknown): number[][] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is number[] => Array.isArray(item) && item.every((n) => typeof n === "number"));
}

function extrasOf(payload: JsonObject): { [key: string]: JsonValue } {
  const extras = payload.extras;
  if (!extras || typeof extras !== "object" || Array.isArray(extras)) return {};
  return { ...(extras as { [key: string]: JsonValue }) };
}

/** Rebuild a highlight from a pulled or persisted payload. */
export function highlightFromPayload(id: string, payload: JsonObject): HighlightRecord | null {
  const quote = asString(payload.quote);
  const prefix = asString(payload.prefix);
  const suffix = asString(payload.suffix);
  const color = asNumber(payload.color);
  if (quote === undefined || prefix === undefined || suffix === undefined || color === undefined) return null;
  if (!isHighlightColor(color)) return null;
  const record: HighlightRecord = {
    id,
    color,
    quote,
    prefix,
    suffix,
    rects: asRects(payload.rects),
    extras: extrasOf(payload),
  };
  const page = asNumber(payload.page);
  const cfi = asString(payload.cfi);
  const section = asString(payload.section);
  if (page !== undefined) record.page = page;
  if (cfi !== undefined) record.cfi = cfi;
  if (section !== undefined) record.section = section;
  return record;
}

/** Rebuild a note from a pulled or persisted payload. */
export function noteFromPayload(id: string, payload: JsonObject): NoteRecord | null {
  const quote = asString(payload.quote);
  const prefix = asString(payload.prefix);
  const suffix = asString(payload.suffix);
  const body = asString(payload.body);
  if (quote === undefined || prefix === undefined || suffix === undefined || body === undefined) return null;
  const record: NoteRecord = {
    id,
    quote,
    prefix,
    suffix,
    ai: payload.ai === true,
    scope: asString(payload.scope) ?? "passage",
    body,
    extras: extrasOf(payload),
  };
  const page = asNumber(payload.page);
  const cfi = asString(payload.cfi);
  const section = asString(payload.section);
  const created = asString(payload.created);
  const updated = asString(payload.updated);
  const provider = asString(payload.provider);
  if (page !== undefined) record.page = page;
  if (cfi !== undefined) record.cfi = cfi;
  if (section !== undefined) record.section = section;
  if (created !== undefined) record.created = created;
  if (updated !== undefined) record.updated = updated;
  if (provider !== undefined) record.provider = provider;
  return record;
}

/** Rebuild a saved word from a pulled or persisted payload. Lookups are attached by the caller. */
export function wordFromPayload(id: string, payload: JsonObject): WordRecord | null {
  const word = asString(payload.word);
  const definition = asString(payload.definition);
  if (word === undefined || definition === undefined) return null;
  const record: WordRecord = {
    id,
    word,
    definition,
    learned: payload.learned === true,
    lookups: [],
    extras: extrasOf(payload),
  };
  const explanation = asString(payload.explanation);
  const explanationProvider = asString(payload.explanationProvider);
  const pronunciation = asString(payload.pronunciation);
  const partOfSpeech = asString(payload.partOfSpeech);
  if (explanation !== undefined) record.explanation = explanation;
  if (explanationProvider !== undefined) record.explanationProvider = explanationProvider;
  if (pronunciation !== undefined) record.pronunciation = pronunciation;
  if (partOfSpeech !== undefined) record.partOfSpeech = partOfSpeech;
  return record;
}

