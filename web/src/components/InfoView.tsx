import { useEffect, useState } from "react";
import { ArrowLeft } from "lucide-react";
import type { EquationInfo } from "../types";
import { request } from "../utils";

const VERSION_LABELS: Record<string, string> = {
  app: "CKD Colorimetry app",
  engine: "Scientific engine",
  configuration: "Equation configuration",
  flower_reference: "Flower 9 reference colors",
  libraw: "LibRaw",
  rawpy: "rawpy",
  numpy: "NumPy",
  scikit_image: "scikit-image",
  python: "Python",
};

const signed = (value: number, first = false) =>
  first
    ? value < 0
      ? `−${Math.abs(value)}`
      : `${value}`
    : value < 0
      ? ` − ${Math.abs(value)}`
      : ` + ${value}`;

function Term({ value, symbol, first }: { value: number; symbol?: string; first?: boolean }) {
  return (
    <>
      {signed(value, first)}
      {symbol && <>·{symbol}</>}
    </>
  );
}

export function InfoView({ onBack }: { onBack: () => void }) {
  const [info, setInfo] = useState<EquationInfo | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    request<EquationInfo>("/info").then(setInfo).catch((e) => setError(e.message));
  }, []);
  if (error) return <p className="alert" role="alert">{error}</p>;
  if (!info) return <p className="notice">Loading equations…</p>;
  const { ph, creatinine, classifier } = info;
  return (
    <section className="info-view results-view" aria-label="Equations and versions">
      <div className="section-heading">
        <div>
          <span className="eyebrow">CURRENT CONFIGURATION</span>
          <h2>Equations and versions</h2>
        </div>
        <button onClick={onBack}>
          <ArrowLeft size={15} />
          Back
        </button>
      </div>
      <p className="notice">
        Research configuration. Assay and classifier validation is pending.
      </p>

      <h3>pH</h3>
      <p className="equation">
        b* = <Term value={ph.quadratic} symbol="pH²" first />
        <Term value={ph.linear} symbol="pH" />
        <Term value={ph.intercept} />
      </p>
      <p className="muted">
        pH is the smaller root: pH = (−{ph.linear} − √({ph.linear}² − 4·({ph.quadratic})·({ph.intercept} − b*))) / (2·({ph.quadratic})).
        Version {info.equations.ph}.
      </p>

      <h3>Urea (mM)</h3>
      <p className="equation">urea = c₀ + c₁·L* + c₂·a* + c₃·b*, with the model chosen by the final pH</p>
      {info.urea_calibrations.map((calibration) => (
        <div className="table-scroll" key={calibration.key}>
          <table>
            <caption>
              {calibration.label} · {calibration.version}
            </caption>
            <thead>
              <tr>
                <th>Model</th>
                <th>Used when</th>
                <th>c₀</th>
                <th>c₁ (L*)</th>
                <th>c₂ (a*)</th>
                <th>c₃ (b*)</th>
              </tr>
            </thead>
            <tbody>
              {calibration.models.map((model) => (
                <tr key={model.model}>
                  <td>{model.model.replace("_", " ")}</td>
                  <td>
                    {info.urea.find((u) => u.model === model.model)?.applies}
                  </td>
                  {model.coefficients.map((value, i) => (
                    <td key={i}>{value}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ))}
      <p className="muted">
        Automatic: the model nearest the final pH, which needs at least one
        included pH reservoir and all eligible pH reviews resolved. A manually
        chosen urea pH model (6.0, 6.5 or 7.0) is used instead when set, with or
        without pH reservoirs. Version {info.equations.urea}.
      </p>

      <h3>Creatinine (µM)</h3>
      <p className="equation">
        creatinine = ({creatinine.numerator} − √({creatinine.offset} − {creatinine.slope}·a*)) / {creatinine.denominator}
      </p>
      <p className="muted">Version {info.equations.creatinine}.</p>

      <h3>CKD G3+ prediction</h3>
      <p className="equation">
        z = <Term value={classifier.intercept} first />
        <Term value={-classifier.urea} symbol="urea" />
        <Term value={-classifier.creatinine} symbol="creatinine" />
        <Term value={-classifier.age} symbol="age" />
        <Term value={classifier.male} symbol="male" />
      </p>
      <p className="muted">
        p = 1 / (1 + eᶻ). Predicted G3+ when p ≥ {classifier.threshold}; male is 1
        for male and 0 for female. Version {classifier.version}.
      </p>
      {info.classifiers.map((model) => (
        <div key={model.model}>
          <h4>{model.label}</h4>
          <p className="equation">
            logit = <Term value={model.intercept} first />
            <Term value={model.analyte} symbol={model.model} />
            <Term value={model.age} symbol="age" />
            <Term value={model.male} symbol="male" />
          </p>
          <p className="muted">
            p = 1 / (1 + e^(−logit)). Predicted G3+ when p ≥ {model.threshold};
            AUC {model.auc}. Version {model.version}.
          </p>
        </div>
      ))}
      <p className="muted">
        Automatic choice: the full model when final urea and creatinine are
        both available, otherwise the creatinine or urea model. The model can
        be chosen manually in the Results step.
      </p>

      <h3>Review ranges</h3>
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Analyte</th>
              <th>Minimum</th>
              <th>Maximum</th>
              <th>Unit</th>
            </tr>
          </thead>
          <tbody>
            {Object.entries(info.ranges).map(([name, range]) => (
              <tr key={name}>
                <td>{name === "ph" ? "pH" : name}</td>
                <td>{range.minimum}</td>
                <td>{range.maximum}</td>
                <td>{range.unit === "uM" ? "µM" : range.unit}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted">
        Valid results inside these ranges are included automatically. Results
        outside them need Include or Exclude. Invalid equation domains and
        negative concentrations stay out unless a reviewer chooses Include anyway.
      </p>

      <h3>Calibration</h3>
      <p className="muted">
        Measured patch colors are fitted to the reference L*a*b* values: L*
        independently, a* and b* jointly. Standard 24 calibrations with RMSE
        above {info.calibration.standard_24_max_rmse} are rejected; Flower 9 has
        no acceptance threshold. Flower reference {info.calibration.flower_reference}.
        An ROI whose calibrated color lies outside the range of the reference
        patch colors (beyond the calibration RMSE) is flagged and its reservoir
        needs review. The 24-patch calibration uses the same pH, urea and
        creatinine equations as Flower.
      </p>

      <h3>Uncertainty (testing)</h3>
      <p className="muted">
        Each reservoir shows the sample SD and range of the concentrations of
        its ROIs (two or more valid ROIs), and each ROI shows the concentration
        at its pixel color median minus and plus one SD. The reservoir value uses
        the mean of its ROI color medians.
      </p>

      <h3>Versions</h3>
      <div className="table-scroll">
        <table>
          <tbody>
            {Object.entries(info.versions).map(([key, value]) => (
              <tr key={key}>
                <td>{VERSION_LABELS[key] || key}</td>
                <td>{value}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
