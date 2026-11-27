import * as Crypto from "expo-crypto";

/** `prefix_` plus 32 lowercase hex chars. Uses expo-crypto, not global crypto. */
export function makeId(prefix: string): string {
  const bytes = Crypto.getRandomBytes(16);
  let hex = "";
  for (const byte of bytes) hex += byte.toString(16).padStart(2, "0");
  return `${prefix}_${hex}`;
}
