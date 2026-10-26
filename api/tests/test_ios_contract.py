"""iOS analysis folders and export ZIPs open, import, reproduce and stay editable on the Mac."""

import csv
import io
import json
import shutil
import zipfile

import numpy as np
import pytest

from ckd.projects import ProjectStore
from ckd.projects.importer import ExportImporter
from ckd.projects.utils import validate_document
from ckd.utils import (
    calibrate,
    export_tables,
    measure_rois,
    patch_measurements_csv,
    render_raw,
    rgba_digest,
    roi_measurements_csv,
    white_balance,
)
from utils import FIXTURES

CONTRACT = FIXTURES / "ios_contract"
FOLDER = CONTRACT / "_NOT_ACTUAL_TEST"
ARCHIVE = CONTRACT / "ios_export.zip"


def ios_document():
    return json.loads((FOLDER / "analysis.ckd.json").read_text())


def identity(doc):
    return {"analysis_id": doc["analysis_id"], "analysis_title": doc["draft"]["title"],
            "source_filename": doc["source"]["filename"]}


def zip_text(name):
    with zipfile.ZipFile(ARCHIVE) as archive:
        return archive.read(name).decode()


def assert_close(actual, expected, tolerance, path="$"):
    if isinstance(expected, dict):
        assert set(actual) == set(expected), path
        for key in expected:
            assert_close(actual[key], expected[key], tolerance, f"{path}.{key}")
    elif isinstance(expected, list):
        assert len(actual) == len(expected), path
        for index, (a, e) in enumerate(zip(actual, expected)):
            assert_close(a, e, tolerance, f"{path}[{index}]")
    elif isinstance(expected, float) and not isinstance(actual, bool):
        assert actual == pytest.approx(expected, rel=tolerance, abs=tolerance), path
    else:
        assert actual == expected, path


def assert_csv_close(actual, expected, tolerance):
    a, e = list(csv.reader(io.StringIO(actual))), list(csv.reader(io.StringIO(expected)))
    assert len(a) == len(e)
    for row_a, row_e in zip(a, e):
        assert len(row_a) == len(row_e)
        for x, y in zip(row_a, row_e):
            if x == y:
                continue
            parts = [p.split(":") for p in (x, y)] if ":" in x else [x.split(";"), y.split(";")]
            values = [[float(v.lstrip("'")) for v in part] for part in parts]
            np.testing.assert_allclose(values[0], values[1], atol=tolerance, rtol=0)


@pytest.fixture(scope="module")
def mac_rerun():
    doc = ios_document()
    source = FOLDER / doc["source"]["file"]
    initial, meta = render_raw(source)
    image, _ = white_balance(source, initial, meta["camera_whitebalance"], doc["draft"]["white_balance"])
    draft = doc["draft"]
    calibration = calibrate(image, draft["mode"], draft["corners"], draft["manual_patches"])
    return doc, initial, image, calibration, measure_rois(image, draft, calibration)


def test_mac_validates_and_lists_the_ios_folder(tmp_path):
    validate_document(ios_document())
    shutil.copytree(FOLDER, tmp_path / "iPad analysis")
    library = ProjectStore(tmp_path).library()
    assert library["problems"] == []
    assert [a["analysis_id"] for a in library["analyses"]] == [ios_document()["analysis_id"]]


def test_mac_imports_the_ios_export_zip(tmp_path):
    store = ProjectStore(tmp_path)
    imported = ExportImporter(store).import_zip(ARCHIVE)
    doc = ios_document()
    assert imported["analysis_id"] == doc["analysis_id"]
    assert imported["results"] == doc["results"]
    assert imported["render"]["array"].startswith(".cache/")


def test_mac_reproduces_ios_rasters_calibration_and_results(mac_rerun):
    doc, initial, image, calibration, results = mac_rerun
    assert rgba_digest(initial) == doc["render"]["rgba8888_sha256"]
    assert rgba_digest(image) == doc["white_balance"]["rgba8888_sha256"]
    assert_close(calibration, doc["calibration"], 1e-12)
    expected = {k: v for k, v in doc["results"].items() if k not in ("versions", "calculated_at")}
    actual = {k: v for k, v in results.items() if k not in ("versions", "calculated_at")}
    assert_close(json.loads(json.dumps(actual)), expected, 1e-12)
    assert doc["results"]["versions"]["platform"] == "ios"


def test_mac_accepts_ios_results_and_allows_review_edits(tmp_path):
    from ckd.local import LocalAnalysisService

    shutil.copytree(FOLDER, tmp_path / "iPad analysis")
    service = LocalAnalysisService(tmp_path, inline=True)
    doc = service.fetch(service.store.library()["analyses"][0]["id"])
    comparison = service.comparison(doc)
    assert comparison["calculated_on"] == "ios" and comparison["calculated_with"] == "2.1.0"
    assert [row["key"] for row in comparison["versions"] if row["differs"]] == ["app"]
    assert not comparison["affects_values"] and not comparison["needs_remeasure"]
    assert not any(row["changed"] for row in comparison["values"])
    draft = doc["draft"]
    target = next(r for r in draft["reservoirs"] if r["analyte"] == "ph" and r["roi_ids"])
    target.update(review="excluded", reason="Bubble")
    saved = service.save(doc["id"], doc["revision"], draft)
    assert target["id"] not in saved["results"]["summaries"]["ph"]["included_ids"]
    assert saved["results"]["versions"]["platform"] == "ios"


def test_ios_export_tables_match_mac_formatting(mac_rerun):
    doc, _, image, calibration, results = mac_rerun
    for name, text in export_tables(doc["results"], identity(doc)).items():
        assert zip_text(name) == text, name
    assert_csv_close(zip_text("03_colorchecker_patch_measurements.csv"),
                     patch_measurements_csv(image, doc["calibration"], identity(doc)), 1.5e-6)
    assert_csv_close(zip_text("04_roi_measurements.csv"),
                     roi_measurements_csv(image, doc["draft"], doc["results"], doc["calibration"], identity(doc)), 1.5e-6)
    manifest = json.loads(zip_text("manifest.json"))
    assert manifest["schema_name"] == "ckd_export"
    assert manifest["files"]["02_libraw_explicit_wb_rgba8888.bin"] == doc["white_balance"]["rgba8888_sha256"]
