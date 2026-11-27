import type { JsonValue } from "../contract/types";
import type { JsonObject } from "./wire";

/** Recursively sort object keys. Arrays keep their order. Drops `undefined`. */
export function sortJson(value: unknown): JsonValue {
  if (value === null || value === undefined) return null;
  if (typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (Array.isArray(value)) return value.map((item) => sortJson(item));
  if (typeof value === "object") {
    const source = value as Record<string, unknown>;
    const sorted: { [key: string]: JsonValue } = {};
    for (const key of Object.keys(source).sort()) {
      if (source[key] !== undefined) sorted[key] = sortJson(source[key]);
    }
    return sorted;
  }
  return null;
}

/** Byte-stable JSON used for payload equality. Key order does not matter. */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(sortJson(value));
}

export function payloadsEqual(left: unknown, right: unknown): boolean {
  return canonicalJson(left) === canonicalJson(right);
}

export function sameRecord(
  left: { deleted: boolean; payload: unknown },
  right: { deleted: boolean; payload: unknown },
): boolean {
  return left.deleted === right.deleted && payloadsEqual(left.payload, right.payload);
}

export function asJsonObject(value: unknown): JsonObject {
  const sorted = sortJson(value);
  if (sorted === null || typeof sorted !== "object" || Array.isArray(sorted)) {
    throw new Error("payload must be a JSON object");
  }
  return sorted;
}

export function utf8Size(value: string): number {
  return new TextEncoder().encode(value).length;
}

export function clone<T>(value: T): T {
  return structuredClone(value);
}
