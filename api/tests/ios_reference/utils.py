"""Mac engine references frozen for the iOS Swift port: results-layer cases and full pipeline runs."""

import copy
import hashlib
import json
import platform
from pathlib import Path

import numpy as np

from ckd import __version__
from ckd.models import Draft
from ckd.utils import (
    CONFIG_VERSION,
    FLOWER_LAB,
    STANDARD_LAB,
    apply_calibration,
    concentration_results,
    export_tables,
)

HERE = Path(__file__).parent
ROOT = HERE.parents[2]
IDENTITY = {
    "analysis_id": "00000000-0000-4000-8000-000000000001",
    "analysis_title": "iOS reference, case",
    "source_filename": "reference.DNG",
}
COEFFICIENTS = [[1.02, 0.0, 0.0], [0.0, 0.98, 0.01], [0.0, -0.02, 1.01], [-1.5, 0.4, -0.3]]
PH_B = {6.3: 9.8878, 6.6: -5.6209, 7.4: -56.12, "invalid": 70.0}
CREATININE_A = {20: 13.5, 40: 27.284, 60: 38.8, "negative": -10.0, "invalid": 70.0}
UREA_LAB = {"trace": (60.0, 0.0, 52.2), "mid": (60.0, 10.0, -30.0), "low_l": (70.0, 5.0, -12.0), "bright": (95.0, 4.0, -8.0)}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def calibration(reference, rmse=2.5):
    return {"coefficients": COEFFICIENTS, "rmse": rmse, "reference_lab": np.asarray(reference).tolist()}


class Builder:
    def __init__(self, seed):
        self.rng = np.random.default_rng(seed)
        self.rois, self.reservoirs = [], []

    def roi(self, target, jitter=0.6):
        roi_id = len(self.rois) + 1
        wanted = np.asarray(target, dtype=float) + self.rng.normal(0, jitter, 3)
        c = np.asarray(COEFFICIENTS)
        median = ((wanted - c[3]) @ np.linalg.inv(c[:3])).round(6)
        mean = median + self.rng.normal(0, 0.05, 3)
        sd = np.abs(self.rng.normal(0.4, 0.1, 3))
        self.rois.append({
            "id": roi_id,
            "label": f"ROI {roi_id}",
            "median": median.tolist(),
            "mean": mean.tolist(),
            "standard_deviation": sd.tolist(),
            "pixel_count": int(self.rng.integers(400, 30000)),
            "calibrated_median": apply_calibration(median, COEFFICIENTS),
            "calibrated_mean": apply_calibration(mean, COEFFICIENTS),
        })
        return roi_id

    def reservoir(self, analyte, targets, **fields):
        roi_ids = [self.roi(t) for t in targets]
        self.reservoirs.append({"id": len(self.reservoirs) + 1, "analyte": analyte, "roi_ids": roi_ids, **fields})
        return self

    def unassigned(self, *targets):
        for t in targets:
            self.roi(t)
        return self

    def draft(self, mode="flower_9_manual", **fields):
        rois = [{"id": r["id"], "label": r["label"],
                 "points": [{"x": 10.0 * r["id"], "y": 5.0}, {"x": 10.0 * r["id"] + 8, "y": 5.0},
                            {"x": 10.0 * r["id"] + 8, "y": 12.0}]} for r in self.rois]
        return Draft(mode=mode, rois=rois, reservoirs=self.reservoirs, **fields).model_dump()


def ph(value):
    return (50.0, 2.0, PH_B[value])


def creatinine(value):
    return (55.0, CREATININE_A[value], 12.0)


def flower_six(seed=1, ph_second=6.3, reviews=None):
    reviews = reviews or {}
    b = Builder(seed)
    b.reservoir("ph", [ph(6.6)] * 4, review=reviews.get(1, "needs_review"), reason=reviews.get("reason1", ""))
    b.reservoir("ph", [ph(ph_second)] * 2, review=reviews.get(2, "needs_review"), reason=reviews.get("reason2", ""))
    b.reservoir("urea", [UREA_LAB["mid"]] * 3, review=reviews.get(3, "needs_review"))
    b.reservoir("urea", [UREA_LAB["low_l"]], review=reviews.get(4, "needs_review"), reason=reviews.get("reason4", ""))
    b.reservoir("creatinine", [creatinine(40)] * 2)
    b.reservoir("creatinine", [creatinine(60)] * 3)
    return b


def cases():
    out = []

    def add(name, builder, mode="flower_9_manual", reference=FLOWER_LAB, cal=True, **fields):
        out.append({
            "name": name,
            "draft": builder.draft(mode, **fields),
            "rois": copy.deepcopy(builder.rois),
            "calibration": calibration(reference) if cal else None,
        })

    add("flower_all_automatic", flower_six(), age=58.0, sex="female")
    add("ph_flagged_needs_review", flower_six(ph_second=7.4), age=58.0, sex="male")
    add("ph_flagged_included", flower_six(ph_second=7.4, reviews={2: "included", 4: "excluded",
                                                               "reason4": 'Bubble, "dry" spot\nsecond line'}),
        age=71.0, sex="male")
    add("all_ph_excluded", flower_six(reviews={1: "excluded", 2: "excluded", "reason1": "-contaminated",
                                                 "reason2": "@reader note"}), age=45.0, sex="female")
    b = Builder(5)
    b.reservoir("urea", [UREA_LAB["low_l"]] * 2).reservoir("urea", [UREA_LAB["mid"]])
    b.reservoir("creatinine", [creatinine(40)] * 2)
    add("manual_urea_model_without_ph", b, urea_ph_model="pH_6.0", age=66.0, sex="male")
    add("ab_urea_calibration", flower_six(seed=6), urea_calibration="ab", age=58.0, sex="female")
    b = Builder(7)
    b.reservoir("ph", [ph(6.6)] * 2).reservoir("urea", [UREA_LAB["mid"]] * 2)
    add("urea_only_prediction", b, age=52.0, sex="male")
    b = Builder(8)
    b.reservoir("creatinine", [creatinine(60)] * 2).reservoir("creatinine", [creatinine(40)])
    add("creatinine_only_prediction", b, age=49.0, sex="female")
    add("manual_classifier_choice", flower_six(seed=9), classifier_model="creatinine", age=58.0, sex="female")
    b = flower_six(seed=10)
    for r, (condition, replicate) in zip(b.reservoirs, [("Baseline", "1"), ("Baseline", "2"), ("Post-exercise", "1"),
                                                        ("Post-exercise", "2"), ("=SUM(1)", "+3"), ("", "")]):
        r.update(condition=condition, replicate=replicate)
    b.reservoir("custom", [(62.0, 8.0, 4.0)] * 2, custom_name="Glucose", condition="Baseline", replicate="1")
    b.reservoir("custom", [(48.0, -6.0, 20.0)])
    add("custom_biomarkers_and_labels", b, age=58.0, sex="female")
    b = Builder(11)
    b.reservoir("ph", [ph(6.6)] * 2).reservoir("ph", [ph("invalid")])
    b.reservoir("urea", [UREA_LAB["bright"], UREA_LAB["mid"]])
    b.reservoir("creatinine", [creatinine("invalid")]).reservoir("creatinine", [creatinine("negative")])
    b.reservoir("creatinine", [creatinine(40)] * 2, review="excluded", reason="Smudged")
    add("outside_calibration_and_invalid_domains", b)
    b = Builder(12)
    analytes = ["ph", "urea", "creatinine", None]
    for index in range(30):
        analyte = analytes[index % 4]
        count = 0 if index in (7, 18) else 1 + index % 7
        target = {"ph": ph(6.6), "urea": UREA_LAB["mid"], "creatinine": creatinine(40), None: (50.0, 0.0, 0.0)}[analyte]
        b.reservoir(analyte, [target] * count, condition=f"C{index % 3}", replicate=str(index % 5),
                    review="included" if index % 9 == 0 else "needs_review")
    b.unassigned((40.0, 1.0, 1.0), (70.0, -3.0, 5.0))
    add("standard_24_many_reservoirs", b, mode="standard_24_grid", reference=STANDARD_LAB, age=60.0, sex="male",
        title="Many reservoirs")
    b = Builder(13)
    b.unassigned((40.0, 1.0, 1.0), (70.0, -3.0, 5.0))
    b.reservoirs = [{"id": 1, "analyte": None, "roi_ids": [1, 2]}]
    add("standard_24_lab_only", b, mode="standard_24_grid", reference=STANDARD_LAB, age=60.0, sex="male")
    add("no_rois", Builder(14), age=60.0, sex="male")
    add("no_calibration_record", flower_six(seed=15), cal=False, age=58.0, sex="female")
    b = Builder(16)
    for analyte, target in (("ph", ph(6.3)), ("urea", UREA_LAB["mid"]), ("creatinine", creatinine(60))):
        b.reservoir(analyte, [target])
    add("single_roi_pixel_sd", b, age=63.0, sex="female")
    b = Builder(17)
    b.reservoir("ph", [ph(6.6)] * 2).reservoir("urea", [UREA_LAB["trace"]] * 2)
    b.reservoir("creatinine", [creatinine(20)] * 2)
    add("prediction_below_threshold", b, age=30.0, sex="female")
    return out


def run(case):
    results = concentration_results(case["draft"], case["rois"], case["calibration"])
    full = {"rois": case["rois"], **results}
    identity = {**IDENTITY, "analysis_title": f"iOS reference, {case['name']}"}
    return {**case, "identity": identity, "expected": {"results": full, "tables": export_tables(full, identity)}}


def generate_references(output):
    output.mkdir(parents=True, exist_ok=True)
    payload = {"cases": [run(c) for c in cases()]}
    (output / "cases.json").write_text(json.dumps(payload, indent=1, allow_nan=False) + "\n")
    provenance = {
        "app_version": __version__,
        "configuration": CONFIG_VERSION,
        "engine_utils_sha256": sha(ROOT / "api/ckd/utils.py"),
        "engine_models_sha256": sha(ROOT / "api/ckd/models.py"),
        "generator_sha256": sha(HERE / "utils.py"),
        "python": platform.python_version(),
        "numpy": np.__version__,
        "execution": "Mac engine concentration_results and export_tables on synthetic ROI measurements",
    }
    (output / "provenance.json").write_text(json.dumps(provenance, indent=1) + "\n")
    return payload


PIPELINES = [
    ("iPhoneRAW.DNG", False, "dng_standard24"),
    ("SampleImg1.CR2", False, "cr2_standard24"),
    ("_NOT_ACTUAL_TEST.dng", False, "dng_flower_auto"),
    ("_NOT_ACTUAL_TEST.dng", True, "dng_flower_manual"),
]


def test_helpers():
    import importlib.util
    import sys

    sys.path.insert(0, str(HERE.parent))
    spec = importlib.util.spec_from_file_location("ckd_test_helpers", HERE.parent / "utils.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stable(document):
    out = {k: v for k, v in document.items() if k not in ("project_path", "read_only", "job_history")}
    out["job"] = None
    return out


def generate_mac_references(output):
    import shutil
    import tempfile

    helpers = test_helpers()
    fixtures = HERE.parent / "fixtures"
    pipeline_dir = output / "mac_reference" / "pipeline"
    contract_dir = output / "mac_reference" / "contract"
    pipeline_dir.mkdir(parents=True, exist_ok=True)
    for name, manual, label in PIPELINES:
        ref = helpers.swift_reference(name + ".json")
        inputs = ref["manual_inputs"] if manual else ref["inputs"]
        with tempfile.TemporaryDirectory(prefix="ckd-mac-reference-") as temporary:
            with helpers.pipeline_context(Path(temporary)) as (api, service):
                with (fixtures / name).open("rb") as stream:
                    response = api.post("/api/analyses", files={"file": (name, stream)})
                response.raise_for_status()
                doc = response.json()
                url = f"/api/analyses/{doc['id']}"
                for action in ("render", "white_balance", "calibrate", "analyze"):
                    if action == "white_balance":
                        draft = helpers.swift_draft(inputs, ref["white_balance_polygon"]["points"])
                        draft["title"] = label
                        response = api.put(url, json={"revision": doc["revision"], "draft": draft})
                        response.raise_for_status()
                        doc = response.json()
                    response = api.post(url + "/jobs", json={"revision": doc["revision"], "action": action})
                    response.raise_for_status()
                    doc = response.json()
                    assert doc["job"]["status"] == "completed", doc["job"]
                (pipeline_dir / f"{label}.json").write_text(json.dumps(stable(doc), indent=1) + "\n")
                if label == "dng_flower_manual":
                    directory = service.directory(doc)
                    folder = contract_dir / "Mac analysis"
                    (folder / "original").mkdir(parents=True, exist_ok=True)
                    shutil.copy2(directory / "analysis.ckd.json", folder / "analysis.ckd.json")
                    shutil.copy2(directory / doc["source"]["file"], folder / doc["source"]["file"])
                    _, archive = service.export_archive(doc["id"], include_rasters=True)
                    shutil.copy2(archive, contract_dir / "mac_export.zip")
                    archive.unlink()
    provenance = {
        "app_version": __version__,
        "configuration": CONFIG_VERSION,
        "engine_sha256": {p.name: sha(p) for p in sorted((ROOT / "api/ckd").rglob("*.py"))},
        "generator_sha256": sha(HERE / "utils.py"),
        "execution": "Mac LocalAnalysisService render, white balance, calibrate and analyze on the RAW fixtures",
    }
    (output / "mac_reference" / "provenance.json").write_text(json.dumps(provenance, indent=1) + "\n")
