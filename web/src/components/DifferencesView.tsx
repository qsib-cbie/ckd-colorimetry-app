import { ArrowLeft, RefreshCw } from "lucide-react";
import type { Comparison } from "../types";
import { numberText } from "../utils";

type Props = {
  comparison: Comparison;
  disabled: boolean;
  onBack: () => void;
  onRecompute: () => void;
};

const unitText = (unit: string) =>
  unit === "probability" ? "" : unit === "uM" ? "µM" : unit;
const valueText = (value: number | null, unit: string) =>
  value == null
    ? "Not available"
    : `${numberText(value, unit === "probability" ? 4 : 3)} ${unitText(unit)}`;

export const calculatedText = (comparison: Comparison) =>
  `Calculated ${comparison.calculated_on === "ios" ? "on iPad or iPhone " : ""}with CKD ${comparison.calculated_with}`;

export function DifferencesView({ comparison, disabled, onBack, onRecompute }: Props) {
  return (
    <section className="differences-view results-view" aria-label="Differences">
      <div className="section-heading">
        <div>
          <span className="eyebrow">RESULT VERSIONS</span>
          <h2>Differences</h2>
        </div>
        <div className="heading-actions">
          <button onClick={onBack}>
            <ArrowLeft size={15} />
            Back to results
          </button>
          <button className="primary" disabled={disabled} onClick={onRecompute}>
            <RefreshCw size={15} />
            Recompute
          </button>
        </div>
      </div>
      <p className="notice">
        {calculatedText(comparison).replace("Calculated", "These results were calculated")}. This
        app is CKD {comparison.current_app}.{" "}
        {comparison.needs_remeasure
          ? "The image processing changed, so Recompute renders the original RAW again, re-applies white balance and calibration, and measures every ROI. New values appear after recomputing."
          : comparison.affects_values
            ? "The equations changed. The current values below are calculated from the stored color measurements."
            : "Nothing that affects the numbers changed. Recompute records this app version."}
      </p>
      <h3>Versions</h3>
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Component</th>
              <th>Saved results</th>
              <th>This app</th>
            </tr>
          </thead>
          <tbody>
            {comparison.versions.map((row) => (
              <tr key={row.key} className={row.differs ? "changed" : undefined}>
                <td>{row.label}</td>
                <td>{row.applies ? (row.saved ?? "Not recorded") : "Not used on iPad or iPhone"}</td>
                <td>{row.current}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <h3>Values</h3>
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Result</th>
              <th>Saved</th>
              <th>Current</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {comparison.values.map((row) => (
              <tr key={row.label} className={row.changed ? "changed" : undefined}>
                <td>{row.label}</td>
                <td>{valueText(row.saved, row.unit)}</td>
                <td>
                  {comparison.needs_remeasure
                    ? "After recompute"
                    : valueText(row.current, row.unit)}
                </td>
                <td>
                  {row.changed == null
                    ? "Unknown until recomputed"
                    : row.changed
                      ? `Changed${row.current_status && row.current_status !== row.saved_status ? ` (${row.saved_status} to ${row.current_status})` : ""}`
                      : "Unchanged"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted">
        Recompute keeps the saved numbers in the analysis run history. Reservoirs
        whose value or status changes go back to “needs review”; other review
        decisions are kept.
      </p>
    </section>
  );
}
