import { describe, expect, it } from "vitest";
import {
  imagePoint,
  cyclicPoints,
  polygonProblem,
  exportFilename,
  homeRelative,
  nextRoiId,
  rectanglePoints,
  markerPatches,
} from "./utils";

describe("original-pixel coordinates", () => {
  it("inverts pan and zoom without integer truncation", () => {
    expect(
      imagePoint({ x: 180, y: 250 }, { x: 30, y: 50 }, 0.125, 4032, 3024),
    ).toEqual({ x: 1200, y: 1600 });
    expect(
      imagePoint({ x: 31.25, y: 51.25 }, { x: 30, y: 50 }, 0.5, 4032, 3024),
    ).toEqual({ x: 2.5, y: 2.5 });
  });
  it("keeps vertices inside the last actual pixel", () => {
    expect(
      imagePoint({ x: -10, y: 10000 }, { x: 0, y: 0 }, 1, 100, 100),
    ).toEqual({ x: 0, y: 99 });
  });
  it("renders imported TL TR BL BR corners without a crossed boundary", () => {
    expect(
      cyclicPoints([
        { x: 1, y: 1 },
        { x: 9, y: 1 },
        { x: 1, y: 9 },
        { x: 9, y: 9 },
      ]),
    ).toEqual([
      { x: 1, y: 1 },
      { x: 9, y: 1 },
      { x: 9, y: 9 },
      { x: 1, y: 9 },
    ]);
  });
});

describe("polygon checks match the engine", () => {
  const square = [
    { x: 0, y: 0 },
    { x: 10, y: 0 },
    { x: 10, y: 10 },
    { x: 0, y: 10 },
  ];
  it("accepts a simple polygon and convex corners", () => {
    expect(polygonProblem(square)).toBeNull();
    expect(polygonProblem([square[2], square[0], square[3], square[1]], true)).toBeNull();
  });
  it("rejects duplicate, tiny and crossing shapes", () => {
    expect(polygonProblem([...square, square[3]])).toMatch(/same place/);
    expect(polygonProblem([{ x: 0, y: 0 }, { x: 0.5, y: 0 }, { x: 0, y: 0.5 }])).toMatch(/too small/);
    expect(polygonProblem([square[0], square[2], square[1], { x: 0, y: 4 }])).toMatch(/crosses itself/);
    expect(polygonProblem([...square.slice(0, 3), { x: 9, y: 9 }], true)).toMatch(/convex/);
  });
});

describe("export names", () => {
  it("uses the analysis title and local time", () => {
    expect(exportFilename("Sample A/B", new Date(2026, 8, 30, 7, 5, 9))).toBe(
      "Sample A-B_2026-09-30_070509.zip",
    );
    expect(exportFilename("...")).toMatch(/^ckd-analysis_/);
  });
});

describe("recent folder paths", () => {
  it("shows paths inside the home folder from ~", () => {
    expect(homeRelative("/Users/sam/Documents/CKD", "/Users/sam")).toBe("~/Documents/CKD");
    expect(homeRelative("/Users/sam", "/Users/sam")).toBe("~");
    expect(homeRelative("/Users/samantha/CKD", "/Users/sam")).toBe("/Users/samantha/CKD");
    expect(homeRelative("/Volumes/Lab/CKD", "/Users/sam")).toBe("/Volumes/Lab/CKD");
  });
});

describe("ROI numbering", () => {
  it("reuses the lowest free number", () => {
    expect(nextRoiId([])).toBe(1);
    expect(nextRoiId([{ id: 2 }, { id: 3 }])).toBe(1);
    expect(nextRoiId([{ id: 1 }, { id: 2 }, { id: 4 }, { id: 5 }])).toBe(3);
    expect(nextRoiId([{ id: 1 }, { id: 2 }, { id: 3 }])).toBe(4);
  });
});

describe("two-click rectangles", () => {
  it("orders the four corners from any pair of opposite corners", () => {
    const expected = [
      { x: 10, y: 20 },
      { x: 50, y: 20 },
      { x: 50, y: 60 },
      { x: 10, y: 60 },
    ];
    expect(rectanglePoints({ x: 10, y: 20 }, { x: 50, y: 60 })).toEqual(expected);
    expect(rectanglePoints({ x: 50, y: 60 }, { x: 10, y: 20 })).toEqual(expected);
    expect(rectanglePoints({ x: 50, y: 20 }, { x: 10, y: 60 })).toEqual(expected);
  });
});

describe("markerPatches", () => {
  const close = (actual: { x: number; y: number }[], expected: number[][]) =>
    actual.forEach((p, i) => {
      expect(p.x).toBeCloseTo(expected[i][0], 9);
      expect(p.y).toBeCloseTo(expected[i][1], 9);
    });
  const landscape = [{ x: 100, y: 80 }, { x: 700, y: 120 }, { x: 680, y: 520 }, { x: 90, y: 470 }];
  it("matches the engine's Standard 24 layout", () => {
    const patches = markerPatches("standard_24_grid", landscape);
    expect(patches).toHaveLength(24);
    close(patches[0], [[129.2125, 111.2875], [169.1625, 114.00416666666668],
      [168.04583333333332, 153.12083333333334], [128.1625, 150.33749999999998]]);
    close(patches[23], [[614.4625000000001, 444.3708333333333], [653.9125000000001, 447.5875],
      [651.9625000000001, 487.53749999999997], [612.5791666666667, 484.25416666666666]]);
    const portrait = [{ x: 100, y: 80 }, { x: 400, y: 90 }, { x: 390, y: 600 }, { x: 95, y: 590 }];
    close(markerPatches("standard_24_grid", portrait)[5], [[196.06458333333336, 193.75],
      [195.62291666666667, 227.75], [225.48125000000002, 228.75], [225.95625, 194.75]]);
  });
  it("matches the engine's Flower 9 layout and skips bad corners", () => {
    close(markerPatches("flower_9", landscape)[0], [[277.2950104602053, 173.77391454917927],
      [330.97855728788795, 213.8527269068328], [274.90498953979477, 246.0260854508207],
      [221.22144271211204, 205.9472730931672]]);
    expect(markerPatches("standard_24_grid", landscape.slice(0, 3))).toEqual([]);
  });
});
