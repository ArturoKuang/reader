import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { codePointsOf, normalizeWord, wordId } from "./wordId";

const fixture = JSON.parse(
  readFileSync(join(dirname(__filename), "fixtures", "word-id-normalize.json"), "utf8"),
) as { cases: FixtureCase[] };

type FixtureCase = {
  name: string;
  inputCodepoints: string[];
  expectedCodepoints: string[];
  hasWordId: boolean;
};

function fromLabels(labels: string[]): number[] {
  return labels.map((label) => Number.parseInt(label.slice(2), 16));
}

function textFrom(labels: string[]): string {
  const points = fromLabels(labels);
  return points.length === 0 ? "" : String.fromCodePoint(...points);
}

const cases = fixture.cases;

describe("Swift word-id fixture", () => {
  test("ships the 30 upstream cases", () => {
    expect(cases).toHaveLength(30);
  });

  test.each(cases)("$name", (item) => {
    const input = textFrom(item.inputCodepoints);
    const output = normalizeWord(input);
    expect(codePointsOf(output)).toEqual(fromLabels(item.expectedCodepoints));
    const id = wordId(input);
    if (item.hasWordId) {
      expect(id).not.toBeNull();
      expect(codePointsOf((id ?? "").slice(2))).toEqual(codePointsOf(output));
      expect(id?.startsWith("w_")).toBe(true);
    } else {
      expect(id).toBeNull();
    }
  });
});
