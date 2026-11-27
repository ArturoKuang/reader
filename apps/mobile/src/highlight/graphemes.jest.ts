import { graphemeClusters, takeFirstGraphemes, takeLastGraphemes } from "./graphemes";

describe("hand-written grapheme clusters", () => {
  test("keeps a combining mark on its base", () => {
    const text = "ae\u0301";
    expect(graphemeClusters(text)).toEqual(["a", "e\u0301"]);
    expect(takeLastGraphemes(text, 1)).toBe("e\u0301");
    expect(takeFirstGraphemes(text, 1)).toBe("a");
  });

  test("keeps a variation selector, a ZWJ sequence, and a flag pair together", () => {
    expect(graphemeClusters("\u263a\uFE0F")).toEqual(["\u263a\uFE0F"]);
    const family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}";
    expect(graphemeClusters(family)).toEqual([family]);
    const flag = "\u{1F1FA}\u{1F1F8}";
    expect(graphemeClusters(`x${flag}`)).toEqual(["x", flag]);
  });
});
