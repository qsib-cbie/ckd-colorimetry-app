import copy

import pytest

from ckd.utils import concentration_results, export_tables, urea_model
from test_storage import flower_analysis
from utils import draft_with_reservoirs


def urea(results):
    return next(r for r in results["reservoirs"] if r["analyte"] == "urea")


def test_nearest_model_follows_the_midpoint_rule():
    assert [urea_model(p) for p in (6.0, 6.25, 6.26, 6.75, 6.76, None)] == [
        "pH_6.0", "pH_6.0", "pH_6.5", "pH_6.5", "pH_7.0", None]
    assert [urea_model(p) for p in (4.9, 5.99, 7.01, 7.6, 7.99)] == [
        "pH_6.0", "pH_6.0", "pH_7.0", "pH_7.0", "pH_7.0"]


def test_manual_model_overrides_the_measured_ph():
    draft, rois = draft_with_reservoirs([("ph", [[60, 0, 19.19]]), ("urea", [[60, 0, 0]])])
    automatic = concentration_results(draft, rois)
    assert urea(automatic)["urea_ph_model"] == "pH_6.0"
    assert automatic["urea_ph_model"] == {"source": "measured", "selected": "pH_6.0", "nearest": "pH_6.0"}
    draft["urea_ph_model"] = "pH_7.0"
    manual = concentration_results(draft, rois)
    assert urea(manual)["urea_ph_model"] == "pH_7.0"
    assert urea(manual)["value"] == pytest.approx(592.133 - 5.940 * 60)
    assert manual["urea_ph_model"] == {"source": "manual", "selected": "pH_7.0", "nearest": "pH_6.0"}


def test_without_ph_urea_needs_a_manual_model():
    draft, rois = draft_with_reservoirs([("urea", [[60, 0, 0]])])
    assert urea(concentration_results(draft, rois))["calculation_status"] == "missing_input"
    draft["urea_ph_model"] = "pH_6.0"
    chosen = urea(concentration_results(draft, rois))
    assert chosen["calculation_status"] == "valid"
    assert chosen["value"] == pytest.approx(328.758 - 3.707 * 60)


def test_drafts_saved_before_the_field_existed_still_calculate():
    draft, rois = draft_with_reservoirs([("ph", [[60, 0, 19.19]]), ("urea", [[60, 0, 0]])])
    del draft["urea_ph_model"]
    assert urea(concentration_results(draft, rois))["urea_ph_model"] == "pH_6.0"


def test_choosing_a_model_recomputes_without_a_job_and_is_exported(client):
    api, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    draft["urea_ph_model"] = "pH_7.0"
    saved = api.put(f"/api/analyses/{doc['id']}", json={"revision": doc["revision"], "draft": draft}).json()
    assert saved["job"] == doc["job"]
    assert saved["results"]["urea_ph_model"]["source"] == "manual"
    assert urea(saved["results"])["equation_version"].endswith(":pH_7.0")
    assert "urea_ph_model_manual" in export_tables(saved["results"])["08_notes.csv"]
