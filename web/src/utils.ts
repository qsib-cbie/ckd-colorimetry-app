import type { Point } from "./types";

export async function request<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const headers = new Headers(options.headers);
  const response = await fetch(`/api${path}`, {
    ...options,
    headers,
    credentials: "same-origin",
    cache: "no-store",
  });
  if (!response.ok) {
    const body = await response
      .json()
      .catch(() => ({ detail: `Local engine returned ${response.status}.` }));
    const message = Array.isArray(body.detail)
      ? body.detail
          .map((d: { msg: string; loc?: (string | number)[] }) => {
            const text = d.msg.replace(/^Value error, /, "");
            const field = d.loc?.at(-1);
            return typeof field === "string" && !["body", "draft"].includes(field)
              ? `${field.replaceAll("_", " ")}: ${text}`
              : text;
          })
          .join(" ")
      : body.detail;
    throw Object.assign(
      new Error(message || "The request failed. Please retry."),
      { status: response.status },
    );
  }
  return response.json();
}
export const jsonRequest = (method: string, body: unknown): RequestInit => ({
  method,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});
export const numberText = (n: number | null | undefined, digits = 2) =>
  n == null ? "Not available" : n.toFixed(digits);
export function exportFilename(title: string, at = new Date()) {
  const safe =
    title.replace(/[^A-Za-z0-9._ -]+/g, "-").replace(/^[ .-]+|[ .-]+$/g, "") ||
    "ckd-analysis";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${safe}_${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}_${pad(at.getHours())}${pad(at.getMinutes())}${pad(at.getSeconds())}.zip`;
}
export function imagePoint(
  screen: Point,
  offset: Point,
  scale: number,
  width: number,
  height: number,
): Point {
  return {
    x: Math.max(0, Math.min(width - 1, (screen.x - offset.x) / scale)),
    y: Math.max(0, Math.min(height - 1, (screen.y - offset.y) / scale)),
  };
}
export function cyclicPoints(points: Point[]): Point[] {
  const center = points.reduce(
    (a, p) => ({ x: a.x + p.x / points.length, y: a.y + p.y / points.length }),
    { x: 0, y: 0 },
  );
  return [...points].sort(
    (a, b) =>
      Math.atan2(a.y - center.y, a.x - center.x) -
      Math.atan2(b.y - center.y, b.x - center.x),
  );
}

function cross(a: Point, b: Point, c: Point) {
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}
function between(value: number, a: number, b: number) {
  return value >= Math.min(a, b) - 1e-9 && value <= Math.max(a, b) + 1e-9;
}
function segmentsTouch(a: Point, b: Point, c: Point, d: Point) {
  const values = [cross(a, b, c), cross(a, b, d), cross(c, d, a), cross(c, d, b)];
  if (values[0] * values[1] < 0 && values[2] * values[3] < 0) return true;
  return (
    [
      [values[0], a, b, c],
      [values[1], a, b, d],
      [values[2], c, d, a],
      [values[3], c, d, b],
    ] as [number, Point, Point, Point][]
  ).some(
    ([value, p, q, r]) =>
      Math.abs(value) < 1e-9 && between(r.x, p.x, q.x) && between(r.y, p.y, q.y),
  );
}
export function polygonProblem(points: Point[], corners = false): string | null {
  if (corners) {
    const ordered = cyclicPoints(points);
    const signs = ordered.map((p, i) =>
      cross(p, ordered[(i + 1) % 4], ordered[(i + 2) % 4]),
    );
    return points.length === 4 && signs.every((value) => value > 0)
      ? null
      : "The four corners must form a convex shape. Undo the last corner and place it again.";
  }
  if (new Set(points.map((p) => `${p.x}:${p.y}`)).size !== points.length)
    return "Two vertices are in the same place. Undo the last vertex and continue.";
  const area =
    Math.abs(
      points.reduce(
        (sum, p, i) =>
          sum + p.x * points[(i + 1) % points.length].y - points[(i + 1) % points.length].x * p.y,
        0,
      ),
    ) / 2;
  if (area < 0.5) return "This shape is too small to measure.";
  const n = points.length;
  for (let i = 0; i < n; i++)
    for (let j = i + 1; j < n; j++) {
      if (j === i + 1 || (i === 0 && j === n - 1)) continue;
      if (segmentsTouch(points[i], points[(i + 1) % n], points[j], points[(j + 1) % n]))
        return "This shape crosses itself. Undo the last vertex (Cmd+Z) and continue.";
    }
  return null;
}
export function readPreference<T>(key: string, fallback: T): T {
  try {
    const value = window.localStorage.getItem(`ckd.${key}`);
    return value === null ? fallback : (JSON.parse(value) as T);
  } catch {
    return fallback;
  }
}
export function writePreference(key: string, value: unknown) {
  try {
    window.localStorage.setItem(`ckd.${key}`, JSON.stringify(value));
  } catch {
    return;
  }
}
export function homeRelative(path: string, home: string) {
  if (!home) return path;
  if (path === home) return "~";
  return path.startsWith(`${home}/`) ? `~${path.slice(home.length)}` : path;
}
export function nextRoiId(rois: { id: number }[]) {
  const used = new Set(rois.map((roi) => roi.id));
  let id = 1;
  while (used.has(id)) id += 1;
  return id;
}
export const MAX_RESERVOIRS = 1000;
export const MAX_ROIS = 5000;
export function rectanglePoints(a: Point, b: Point): Point[] {
  const left = Math.min(a.x, b.x);
  const right = Math.max(a.x, b.x);
  const top = Math.min(a.y, b.y);
  const bottom = Math.max(a.y, b.y);
  return [
    { x: left, y: top },
    { x: right, y: top },
    { x: right, y: bottom },
    { x: left, y: bottom },
  ];
}

function orderedCorners(points: Point[]): Point[] | null {
  if (points.length !== 4) return null;
  const cyclic = cyclicPoints(points);
  const convex = cyclic.every((p, i) => cross(p, cyclic[(i + 1) % 4], cyclic[(i + 2) % 4]) > 0);
  return convex ? [cyclic[0], cyclic[1], cyclic[3], cyclic[2]] : null;
}

function mapPatch([tl, tr, bl, br]: Point[], uv: [number, number][]): Point[] {
  return uv.map(([u, v]) => ({
    x: (1 - u) * (1 - v) * tl.x + u * (1 - v) * tr.x + (1 - u) * v * bl.x + u * v * br.x,
    y: (1 - u) * (1 - v) * tl.y + u * (1 - v) * tr.y + (1 - u) * v * bl.y + u * v * br.y,
  }));
}

export function markerPatches(mode: string, points: Point[]): Point[][] {
  const c = orderedCorners(points);
  if (!c) return [];
  const length = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.y - b.y);
  if (mode === "flower_9") {
    const centers = [[0.3, 0.3], [0.5, 0.18], [0.7, 0.3], [0.18, 0.5], [0.5, 0.5],
      [0.82, 0.5], [0.3, 0.7], [0.5, 0.82], [0.7, 0.7]];
    return centers.map(([u, v], i) => {
      const s = i === 4 ? 0.075 : 0.065;
      let offset = [[-s, -s], [s, -s], [s, s], [-s, s]];
      if ([0, 2, 6, 8].includes(i)) {
        const t = Math.PI / 4;
        offset = offset.map(([a, b]) => [a * Math.cos(t) - b * Math.sin(t), a * Math.sin(t) + b * Math.cos(t)]);
      }
      return mapPatch(c, offset.map(([a, b]) => [a + u, b + v]));
    });
  }
  const landscape = length(c[1], c[0]) + length(c[3], c[2]) >= length(c[2], c[0]) + length(c[3], c[1]);
  const patches: Point[][] = [];
  for (let x = 0; x < 6; x++)
    for (let y = 0; y < 4; y++) {
      const u = 0.05 + x / 6;
      const v = 0.075 + y / 4;
      let uv: [number, number][] = [[u, v], [u + 1 / 15, v], [u + 1 / 15, v + 0.1], [u, v + 0.1]];
      if (!landscape) uv = uv.map(([a, b]) => [b, a]);
      patches.push(mapPatch(c, uv));
    }
  return patches;
}
