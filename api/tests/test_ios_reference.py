"""The Mac engine reproduces the frozen iOS results cases and Mac pipeline references."""

import json

import pytest

from ckd.utils import concentration_results, export_tables
from utils import FIXTURES

CASES = json.loads((FIXTURES / "ios_results" / "cases.json").read_text())["cases"]


@pytest.mark.parametrize("case", CASES, ids=lambda c: c["name"])
def test_mac_engine_matches_frozen_ios_reference(case):
    results = concentration_results(case["draft"], case["rois"], case["calibration"])
    full = {"rois": case["rois"], **results}
    assert json.loads(json.dumps(full)) == case["expected"]["results"]
    assert export_tables(full, case["identity"]) == case["expected"]["tables"]


PIPELINES = {
    "dng_standard24": "iPhoneRAW.DNG",
    "cr2_standard24": "SampleImg1.CR2",
    "dng_flower_auto": "_NOT_ACTUAL_TEST.dng",
    "dng_flower_manual": "_NOT_ACTUAL_TEST.dng",
}


@pytest.mark.raw
@pytest.mark.parametrize("label", PIPELINES)
def test_mac_engine_matches_frozen_mac_pipeline_reference(label):
    from ckd.utils import calibrate, measure_rois, render_raw, rgba_digest, white_balance

    doc = json.loads((FIXTURES / "mac_reference" / "pipeline" / f"{label}.json").read_text())
    source, draft = FIXTURES / PIPELINES[label], doc["draft"]
    initial, meta = render_raw(source)
    image, wb = white_balance(source, initial, meta["camera_whitebalance"], draft["white_balance"])
    assert rgba_digest(initial) == doc["render"]["rgba8888_sha256"]
    assert rgba_digest(image) == doc["white_balance"]["rgba8888_sha256"]
    assert wb["white_balance"] == doc["white_balance"]["white_balance"]
    calibration = calibrate(image, draft["mode"], draft["corners"], draft["manual_patches"])
    assert json.loads(json.dumps(calibration)) == doc["calibration"]
    results = json.loads(json.dumps(measure_rois(image, draft, calibration)))
    for key in ("versions", "calculated_at"):
        results.pop(key)
    assert results == {k: v for k, v in doc["results"].items() if k not in ("versions", "calculated_at")}
