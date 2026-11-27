/**
 * Hermes has no Intl.Segmenter. Loading the highlight modules must not
 * construct one. Babel-jest compiles `import` to `require`, so the load
 * under test is `require` after `delete Intl.Segmenter`.
 */
describe("highlight modules without Intl.Segmenter", () => {
  const saved = Object.getOwnPropertyDescriptor(Intl, "Segmenter");

  afterEach(() => {
    if (saved) Object.defineProperty(Intl, "Segmenter", saved);
  });

  test("locate and captureAnchor load and run after Segmenter is deleted", () => {
    delete (Intl as unknown as { Segmenter?: unknown }).Segmenter;
    expect((Intl as unknown as { Segmenter?: unknown }).Segmenter).toBeUndefined();
    jest.resetModules();
    let locate: typeof import("./locate") | undefined;
    let selection: typeof import("./selection") | undefined;
    jest.isolateModules(() => {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      locate = require("./locate") as typeof import("./locate");
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      selection = require("./selection") as typeof import("./selection");
    });
    if (!locate || !selection) throw new Error("highlight modules did not load");
    const hit = locate.locate("Ishmael", "Call me ", ".", [{ page: 1, text: "Call me Ishmael." }]);
    expect(hit?.prefix).toBe("Call me ");
    expect(hit?.page).toBe(1);
    const anchor = selection.captureAnchor("Call me Ishmael.", 8, 15, 1, "Page 1");
    expect(anchor.quote).toBe("Ishmael");
    expect(anchor.prefix).toBe("Call me ");
    const cafe = "e\u0301";
    expect(selection.captureAnchor(`a${cafe}`, 1, 1 + cafe.length).quote).toBe(cafe);
  });
});
