jest.mock("expo-crypto", () => ({
  getRandomBytes: (count: number) => {
    const bytes = new Uint8Array(count);
    for (let index = 0; index < count; index += 1) bytes[index] = (index * 17 + 3) & 0xff;
    return bytes;
  },
}));

describe("makeId without global crypto", () => {
  const saved = Object.getOwnPropertyDescriptor(globalThis, "crypto");

  afterEach(() => {
    if (saved) Object.defineProperty(globalThis, "crypto", saved);
  });

  test("returns prefix plus 32 hex chars after crypto is deleted", () => {
    delete (globalThis as { crypto?: unknown }).crypto;
    expect((globalThis as { crypto?: unknown }).crypto).toBeUndefined();
    jest.resetModules();
    let ids: typeof import("./ids") | undefined;
    jest.isolateModules(() => {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      ids = require("./ids") as typeof import("./ids");
    });
    if (!ids) throw new Error("ids module did not load");
    expect(ids.makeId("h")).toMatch(/^h_[0-9a-f]{32}$/);
    expect(ids.makeId("n")).toMatch(/^n_[0-9a-f]{32}$/);
  });
});
