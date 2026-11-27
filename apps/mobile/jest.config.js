/** @type {import("jest").Config} */
module.exports = {
  projects: [
    {
      displayName: "node",
      testEnvironment: "node",
      testMatch: ["**/*.jest.ts"],
      transform: {
        "^.+\\.tsx?$": ["babel-jest", { presets: ["babel-preset-expo"] }],
      },
    },
    {
      displayName: "native",
      preset: "jest-expo",
      testMatch: ["**/*.jest.tsx"],
    },
  ],
};
