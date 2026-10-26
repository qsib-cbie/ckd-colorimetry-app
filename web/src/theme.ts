import { getCurrentWindow } from "@tauri-apps/api/window";
import { isDesktop } from "./native";
import { readPreference, writePreference } from "./utils";

export type ThemePreference = "system" | "light" | "dark";
export const THEMES: ThemePreference[] = ["system", "light", "dark"];

let preference: ThemePreference = "system";

const darkQuery = () => window.matchMedia?.("(prefers-color-scheme: dark)");

export function savedTheme(): ThemePreference {
  const value = readPreference<string>("theme", "system");
  return THEMES.includes(value as ThemePreference) ? (value as ThemePreference) : "system";
}

export function resolveTheme(value: ThemePreference, systemDark: boolean) {
  return value === "system" ? (systemDark ? "dark" : "light") : value;
}

function paint() {
  document.documentElement.dataset.theme = resolveTheme(preference, !!darkQuery()?.matches);
}

function syncWindow() {
  if (isDesktop()) void getCurrentWindow().setTheme(preference === "system" ? null : preference).catch(() => undefined);
}

export function initTheme() {
  preference = savedTheme();
  paint();
  syncWindow();
  darkQuery()?.addEventListener("change", () => {
    if (preference === "system") paint();
  });
}

export function setTheme(value: ThemePreference) {
  preference = value;
  writePreference("theme", value);
  paint();
  syncWindow();
}
