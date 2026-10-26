from ckd.utils import concentration_results, export_tables, outside_calibration_range
from utils import draft_with_reservoirs

CALIBRATION = {"reference_lab": [[30, -20, -20], [90, 40, 60]], "rmse": 1.0,
               "coefficients": [[1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 0, 0]]}


def test_range_check_names_each_channel_outside_the_patch_colors():
    reference = CALIBRATION["reference_lab"]
    assert outside_calibration_range([60, 0, 0], reference) == []
    assert outside_calibration_range([95, 0, -25], reference) == ["L", "b"]
    assert outside_calibration_range([90.5, 0, 0], reference, margin=1.0) == []


def test_out_of_range_roi_needs_review_and_is_exported():
    draft, rois = draft_with_reservoirs([("ph", [[60, 0, 19.19]]), ("creatinine", [[95, 5, 0]])])
    results = {"rois": rois, **concentration_results(draft, rois, CALIBRATION)}
    ph, creatinine = results["reservoirs"]
    assert ph["review_status"] == "automatically_included"
    assert creatinine["review_status"] == "needs_review"
    assert any("outside the calibration patch range (L)" in w for w in creatinine["warnings"])
    assert results["outside_calibration"] == [{"roi_id": 2, "channels": ["L"]}]
    assert "roi_outside_calibration_range" in export_tables(results)["08_notes.csv"]


def test_lab_only_and_pending_modes_still_report_flags():
    draft, rois = draft_with_reservoirs([("ph", [[95, 0, 19.19]])])
    draft["mode"], draft["reservoirs"] = "standard_24_grid", []
    assert concentration_results(draft, rois, CALIBRATION)["outside_calibration"] == [{"roi_id": 1, "channels": ["L"]}]


def test_without_a_stored_calibration_nothing_is_flagged():
    draft, rois = draft_with_reservoirs([("creatinine", [[95, 5, 0]])])
    assert concentration_results(draft, rois)["outside_calibration"] == []
