"""Compare the desktop engine with the executed QDAQ Swift source."""

import numpy as np
import pytest

from ckd.utils import (
    calculate,
    classifier,
    concentration_results,
    export_tables,
    fit_calibration,
    lab_stats,
    sample_rgb,
)
from utils import (
    assert_swift_concentrations,
    assert_swift_csvs,
    oracle_number,
    swift_draft,
    swift_reference,
    swift_roi_measurements,
    swift_lab,
    SWIFT_LAB_ATOL,
)

REFERENCE = swift_reference("units.json")


@pytest.mark.parametrize(
    "case", REFERENCE["equations"], ids=lambda c: c["input"]["name"]
)
def test_equations_domains_ranges_and_ph_model_boundaries_against_swift(case):
    i, e = case["input"], case["expected"]
    actual = calculate(
        i["analyte"], list(map(oracle_number, i["lab"])), oracle_number(i.get("ph"))
    )
    assert actual["calculation_status"] == e["status"]
    assert actual["value"] == pytest.approx(e["value"], rel=0, abs=1e-10)
    assert actual["urea_ph_model"] == e["model"]
    assert actual["equation_version"] == e["equation_version"]
    assert bool(actual["warnings"]) == bool(e["warnings"])


@pytest.mark.parametrize("case", REFERENCE["fits"])
def test_independent_l_and_joint_ab_fit_against_swift_on_identical_lab(case):
    i = case["input"]
    if case["coefficients"] is None:
        with pytest.raises(ValueError, match="degenerate"):
            fit_calibration(i["measured"], i["reference"])
    else:
        fit = fit_calibration(i["measured"], i["reference"])
        np.testing.assert_allclose(
            fit["coefficients"], case["coefficients"], rtol=0, atol=1e-10
        )


REVIEWER_INCLUDED_CASES = {"negative_urea_included", "negative_creatinine_included"}


@pytest.mark.parametrize(
    "case", [c for c in REFERENCE["reservoirs"] if c["input"]["name"] not in REVIEWER_INCLUDED_CASES],
    ids=lambda c: c["input"]["name"],
)
def test_roi_aggregation_review_dependency_summaries_and_export_against_swift(case):
    i = case["input"]
    actual = concentration_results(
        swift_draft(i), swift_roi_measurements(i["roi_results"])
    )
    assert_swift_concentrations(actual, case["expected"])
    assert_swift_csvs(export_tables({**actual, "rois": []}), case["expected"])


@pytest.mark.parametrize(
    "case", [c for c in REFERENCE["reservoirs"] if c["input"]["name"] in REVIEWER_INCLUDED_CASES],
    ids=lambda c: c["input"]["name"],
)
def test_an_explicitly_included_invalid_value_counts_unlike_legacy_swift(case):
    i = case["input"]
    actual = concentration_results(swift_draft(i), swift_roi_measurements(i["roi_results"]))
    legacy = {r["reservoir_id"]: r for r in case["expected"]["results"]["reservoir_results"]}
    included = [r for r in actual["reservoirs"]
                if r["calculation_status"] == "invalid_domain" and r["review"] == "included"]
    assert included and all(legacy[r["id"]]["review_status"] == "mathematically_invalid" for r in included)
    for r in included:
        assert r["review_status"] == "included"
        assert r["id"] in actual["summaries"][r["analyte"]]["included_ids"]
        assert any("included by the reviewer" in w for w in r["warnings"])


@pytest.mark.parametrize("case", REFERENCE["classifiers"])
def test_classifier_probability_sign_demographics_and_overflow_against_swift(case):
    i, e = case["input"], case["expected"]
    actual = classifier(i["urea"], i["creatinine"], oracle_number(i["age"]), i["sex"])
    if e is None:
        assert actual["status"] == "not_calculated"
    else:
        assert actual["status"] == "complete"
        assert actual["classification"] == e["label"]
        assert actual["threshold"] == e["threshold"]
        assert actual["probability"] == pytest.approx(
            e["probability"], rel=0, abs=1e-12
        )


@pytest.mark.parametrize(
    "case", REFERENCE["sampling"], ids=lambda c: c["input"]["name"]
)
def test_pixel_boundaries_rgb_lab_median_mean_population_sd_against_swift(case):
    i, e = case["input"], case["expected"]
    image = np.array(i["rgb"], dtype=np.uint8).reshape(i["height"], i["width"], 3)
    stats = lab_stats(image, i["polygon"]["points"])
    assert stats["pixel_count"] == e["pixel_count"]
    for field in ("median", "mean", "standard_deviation"):
        np.testing.assert_allclose(
            stats[field], swift_lab(e[field]), atol=SWIFT_LAB_ATOL, rtol=0
        )
    np.testing.assert_allclose(
        sample_rgb(image, i["polygon"]["points"]).mean(axis=0),
        [e["rgb_mean"][k] for k in ("red", "green", "blue")],
        atol=1e-12,
        rtol=0,
    )
