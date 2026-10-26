import math

import numpy as np
import pytest
from pydantic import ValidationError

from ckd.models import MAX_RESERVOIRS, MAX_ROIS, Draft
from ckd.utils import (
    FLOWER_LAB,
    apply_calibration,
    calibrate,
    calculate,
    classifier,
    concentration_results,
    fit_calibration,
    lab_stats,
    sample_rgb,
    validate_polygon,
    wb_multipliers,
)
from utils import draft_with_reservoirs, flower_image, rectangle, quantized_flower_lab


def test_boundary_inclusive_full_resolution_pixels():
    image = np.full((20, 20, 3), 128, dtype=np.uint8)
    assert len(sample_rgb(image, rectangle(1, 1, 8))) == 81
    stats = lab_stats(image, rectangle(1, 1, 8))
    assert stats["pixel_count"] == 81
    assert stats["median"] == pytest.approx(
        [53.5850, -0.0014726, 0.00279145], abs=0.0001
    )


@pytest.mark.parametrize(
    "points",
    [
        [{"x": 1, "y": 1}, {"x": 8, "y": 8}, {"x": 1, "y": 8}, {"x": 8, "y": 1}],
        [{"x": 1, "y": 1}, {"x": 2, "y": 2}, {"x": 3, "y": 3}],
        rectangle(-1, 1),
        rectangle(15, 15),
        [{"x": float("nan"), "y": 1}, {"x": 2, "y": 1}, {"x": 2, "y": 3}],
        [{"x": 1, "y": 1}, {"x": 5, "y": 1}, {"x": 5, "y": 5}, {"x": 5, "y": 1}],
    ],
)
def test_reject_invalid_geometry(points):
    with pytest.raises(ValueError):
        validate_polygon(points, 20, 20)


def test_closed_polygon_and_black_wb():
    points = rectangle()
    assert len(validate_polygon(points + [points[0]], 20, 20)) == 4
    with pytest.raises(ValueError, match="black"):
        wb_multipliers([0, 0, 0], [1, 1, 1, 0])


def test_independent_l_and_joint_ab_affine_fit():
    measured = FLOWER_LAB.copy()
    measured[:, 0] = (measured[:, 0] - 3) / 0.8
    measured[:, 1:] = (measured[:, 1:] - [2, -4]) @ np.linalg.inv(
        [[1.1, 0.2], [-0.1, 0.9]]
    )
    fit = fit_calibration(measured, FLOWER_LAB)
    assert fit["rmse"] < 1e-12
    np.testing.assert_allclose(
        apply_calibration(measured[0], fit["coefficients"]), FLOWER_LAB[0], atol=1e-10
    )
    with pytest.raises(ValueError, match="degenerate"):
        fit_calibration(np.ones((9, 3)), FLOWER_LAB)


@pytest.mark.parametrize("transform", range(8))
def test_all_automatic_flower_orientations(transform):
    image, corners, _ = flower_image()
    transformed = np.rot90(image, transform % 4)
    if transform >= 4:
        transformed = np.fliplr(transformed)
    result = calibrate(transformed, "flower_9", corners, [])
    assert result["rmse"] < 0.3
    assert result["confidence"] > 1
    np.testing.assert_allclose(
        result["measured_lab"], quantized_flower_lab(), atol=1e-10
    )


@pytest.mark.parametrize("shift", range(8))
@pytest.mark.parametrize("reverse", [False, True])
def test_manual_flower_independent_of_draw_order(shift, reverse):
    image, _, patches = flower_image()
    patches = patches[shift:] + patches[:shift]
    if reverse:
        patches = patches[::-1]
    result = calibrate(image, "flower_9_manual", [], patches)
    assert result["rmse"] < 0.3
    np.testing.assert_allclose(
        result["measured_lab"], quantized_flower_lab(), atol=1e-10
    )


def test_equations_and_exact_midpoint_ties():
    assert calculate("ph", [60, 0, -0.2435])["value"] == pytest.approx(6.5)
    assert calculate("urea", [60, 0, 20], 6.5)["value"] == pytest.approx(57.798)
    assert calculate("urea", [60, 0, 20], 6.25)["urea_ph_model"] == "pH_6.0"
    assert calculate("urea", [60, 0, 20], 6.75)["urea_ph_model"] == "pH_6.5"
    assert calculate("urea", [60, 0, 20], 6.750001)["urea_ph_model"] == "pH_7.0"
    assert calculate("creatinine", [50, 2.85, 5])["value"] == pytest.approx(
        6.354548326937925
    )
    assert calculate("ph", [60, 0, 1000])["calculation_status"] == "invalid_domain"
    assert (
        calculate("creatinine", [60, 100, 0])["calculation_status"] == "invalid_domain"
    )
    assert (
        calculate("creatinine", [60, -100, 0])["calculation_status"] == "invalid_domain"
    )
    assert calculate("urea", [100, 0, 100], 6)["calculation_status"] == "invalid_domain"
    assert calculate("urea", [60, 0, 20])["calculation_status"] == "missing_input"


@pytest.mark.parametrize("count", [1, 2, 3, 4])
def test_partial_analyte_and_one_to_four_rois(count):
    draft, results = draft_with_reservoirs([("creatinine", [[50, 2.85, 5]] * count)])
    output = concentration_results(draft, results)
    assert output["summaries"]["creatinine"]["value"] == pytest.approx(
        6.354548326937925
    )
    assert output["reservoirs"][0]["review_status"] == "automatically_included"
    assert output["prediction"]["model"] == "creatinine"
    assert output["prediction"]["status"] == "complete"
    draft["classifier_model"] = "full"
    assert concentration_results(draft, results)["prediction"]["status"] == "not_calculated"


def test_equal_roi_weight_and_concentration_before_duplicate_averaging():
    draft, results = draft_with_reservoirs(
        [("creatinine", [[50, 2.85, 5], [60, 12, 5]]), ("creatinine", [[40, 20, 5]])]
    )
    output = concentration_results(draft, results)
    assert output["reservoirs"][0]["average_lab"] == [55, 7.425, 5]
    expected = (
        calculate("creatinine", [55, 7.425, 5])["value"]
        + calculate("creatinine", [40, 20, 5])["value"]
    ) / 2
    assert output["summaries"]["creatinine"]["value"] == pytest.approx(expected)
    assert abs(expected - calculate("creatinine", [47.5, 13.7125, 5])["value"]) > 0.1


def test_ph_review_blocks_urea_until_resolved_invalid_extra_does_not():
    draft, results = draft_with_reservoirs(
        [
            ("ph", [[60, 0, -0.2435]]),
            ("ph", [[60, 0, -102.93]]),
            ("urea", [[60, 0, 20]]),
            ("creatinine", [[50, 2.85, 5]]),
        ]
    )
    first = concentration_results(draft, results)
    assert first["reservoirs"][1]["review_status"] == "needs_review"
    assert first["reservoirs"][2]["calculation_status"] == "provisional_input"
    assert first["summaries"]["urea"]["value"] is None
    draft["reservoirs"][1]["review"] = "excluded"
    second = concentration_results(draft, results)
    assert second["ph_ready_for_urea"]
    assert second["summaries"]["urea"]["value"] == pytest.approx(57.798)
    assert second["prediction"]["status"] == "complete"
    results[1]["calibrated_median"] = [60, 0, 1000]
    draft["reservoirs"][1]["review"] = "included"
    third = concentration_results(draft, results)
    assert third["reservoirs"][1]["review_status"] == "mathematically_invalid"
    assert third["ph_ready_for_urea"]


def test_classifier_uses_probability_convention_and_demographic_gate():
    result = classifier(10, 5, 50, "female")
    assert result["probability"] == pytest.approx(1 / (1 + math.exp(1.53)))
    assert result["classification"] == "Predicted G1-2"
    assert classifier(10000, 10000, 50, "male")["probability"] == 1
    assert classifier(10, 5, None, "female")["status"] == "not_calculated"


def test_assignment_validation():
    draft, _ = draft_with_reservoirs([("ph", [[60, 0, 0]])])
    draft["reservoirs"][1]["roi_ids"] = [1]
    with pytest.raises(ValidationError, match="only one"):
        Draft.model_validate(draft)
    draft["reservoirs"][1]["roi_ids"] = []
    for r in draft["reservoirs"][:3]:
        r["analyte"] = "ph"
    Draft.model_validate(draft)
    draft["reservoirs"][1]["id"] = draft["reservoirs"][0]["id"]
    with pytest.raises(ValidationError, match="Reservoir IDs must be unique"):
        Draft.model_validate(draft)


def test_reservoir_and_roi_limits():
    square = [{"x": 0, "y": 0}, {"x": 4, "y": 0}, {"x": 4, "y": 4}]
    rois = [{"id": i, "label": f"ROI {i}", "points": square} for i in range(1, 41)]
    reservoirs = [{"id": i} for i in range(1, MAX_RESERVOIRS + 1)]
    reservoirs[0]["roi_ids"] = list(range(1, 41))
    Draft.model_validate({"mode": "standard_24_grid", "rois": rois, "reservoirs": reservoirs})
    with pytest.raises(ValidationError):
        Draft.model_validate({"reservoirs": reservoirs + [{"id": MAX_RESERVOIRS + 1}]})
    with pytest.raises(ValidationError):
        Draft.model_validate({"rois": [{"id": i, "label": "ROI", "points": square} for i in range(1, MAX_ROIS + 2)]})
