import csv
import io

import numpy as np
import pytest

from ckd.utils import apply_calibration, calculate, concentration_results, export_tables
from test_storage import flower_analysis
from utils import draft_with_reservoirs

def with_spread(rois, sd):
    for roi in rois:
        roi["median"], roi["standard_deviation"] = roi["calibrated_median"], [sd, sd, sd]
    return rois


def test_one_roi_has_pixel_spread_but_no_roi_sd():
    draft, rois = draft_with_reservoirs([("ph", [[60, 0, 19.19]])])
    ph = concentration_results(draft, with_spread(rois, 2.0), {"coefficients": np.eye(4, 3).tolist()})["reservoirs"][0]
    spread = ph["uncertainty"]
    assert spread["n_rois"] == 1 and spread["roi_sd"] is None
    roi = spread["rois"][0]
    assert roi["pixel_low"] < roi["value"] < roi["pixel_high"]
    assert roi["value"] == pytest.approx(ph["value"])


def test_roi_sd_is_the_sample_sd_of_per_roi_values():
    labs = [[60, 0, 0], [60, 5, 0], [60, 10, 0]]
    draft, rois = draft_with_reservoirs([("creatinine", labs)])
    spread = concentration_results(draft, rois)["reservoirs"][0]["uncertainty"]
    values = [calculate("creatinine", lab)["value"] for lab in labs]
    assert spread["roi_sd"] == pytest.approx(np.std(values, ddof=1))
    assert (spread["roi_min"], spread["roi_max"]) == pytest.approx((min(values), max(values)))
    assert all(r["pixel_low"] is None for r in spread["rois"])


def test_urea_spread_uses_the_reservoir_model_and_waits_without_one():
    draft, rois = draft_with_reservoirs([("urea", [[60, 0, 0], [62, 0, 0]])])
    assert concentration_results(draft, rois)["reservoirs"][0]["uncertainty"] is None
    draft["urea_ph_model"] = "pH_7.0"
    spread = concentration_results(draft, rois)["reservoirs"][0]["uncertainty"]
    assert [r["value"] for r in spread["rois"]] == pytest.approx([592.133 - 5.94 * 60, 592.133 - 5.94 * 62])


def test_analysis_results_and_export_carry_uncertainty(client):
    _, service = client
    doc, _ = flower_analysis(service)
    ph = next(r for r in doc["results"]["reservoirs"] if r["analyte"] == "ph")
    roi = next(r for r in doc["results"]["rois"] if r["id"] == ph["roi_ids"][0])
    low = apply_calibration(np.asarray(roi["median"]) - roi["standard_deviation"], doc["calibration"]["coefficients"])
    expected = calculate("ph", low)["value"]
    assert expected in (ph["uncertainty"]["rois"][0]["pixel_low"], ph["uncertainty"]["rois"][0]["pixel_high"])
    rows = list(csv.DictReader(io.StringIO(export_tables(doc["results"])["09_roi_results.csv"])))
    assert [row["reservoir_id"] for row in rows] == ["1", "2", "3"]
    assert [row["biomarker"] for row in rows] == ["ph", "urea", "creatinine"]


def test_one_roi_uses_the_propagated_pixel_sd():
    draft, rois = draft_with_reservoirs([("ph", [[60, 0, 19.19]])])
    ph = concentration_results(draft, with_spread(rois, 2.0), {"coefficients": np.eye(4, 3).tolist()})["reservoirs"][0]
    roi = ph["uncertainty"]["rois"][0]
    assert ph["uncertainty"]["sd_basis"] == "pixel"
    assert ph["uncertainty"]["sd"] == pytest.approx((roi["pixel_high"] - roi["pixel_low"]) / 2)


def test_several_rois_use_the_sd_across_rois():
    draft, rois = draft_with_reservoirs([("creatinine", [[60, 0, 0], [60, 5, 0], [60, 10, 0]])])
    spread = concentration_results(draft, rois)["reservoirs"][0]["uncertainty"]
    assert spread["sd_basis"] == "rois" and spread["sd"] == spread["roi_sd"]


def test_summary_sd_spans_included_reservoirs():
    draft, rois = draft_with_reservoirs([("creatinine", [[60, 0, 0]]), ("creatinine", [[60, 5, 0]])])
    results = concentration_results(draft, rois)
    values = [r["value"] for r in results["reservoirs"]]
    summary = results["summaries"]["creatinine"]
    assert summary["sd_basis"] == "reservoirs"
    assert summary["sd"] == pytest.approx(np.std(values, ddof=1))
    single, single_rois = draft_with_reservoirs([("creatinine", [[60, 0, 0], [60, 5, 0]])])
    assert concentration_results(single, single_rois)["summaries"]["creatinine"]["sd_basis"] == "rois"


def test_pixel_sd_uses_the_valid_side_near_an_equation_limit():
    draft, rois = draft_with_reservoirs([("creatinine", [[22, -1.8, 1.5]])])
    creatinine = concentration_results(draft, with_spread(rois, 2.0), {"coefficients": np.eye(4, 3).tolist()})[
        "reservoirs"][0]
    roi = creatinine["uncertainty"]["rois"][0]
    assert roi["pixel_low"] == roi["pixel_high"]
    assert creatinine["uncertainty"]["sd"] == pytest.approx(abs(roi["pixel_high"] - roi["value"]))
    assert creatinine["uncertainty"]["sd_basis"] == "pixel"
