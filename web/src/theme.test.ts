import { describe, expect, it } from "vitest";
import { THEMES, resolveTheme, savedTheme } from "./theme";

describe("appearance", () => {
  it("follows the system only when asked to", () => {
    expect(resolveTheme("system", true)).toBe("dark");
    expect(resolveTheme("system", false)).toBe("light");
    expect(resolveTheme("light", true)).toBe("light");
    expect(resolveTheme("dark", false)).toBe("dark");
  });

  it("offers system, light and dark and defaults to system", () => {
    expect(THEMES).toEqual(["system", "light", "dark"]);
    expect(savedTheme()).toBe("system");
  });
});
