import type { Draft, Results } from "../types";
import { numberText } from "../utils";
import { RangeFlag } from "./RangeFlag";

const SD_BASIS: Record<string, (count: number) => string> = {
  rois: (count) => `SD across ${count} ROIs`,
  pixel: () => "SD from the ROI's pixel color spread",
  reservoirs: (count) => `SD across ${count} reservoirs`,
};

type Props = {
  results: Results;
  draft: Draft;
  disabled: boolean;
  onReview: (
    id: number,
    review: "included" | "excluded" | "needs_review",
    reason: string,
  ) => void;
};
export function ResultsView({ results, draft, disabled, onReview }: Props) {
  return (
    <div className="results-view">
      <div className="section-heading">
        <div>
          <span className="eyebrow">ANALYSIS OUTPUT</span>
          <h2>Results & review</h2>
        </div>
        <span className="tag">Research use</span>
      </div>
      {Object.keys(results.summaries).length > 0 && (
        <div className="summary-grid">
          {Object.entries(results.summaries).map(([name, item]) => {
            const unreviewed = results.reservoirs.filter(
              (r) => r.analyte === name && r.value != null,
            );
            const mean = unreviewed.length
              ? unreviewed.reduce((sum, r) => sum + (r.value as number), 0) / unreviewed.length
              : null;
            return (
            <article className="summary-card" key={name}>
              <span>
                {name === "ph" ? "pH" : name === "urea" ? "Urea" : "Creatinine"}
              </span>
              {item.value == null && mean != null ? (
                <>
                  <strong className="not-final">
                    {numberText(mean)} <small>{item.unit}</small>
                  </strong>
                  <p>
                    <span className="tag">Not final</span>{" "}
                    {unreviewed.length > 1
                      ? `Mean of ${unreviewed.length} reservoirs that are not included, range ${numberText(Math.min(...unreviewed.map((r) => r.value as number)))} to ${numberText(Math.max(...unreviewed.map((r) => r.value as number)))}`
                      : `Reservoir ${unreviewed[0].id}, not included`}
                    {" "}({[...new Set(unreviewed.map((r) => r.review_status.replaceAll("_", " ")))].join(", ")}).
                    Not used for urea or the prediction until included.
                  </p>
                </>
              ) : (
              <>
              <strong>
                {item.value == null ? "N/A" : numberText(item.value)}
                {item.value != null && item.sd != null && ` ± ${numberText(item.sd)}`}{" "}
                <small>{item.unit}</small>
              </strong>
              {item.value != null && item.sd != null && item.sd_basis && (
                <small className="sd-basis">
                  {SD_BASIS[item.sd_basis](item.included_ids.length)}
                </small>
              )}
              <p>
                {item.value == null
                  ? "No final included result"
                  : (item.values?.length || 0) > 1
                    ? `Mean of ${item.values!.length} reservoirs, range ${numberText(item.min)} to ${numberText(item.max)}`
                    : `From reservoir ${item.included_ids[0]}`}
              </p>
              {(item.values?.length || 0) > 1 && (
                <ul className="summary-values">
                  {item.values!.map((v) => (
                    <li key={v.reservoir_id}>
                      Reservoir {v.reservoir_id}
                      {v.condition && ` · ${v.condition}`}
                      {v.replicate && ` · rep ${v.replicate}`}:{" "}
                      {numberText(v.value)}
                    </li>
                  ))}
                </ul>
              )}
              </>
              )}
            </article>
            );
          })}
        </div>
      )}
      {!results.ph_ready_for_urea && Object.keys(results.summaries).length > 0 && (
        <p className="notice">
          Final urea requires at least one included pH reservoir and all
          eligible pH reviews to be resolved.
        </p>
      )}
      {results.reservoirs.length > 0 && (
        <div className="reservoir-results">
          {results.reservoirs.map((r) => (
            <article className="review-card" key={r.id}>
              <div className="review-heading">
                <h3>
                  Reservoir {r.id}
                  {r.condition && <span className="tag">{r.condition}</span>}
                  {r.replicate && <span className="tag">Replicate {r.replicate}</span>}
                  {r.analyte !== "custom" && (
                    <span className="tag">
                      {(["included", "automatically_included"].includes(r.review_status) &&
                        r.calculation_status === "valid") ||
                      (r.review_status === "included" && r.calculation_status === "invalid_domain" && r.value != null)
                        ? "In average"
                        : "Not in average"}
                    </span>
                  )}
                </h3>
                <strong className="analyte-name">
                  {r.analyte === "ph"
                    ? "pH"
                    : r.analyte === "custom"
                      ? r.custom_name || "Custom"
                      : (r.analyte ?? "").charAt(0).toUpperCase() + (r.analyte ?? "").slice(1)}
                </strong>
                <span className={`status ${r.review_status}`}>
                  {r.review_status.replaceAll("_", " ")}
                </span>
              </div>
              {r.analyte === "custom" ? (
                <p className="result-lab">
                  Average L*a*b*{" "}
                  {r.average_lab?.map((n) => numberText(n)).join(", ")}
                  {r.uncertainty?.lab_sd &&
                    ` ± ${r.uncertainty.lab_sd.map((n) => numberText(n)).join(", ")} SD across ${r.uncertainty.n_rois} ROIs`}
                  <br />
                  <small>No calibration equation; color values are exported.</small>
                </p>
              ) : (
                <strong className="result-value">
                  {numberText(r.value)}
                  {r.value != null &&
                    r.uncertainty?.sd != null &&
                    ` ± ${numberText(r.uncertainty.sd)}`}{" "}
                  <small>{r.unit}</small>
                </strong>
              )}
              {r.urea_ph_model && (
                <p>
                  Model: {r.urea_ph_model.replaceAll("_", " ")}
                  {results.urea_calibration === "ab" && " · a*b* only"}
                </p>
              )}
              {r.uncertainty && r.analyte !== "custom" && (
                <div className="uncertainty">
                  <p>
                    <span className="tag">Testing</span>{" "}
                    {r.uncertainty.sd_basis
                      ? SD_BASIS[r.uncertainty.sd_basis](r.uncertainty.n_rois)
                      : r.uncertainty.n_rois > 1
                        ? `${r.uncertainty.n_rois} ROIs; an SD needs at least two valid ROI values`
                        : "1 ROI; no pixel spread available"}
                    {r.uncertainty.roi_sd != null &&
                      `, range ${numberText(r.uncertainty.roi_min)} to ${numberText(r.uncertainty.roi_max)}`}
                  </p>
                  <details>
                    <summary>Per-ROI values</summary>
                    <table>
                      <thead>
                        <tr>
                          <th>ROI</th>
                          <th>Value</th>
                          <th>Pixel color ± 1 SD</th>
                        </tr>
                      </thead>
                      <tbody>
                        {r.uncertainty.rois.map((roi) => (
                          <tr key={roi.roi_id}>
                            <td>
                              {results.rois.find((x) => x.id === roi.roi_id)
                                ?.label || `ROI ${roi.roi_id}`}
                            </td>
                            <td>{numberText(roi.value)}</td>
                            <td>
                              {roi.pixel_low == null
                                ? "N/A"
                                : `${numberText(roi.pixel_low)} to ${numberText(roi.pixel_high)}`}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </details>
                </div>
              )}
              {r.warnings.map((w) => (
                <p className="warning-text" key={w}>
                  {w}
                </p>
              ))}
              {r.review_status !== "not_applicable" && (
              <div className="review-actions">
                <label>
                  Review
                  <select
                    aria-label={`Review reservoir ${r.id}`}
                    disabled={
                      disabled ||
                      r.calculation_status === "missing_input" ||
                      r.calculation_status === "provisional_input"
                    }
                    value={
                      draft.reservoirs.find((x) => x.id === r.id)?.review ||
                      "needs_review"
                    }
                    onChange={(e) =>
                      onReview(
                        r.id,
                        e.target.value as
                          "included" | "excluded" | "needs_review",
                        r.reason,
                      )
                    }
                  >
                    <option value="needs_review">
                      Automatic / needs review
                    </option>
                    <option value="included">
                      {r.calculation_status === "invalid_domain" ? "Include anyway" : "Include"}
                    </option>
                    <option value="excluded">Exclude</option>
                  </select>
                </label>
                <label>
                  Review note
                  <input
                    aria-label={`Review note reservoir ${r.id}`}
                    disabled={disabled}
                    defaultValue={r.reason}
                    maxLength={500}
                    onBlur={(e) => {
                      if (e.target.value !== r.reason)
                        onReview(r.id, r.review, e.target.value);
                    }}
                    placeholder="Optional reason"
                  />
                </label>
              </div>
              )}
            </article>
          ))}
        </div>
      )}
      {(draft.mode !== "standard_24_grid" || results.reservoirs.length > 0) && (
        <article className="prediction">
          <div>
            <span className="eyebrow">OPTIONAL RESEARCH MODEL</span>
            <h3>
              {results.prediction.classification || "Prediction not calculated"}
            </h3>
            {results.prediction.model_label && (
              <p>
                Model: {results.prediction.model_label} (
                {results.prediction.model_source === "manual"
                  ? "chosen manually"
                  : "chosen automatically"}
                )
              </p>
            )}
            <p>
              {results.prediction.status === "complete"
                ? `Probability ${(100 * (results.prediction.probability || 0)).toFixed(1)}% · Threshold ${(100 * (results.prediction.threshold || 0)).toFixed(1)}%${results.prediction.auc ? ` · AUC ${results.prediction.auc}` : ""}`
                : results.prediction.reason}
            </p>
          </div>
          <p className="muted">
            For research use only; not validated for assay accuracy or clinical use.
          </p>
        </article>
      )}
      <h3>ROI measurements</h3>
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>ROI</th>
              <th>Pixels</th>
              <th>Raw L*, a*, b*</th>
              <th>Calibrated L*, a*, b*</th>
            </tr>
          </thead>
          <tbody>
            {results.rois.map((r) => (
              <tr key={r.id}>
                <td>
                  {r.label} <RangeFlag results={results} roiId={r.id} />
                </td>
                <td>{r.pixel_count.toLocaleString()}</td>
                <td>{r.median.map((n) => numberText(n)).join(", ")}</td>
                <td>
                  {r.calibrated_median.map((n) => numberText(n)).join(", ")}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
