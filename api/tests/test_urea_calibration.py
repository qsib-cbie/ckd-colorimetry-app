import copy

import pytest

from ckd.models import Draft
from ckd.utils import calculate, concentration_results, equation_info, export_tables, urea_value
from test_storage import flower_analysis
from utils import draft_with_reservoirs


def urea(results):
    return next(r for r in results["reservoirs"] if r["analyte"] == "urea")


def test_ab_urea_follows_the_workbook_equations():
    lab = [70, 12, 20]
    assert urea_value(lab, "pH_6.0", "ab") == pytest.approx(15.7643 + 1.7388 * 12 - 0.3501 * 20)
    assert urea_value(lab, "pH_6.5", "ab") == pytest.approx(43.5382 + 0.8451 * (12 - 20))
    assert urea_value(lab, "pH_7.0", "ab") == pytest.approx(31.5956 + 0.7921 * (12 - 20))
    assert urea_value([10, 12, 20], "pH_6.5", "ab") == urea_value(lab, "pH_6.5", "ab")


def test_lab_urea_is_unchanged_and_the_default():
    lab = [60, 0, 0]
    assert calculate("urea", lab, 6.0)["value"] == pytest.approx(328.758 - 3.707 * 60)
    ab = calculate("urea", lab, 6.0, urea_calibration="ab")
    assert ab["value"] == pytest.approx(15.7643)
    assert ab["equation_version"] == "urea_ph_specific_ab_2026_10_12:pH_6.0"
    assert calculate("urea", lab, 6.0)["equation_version"] == "urea_ph_specific_screenshot_rounded_v1:pH_6.0"


def test_the_draft_choice_drives_reservoirs_and_uncertainty():
    draft, rois = draft_with_reservoirs([("ph", [[60, 0, 19.19]]), ("urea", [[60, 10, 5], [60, 12, 5]])])
    assert Draft.model_validate(draft).urea_calibration == "lab"
    draft["urea_calibration"] = "ab"
    results = concentration_results(draft, rois)
    assert results["urea_calibration"] == "ab"
    assert urea(results)["value"] == pytest.approx(15.7643 + 1.7388 * 11 - 0.3501 * 5)
    assert [r["value"] for r in urea(results)["uncertainty"]["rois"]] == pytest.approx(
        [15.7643 + 1.7388 * 10 - 0.3501 * 5, 15.7643 + 1.7388 * 12 - 0.3501 * 5])


def test_equation_page_lists_both_calibrations():
    keys = [item["key"] for item in equation_info()["urea_calibrations"]]
    assert keys == ["lab", "ab"]


def test_switching_calibration_recomputes_without_a_job_and_is_exported(client):
    api, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    draft["urea_calibration"] = "ab"
    saved = api.put(f"/api/analyses/{doc['id']}", json={"revision": doc["revision"], "draft": draft}).json()
    assert saved["job"] == doc["job"]
    assert urea(saved["results"])["equation_version"].startswith("urea_ph_specific_ab_2026_10_12:")
    assert "urea_calibration_ab" in export_tables(saved["results"])["08_notes.csv"]


def test_analyses_saved_before_the_field_existed_save_normally(client):
    api, service = client
    doc, _ = flower_analysis(service)
    stored = service.store.get(doc["id"])
    del stored["draft"]["urea_calibration"]
    stored = service.store.replace(stored, stored["revision"])
    stored["results"]["versions"]["configuration"] = "older_equations"
    stored = service.store.replace(stored, stored["revision"])
    draft = copy.deepcopy(stored["draft"])
    draft["title"] = "Renamed only"
    draft.setdefault("urea_calibration", "lab")
    response = api.put(f"/api/analyses/{doc['id']}", json={"revision": stored["revision"], "draft": draft})
    assert response.status_code == 200, response.json()
