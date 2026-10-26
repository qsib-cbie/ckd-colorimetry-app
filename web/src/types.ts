export type Point = { x: number; y: number };
export type Mode = "flower_9" | "flower_9_manual" | "standard_24_grid";
export type Analyte = "ph" | "urea" | "creatinine" | "custom";
export type UreaModel = "pH_6.0" | "pH_6.5" | "pH_7.0";
export type ClassifierModel = "full" | "creatinine" | "urea";
export type ROI = { id: number; label: string; points: Point[] };
export type Reservoir = {
  id: number;
  analyte: Analyte | null;
  custom_name?: string;
  condition?: string;
  replicate?: string;
  roi_ids: number[];
  review: "needs_review" | "included" | "excluded";
  reason: string;
};
export type Draft = {
  title: string;
  mode: Mode;
  white_balance: Point[];
  corners: Point[];
  manual_patches: Point[][];
  rois: ROI[];
  reservoirs: Reservoir[];
  age: number | null;
  sex: "male" | "female" | null;
  urea_ph_model?: UreaModel | null;
  urea_calibration?: "lab" | "ab";
  classifier_model?: ClassifierModel | null;
};
export type Raster = {
  array: string;
  preview: string;
  width: number;
  height: number;
};
export type Calibration = {
  rmse: number;
  confidence: number | null;
  orientation: string;
  patches: Point[][];
  coefficients: number[][];
  delta_e: number[];
};
export type ROIResult = {
  id: number;
  label: string;
  pixel_count: number;
  median: number[];
  mean: number[];
  standard_deviation: number[];
  calibrated_median: number[];
};
export type ReservoirResult = Reservoir & {
  value: number | null;
  unit: string;
  calculation_status: string;
  review_status: string;
  warnings: string[];
  urea_ph_model: string | null;
  average_lab?: number[];
  uncertainty?: {
    n_rois: number;
    roi_sd?: number | null;
    roi_min?: number | null;
    roi_max?: number | null;
    lab_sd?: number[] | null;
    sd?: number | null;
    sd_basis?: "rois" | "pixel" | null;
    rois: {
      roi_id: number;
      value?: number | null;
      pixel_low?: number | null;
      pixel_high?: number | null;
      lab?: number[];
      pixel_sd?: number | number[] | null;
    }[];
  } | null;
};
export type Results = {
  rois: ROIResult[];
  reservoirs: ReservoirResult[];
  summaries: Record<
    Analyte,
    {
      value: number | null;
      unit: string;
      included_ids: number[];
      note: string;
      sd?: number | null;
      sd_basis?: "reservoirs" | "rois" | "pixel" | null;
      values?: {
        reservoir_id: number;
        value: number;
        condition: string;
        replicate: string;
      }[];
      min?: number | null;
      max?: number | null;
    }
  >;
  ph_ready_for_urea: boolean;
  outside_calibration?: { roi_id: number; channels: string[] }[];
  urea_calibration?: "lab" | "ab";
  urea_ph_model?: {
    source: string | null;
    selected: UreaModel | null;
    nearest: UreaModel | null;
  };
  prediction: {
    status: string;
    reason?: string;
    classification?: string;
    probability?: number;
    threshold?: number;
    model?: ClassifierModel;
    model_label?: string;
    model_source?: "automatic" | "manual";
    available_models?: ClassifierModel[];
    auc?: number | null;
  };
};
export type Analysis = {
  analysis_id: string;
  copied_from?: { analysis_id: string; title?: string; copied_at: string };
  project_path: string;
  read_only: boolean;
  id: string;
  revision: number;
  source: {
    filename: string;
    sha256: string;
    width?: number;
    height?: number;
    bytes: number;
  };
  draft: Draft;
  render: Raster | null;
  white_balance: Raster | null;
  calibration: Calibration | null;
  results: Results | null;
  export: { file: string; bytes: number } | null;
  job: {
    id: string;
    action: string;
    status: string;
    error: string | null;
    seconds?: number;
  } | null;
};
export type Summary = {
  project_path: string;
  id: string;
  title: string;
  filename: string;
  updated_at: string;
};

export type Comparison = {
  outdated: boolean;
  calculated_with: string;
  calculated_on: "mac" | "ios";
  current_app: string;
  affects_values: boolean;
  needs_remeasure: boolean;
  versions: {
    key: string;
    label: string;
    saved: string | null;
    current: string;
    applies: boolean;
    differs: boolean;
  }[];
  values: {
    label: string;
    unit: string;
    saved: number | null;
    current: number | null;
    saved_status: string | null;
    current_status: string | null;
    changed: boolean | null;
  }[];
};

export type EquationInfo = {
  versions: Record<string, string>;
  equations: Record<Analyte, string>;
  ranges: Record<Analyte, { minimum: number; maximum: number; unit: string }>;
  ph: { quadratic: number; linear: number; intercept: number };
  creatinine: { offset: number; slope: number; numerator: number; denominator: number };
  urea: { model: string; applies: string; coefficients: number[] }[];
  urea_calibrations: {
    key: string;
    label: string;
    version: string;
    models: { model: string; coefficients: number[] }[];
  }[];
  classifier: {
    intercept: number;
    urea: number;
    creatinine: number;
    age: number;
    male: number;
    threshold: number;
    version: string;
  };
  classifiers: {
    model: string;
    label: string;
    intercept: number;
    analyte: number;
    age: number;
    male: number;
    threshold: number;
    auc: number;
    version: string;
  }[];
  calibration: { flower_reference: string; standard_24_max_rmse: number };
};

export type Folder = { id: string; name: string; parent_id: string | null };
export type LibraryData = {
  root: string;
  folders: Folder[];
  analyses: (Pick<
    Analysis,
    | "id"
    | "analysis_id"
    | "project_path"
    | "draft"
    | "source"
    | "job"
    | "read_only"
  > & { duplicate_id: boolean })[];
  problems: { path: string; error: string }[];
};
export type Workspace = {
  root: string | null;
  recent: string[];
  missing: string[];
  home: string;
};
