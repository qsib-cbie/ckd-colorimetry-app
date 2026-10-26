import { useEffect, useState } from "react";
import { ArrowLeft, FolderOpen, FolderSearch, Monitor, Moon, Pentagon, Square, Sun, Upload } from "lucide-react";
import { THEMES, savedTheme, setTheme, type ThemePreference } from "../theme";
import type { EquationInfo } from "../types";
import { request } from "../utils";

const THEME_LABELS: Record<ThemePreference, [string, typeof Sun]> = {
  system: ["System", Monitor],
  light: ["Light", Sun],
  dark: ["Dark", Moon],
};

type Props = {
  root: string;
  rootLabel: string;
  disabled: boolean;
  debugDefault: boolean;
  onDebugDefault: (value: boolean) => void;
  shapeDefault: "rectangle" | "polygon";
  onShapeDefault: (value: "rectangle" | "polygon") => void;
  onSwitchWorkspace: () => void;
  onReveal: () => void;
  onImport: () => void;
  onBack: () => void;
};

export function SettingsView({
  root,
  rootLabel,
  disabled,
  debugDefault,
  onDebugDefault,
  shapeDefault,
  onShapeDefault,
  onSwitchWorkspace,
  onReveal,
  onImport,
  onBack,
}: Props) {
  const [versions, setVersions] = useState<Record<string, string>>({});
  const [theme, chooseTheme] = useState(savedTheme);
  useEffect(() => {
    request<EquationInfo>("/info")
      .then((info) => setVersions(info.versions))
      .catch(() => setVersions({}));
  }, []);
  return (
    <section className="settings-view results-view" aria-label="Settings">
      <div className="section-heading">
        <div>
          <span className="eyebrow">THIS MAC</span>
          <h2>Settings</h2>
        </div>
        <button onClick={onBack}>
          <ArrowLeft size={15} />
          Back
        </button>
      </div>

      <h3>Workspace</h3>
      <div className="settings-card">
        <div className="settings-workspace">
          <strong>{root.split("/").pop()}</strong>
          <em title={root}>{rootLabel}</em>
        </div>
        <div className="settings-actions">
          <button disabled={disabled} onClick={onSwitchWorkspace}>
            <FolderOpen size={15} />
            Switch workspace
          </button>
          <button onClick={onReveal}>
            <FolderSearch size={15} />
            Reveal workspace in Finder
          </button>
          <button disabled={disabled} onClick={onImport}>
            <Upload size={15} />
            Import export ZIP
          </button>
        </div>
      </div>

      <h3>Appearance</h3>
      <div className="settings-card">
        <div className="segmented" role="radiogroup" aria-label="Appearance">
          {THEMES.map((value) => {
            const [label, Icon] = THEME_LABELS[value];
            return (
              <button
                key={value}
                role="radio"
                aria-checked={theme === value}
                className={theme === value ? "selected" : undefined}
                onClick={() => {
                  setTheme(value);
                  chooseTheme(value);
                }}
              >
                <Icon size={15} />
                {label}
              </button>
            );
          })}
        </div>
        <p className="muted">System follows the macOS appearance setting.</p>
      </div>

      <h3>Drawing</h3>
      <div className="settings-card">
        <div className="segmented" role="radiogroup" aria-label="Default drawing shape">
          {(["rectangle", "polygon"] as const).map((value) => (
            <button
              key={value}
              role="radio"
              aria-checked={shapeDefault === value}
              className={shapeDefault === value ? "selected" : undefined}
              onClick={() => onShapeDefault(value)}
            >
              {value === "rectangle" ? <Square size={15} /> : <Pentagon size={15} />}
              {value === "rectangle" ? "Rectangle · 2 clicks" : "Polygon"}
            </button>
          ))}
        </div>
        <p className="muted">
          Default shape for white-balance areas, calibration patches and ROIs in
          every analysis. Marker corners always take four clicks. You can still
          switch for one analysis in its step.
        </p>
      </div>

      <h3>Exports</h3>
      <div className="settings-card">
        <label className="checkbox-row">
          <input
            type="checkbox"
            checked={debugDefault}
            onChange={(e) => onDebugDefault(e.target.checked)}
          />
          Include debug images in new exports by default
        </label>
        <p className="muted">
          Debug images are the rendered and white-balanced RGBA8888 rasters in
          the iOS debug format. They make exports much larger. You can still
          change this for each export.
        </p>
      </div>

      <h3>About</h3>
      <div className="settings-card">
        <dl className="settings-about">
          <dt>App</dt>
          <dd>CKD Colorimetry {versions.app || ""}</dd>
          <dt>Scientific engine</dt>
          <dd>{versions.engine || ""}</dd>
          <dt>Equations</dt>
          <dd>{versions.configuration || ""}</dd>
          <dt>Engine log</dt>
          <dd>
            <code>~/Library/Logs/edu.northwestern.qsib.ckd-colorimetry/engine.log</code>
          </dd>
        </dl>
      </div>
    </section>
  );
}
