import { createHash } from "node:crypto";
import { afterEach, describe, expect, it, jest } from "@jest/globals";
import { sha256Hex } from "./blobs";

const ABC = new TextEncoder().encode("abc");
const ABC_HEX = createHash("sha256").update(ABC).digest("hex");

function digestBuffer(data: ArrayBuffer | Uint8Array): ArrayBuffer {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  const hash = createHash("sha256").update(bytes).digest();
  return hash.buffer.slice(hash.byteOffset, hash.byteOffset + hash.byteLength);
}

describe("sha256Hex", () => {
  it("returns lowercase 64-char hex via crypto.subtle", async () => {
    expect(typeof globalThis.crypto?.subtle?.digest).toBe("function");
    const hex = await sha256Hex(ABC);
    expect(hex).toBe(ABC_HEX);
    expect(hex).toMatch(/^[0-9a-f]{64}$/);
  });

  it("hashes a Uint8Array view with a non-zero byteOffset", async () => {
    const parent = new Uint8Array([0xff, 0x00, ...ABC, 0xaa]);
    const view = parent.subarray(2, 5);
    expect(view.byteOffset).toBe(2);
    expect(view.byteLength).toBe(3);
    expect(await sha256Hex(view)).toBe(ABC_HEX);
  });
});

describe("sha256Hex without crypto.subtle (Hermes)", () => {
  const savedCrypto = Object.getOwnPropertyDescriptor(globalThis, "crypto");

  afterEach(() => {
    if (savedCrypto) Object.defineProperty(globalThis, "crypto", savedCrypto);
    else delete (globalThis as { crypto?: unknown }).crypto;
    jest.dontMock("expo-crypto");
    jest.resetModules();
  });

  it("falls back to expo-crypto digest when subtle is undefined", async () => {
    jest.resetModules();
    jest.doMock("expo-crypto", () => ({
      CryptoDigestAlgorithm: { SHA256: "SHA-256" },
      digest: async (_algorithm: string, data: Uint8Array) => digestBuffer(data),
    }));
    Object.defineProperty(globalThis, "crypto", {
      configurable: true,
      value: { randomUUID: () => "00000000-0000-4000-8000-000000000000" },
    });
    expect(globalThis.crypto.subtle).toBeUndefined();

    let loaded: typeof import("./blobs") | undefined;
    jest.isolateModules(() => {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      loaded = require("./blobs") as typeof import("./blobs");
    });
    if (!loaded) throw new Error("blobs module did not load");

    expect(await loaded.sha256Hex(ABC)).toBe(ABC_HEX);
    const parent = new Uint8Array([0x01, ...ABC, 0x02]);
    expect(await loaded.sha256Hex(parent.subarray(1, 4))).toBe(ABC_HEX);
  });
});
