"""Full-resolution RAW -> WB -> calibration -> ROI -> concentration -> ZIP.

Expected values come from frozen QDAQ Swift output and legacy Python GUI hashes.
"""

import csv
import copy
import hashlib
import io
import json
import math
import zipfile

import numpy as np
import pytest

from ckd.utils import (
    apply_calibration,
    fit_calibration,
    lab_stats,
    render_raw,
    sample_rgb,
)
from utils import (
    FIXTURES,
    SWIFT_LAB_ATOL,
    assert_same_polygon,
    assert_swift_concentrations,
    assert_swift_csvs,
    rgba_sha,
    reference,
    swift_lab,
    swift_reference,
    swift_draft,
)

pytestmark = pytest.mark.raw


def test_raw_and_each_white_balance_checkpoint(pipeline_run):
    _, service, doc, ref = pipeline_run
    directory = service.directory(doc)
    assert doc["source"]["sha256"] == ref["source_sha256"]
    assert [doc["source"]["width"], doc["source"]["height"]] == ref["dimensions"]
    initial = np.load(directory / doc["render"]["array"], allow_pickle=False)
    assert rgba_sha(initial) == ref["initial_rgba_sha256"]
    np.testing.assert_allclose(
        doc["render"]["camera_whitebalance"], ref["camera_whitebalance"], atol=0, rtol=0
    )
    polygon = ref["white_balance_polygon"]["points"]
    expected_mean = [ref["first_pass"]["mean"][k] for k in ("red", "green", "blue")]
    np.testing.assert_allclose(
        sample_rgb(initial, polygon).mean(axis=0), expected_mean, atol=1e-12, rtol=0
    )
    wb = doc["white_balance"]
    np.testing.assert_allclose(
        wb["first_pass_white_balance"],
        ref["first_pass"]["multipliers"],
        atol=1e-12,
        rtol=0,
    )
    first, _ = render_raw(
        FIXTURES / ref["inputs"]["filename"], wb["first_pass_white_balance"]
    )
    assert rgba_sha(first) == ref["first_pass_rgba_sha256"]
    np.testing.assert_allclose(
        wb["white_balance"], ref["second_pass"]["multipliers"], atol=1e-12, rtol=0
    )
    np.testing.assert_allclose(
        wb["first_pass_mean_rgb"],
        [ref["second_pass"]["mean"][k] for k in ("red", "green", "blue")],
        atol=1e-12,
        rtol=0,
    )
    assert wb["brightness"] == pytest.approx(
        ref["second_pass"]["brightness"], abs=1e-12, rel=0
    )
    final = np.load(directory / wb["array"], allow_pickle=False)
    assert rgba_sha(final) == ref["final_rgba_sha256"]
    if ref["inputs"]["mode"] == "standard_24_grid":
        legacy = reference(ref["inputs"]["filename"])
        assert (
            rgba_sha(final)
            == legacy["python_rendered_raster"]["rendered_raster"]["rgba8888"]["sha256"]
        )


def test_patch_geometry_order_lab_and_calibration_checkpoints(pipeline_run):
    _, service, doc, ref = pipeline_run
    cal, expected = doc["calibration"], ref["expected"]["calibration"]
    image = np.load(
        service.directory(doc) / doc["white_balance"]["array"], allow_pickle=False
    )
    swift_measured = [swift_lab(p["measured_median"]) for p in expected["patches"]]
    swift_reference_lab = [swift_lab(p["reference_lab"]) for p in expected["patches"]]
    # Isolate solver differences from the known RGB-to-LAB matrix rounding.
    common_fit = fit_calibration(swift_measured, swift_reference_lab)
    np.testing.assert_allclose(
        common_fit["coefficients"], expected["coefficients"], atol=1e-9, rtol=0
    )
    assert common_fit["rmse"] == pytest.approx(expected["rmse"], rel=0, abs=1e-10)
    np.testing.assert_allclose(
        cal["reference_lab"], swift_reference_lab, atol=1e-12, rtol=0
    )
    np.testing.assert_allclose(
        cal["measured_lab"], swift_measured, atol=SWIFT_LAB_ATOL, rtol=0
    )
    np.testing.assert_allclose(
        cal["coefficients"], expected["coefficients"], atol=0.01, rtol=0
    )
    assert cal["rmse"] == pytest.approx(expected["rmse"], rel=0, abs=0.01)
    for index, e in zip(cal["sample_order"], expected["patches"]):
        assert_same_polygon(cal["patches"][index], e["polygon"]["points"])
        stats = lab_stats(image, cal["patches"][index])
        assert stats["pixel_count"] == e["pixel_count"]
        np.testing.assert_allclose(
            stats["mean"], swift_lab(e["measured_mean"]), atol=SWIFT_LAB_ATOL, rtol=0
        )
        corrected = apply_calibration(stats["median"], cal["coefficients"])
        np.testing.assert_allclose(
            corrected, swift_lab(e["corrected_lab"]), atol=SWIFT_LAB_ATOL, rtol=0
        )
    np.testing.assert_allclose(
        cal["delta_e"], [p["delta_e"] for p in expected["patches"]], atol=0.02, rtol=0
    )


def test_roi_statistics_and_complete_concentration_chain(pipeline_run):
    _, _, doc, ref = pipeline_run
    actual, expected = doc["results"], ref["expected"]
    assert len(actual["rois"]) == len(expected["results"]["roi_results"])
    for a, e in zip(actual["rois"], expected["results"]["roi_results"]):
        assert a["id"] == e["roi_id"]
        assert a["pixel_count"] == e["pixel_count"]
        for key, field in [
            ("median", "raw_median"),
            ("mean", "raw_mean"),
            ("standard_deviation", "raw_standard_deviation"),
            ("calibrated_median", "calibrated_median"),
            ("calibrated_mean", "calibrated_mean"),
        ]:
            np.testing.assert_allclose(
                a[key], swift_lab(e[field]), atol=SWIFT_LAB_ATOL, rtol=0
            )
    assert_swift_concentrations(actual, expected, same_lab=False)


def test_export_download_contains_reference_values_and_valid_manifest(pipeline_run):
    api, _, doc, ref = pipeline_run
    response = api.get(f"/api/analyses/{doc['id']}/export")
    response.raise_for_status()
    with zipfile.ZipFile(io.BytesIO(response.content)) as bundle:
        manifest = json.loads(bundle.read("manifest.json"))
        assert set(manifest["files"]) == set(bundle.namelist()) - {"manifest.json"}
        for name, digest in manifest["files"].items():
            assert hashlib.sha256(bundle.read(name)).hexdigest() == digest
            if name.endswith(".png") or name.lower().endswith(".cr2"):
                assert bundle.getinfo(name).compress_type == zipfile.ZIP_STORED
            else:
                assert bundle.getinfo(name).compress_type == zipfile.ZIP_DEFLATED
        raw = bundle.read("original/" + ref["inputs"]["filename"])
        assert hashlib.sha256(raw).hexdigest() == ref["source_sha256"]
        coordinates = json.loads(bundle.read("coordinates.json"))
        assert coordinates["schema_version"] == 2
        assert coordinates["source_image_sha256"] == ref["source_sha256"]
        assert len(coordinates["rois"]) == len(ref["inputs"]["rois"])
        for a, e in zip(coordinates["rois"], ref["inputs"]["rois"]):
            assert a["roi_id"] == e["roi_id"]
            assert a["roi_label"] == e["roi_label"]
            assert_same_polygon(a["polygon"]["points"], e["polygon"]["points"])
        assert coordinates["calibration_mode"] == ref["inputs"]["mode"]
        results = json.loads(bundle.read("results.json"))
        assert results == doc["results"]
        assert_swift_concentrations(results, ref["expected"], same_lab=False)
        tables = {
            name: bundle.read(name).decode()
            for name in ("05_reservoirs.csv", "06_analytes.csv", "07_prediction.csv")
        }
        assert_swift_csvs(tables, ref["expected"], same_lab=False)
        rows = list(csv.DictReader(io.StringIO(bundle.read("results.csv").decode())))
        for row, expected in zip(rows, ref["expected"]["results"]["roi_results"]):
            assert int(row["pixel_count"]) == expected["pixel_count"]
            np.testing.assert_allclose(
                json.loads(row["calibrated_median"]),
                swift_lab(expected["calibrated_median"]),
                atol=SWIFT_LAB_ATOL,
                rtol=0,
            )
        assert api.get(f"/api/analyses/{doc['id']}").json()["results"] == results


def test_stage_timings_are_persisted_for_the_complete_pipeline(pipeline_run):
    api, _, doc, _ = pipeline_run
    reopened = api.get(f"/api/analyses/{doc['id']}").json()
    jobs = {job["action"]: job for job in reopened["job_history"]}
    required = {
        "render": {
            "render.raw_open",
            "render.raw_unpack",
            "render.raw_postprocess",
            "raster.npy_write",
            "preview.png_encode",
            "preview.file_write",
        },
        "white_balance": {
            "white_balance.initial_sample",
            "white_balance.pass1.raw_unpack",
            "white_balance.pass1.raw_postprocess",
            "white_balance.pass1_sample",
            "white_balance.pass2.raw_unpack",
            "white_balance.pass2.raw_postprocess",
            "preview.png_encode",
            "preview.file_write",
        },
        "calibrate": {"calibration"},
        "analyze": {"roi_measurements_and_concentrations", "run_snapshot"},
    }
    for action, keys in required.items():
        timings = jobs[action]["timings_seconds"]
        assert keys <= timings.keys()
        assert all(math.isfinite(value) and value >= 0 for value in timings.values())
        assert all(
            value <= jobs[action]["seconds"] + 0.005 for value in timings.values()
        )


def test_excluding_all_ph_clears_urea_and_regenerates_export_against_swift(client):
    api, _ = client
    name = "_NOT_ACTUAL_TEST.dng"
    ref = swift_reference(name + ".json")
    with (FIXTURES / name).open("rb") as raw:
        response = api.post("/api/analyses", files={"file": (name, raw)})
    response.raise_for_status()
    doc = response.json()
    url = f"/api/analyses/{doc['id']}"
    doc = api.post(
        url + "/jobs", json={"revision": doc["revision"], "action": "render"}
    ).json()
    draft = swift_draft(ref["inputs"], ref["white_balance_polygon"]["points"])
    doc = api.put(url, json={"revision": doc["revision"], "draft": draft}).json()
    for action in ("white_balance", "calibrate", "analyze"):
        doc = api.post(
            url + "/jobs", json={"revision": doc["revision"], "action": action}
        ).json()
        assert doc["job"]["status"] == "completed", doc["job"]
    assert doc["results"]["prediction"]["status"] == "complete"
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"][0]["review"] = "excluded"
    doc = api.put(url, json={"revision": doc["revision"], "draft": draft}).json()
    expected = ref["excluded_ph_expected"]
    assert_swift_concentrations(doc["results"], expected, same_lab=False)
    reanalyzed = api.post(
        url + "/jobs", json={"revision": doc["revision"], "action": "analyze"}
    ).json()
    assert reanalyzed["job"]["status"] == "completed", reanalyzed["job"]
    assert reanalyzed["results"]["reservoirs"] == doc["results"]["reservoirs"]
    assert reanalyzed["results"]["summaries"] == doc["results"]["summaries"]
    doc = reanalyzed
    assert doc["results"]["reservoirs"][1]["value"] is None
    assert doc["results"]["reservoirs"][1]["calculation_status"] == "missing_input"
    downloaded = api.get(url + "/export")
    downloaded.raise_for_status()
    with zipfile.ZipFile(io.BytesIO(downloaded.content)) as bundle:
        assert_swift_csvs(
            {
                name: bundle.read(name).decode()
                for name in (
                    "05_reservoirs.csv",
                    "06_analytes.csv",
                    "07_prediction.csv",
                )
            },
            expected,
            same_lab=False,
        )
