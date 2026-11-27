import * as ExpoCrypto from "expo-crypto";

/**
 * Hermes may omit `crypto.randomUUID` and `crypto.getRandomValues`.
 * The sync engine uses both when minting change ids.
 */
export function installCryptoPolyfill(): void {
  const randomUUID = (): string => ExpoCrypto.randomUUID();
  const getRandomValues = <T extends ArrayBufferView>(array: T): T => {
    const bytes = ExpoCrypto.getRandomBytes(array.byteLength);
    new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
    return array;
  };
  const existing = globalThis.crypto;
  if (!existing) {
    Object.defineProperty(globalThis, "crypto", {
      configurable: true,
      value: { randomUUID, getRandomValues },
    });
    return;
  }
  if (typeof existing.randomUUID !== "function") {
    Object.assign(existing, { randomUUID });
  }
  if (typeof existing.getRandomValues !== "function") {
    Object.assign(existing, { getRandomValues });
  }
}
