import copy
import csv
import glob
import hashlib
import io
import json
import os
import tempfile
import zipfile

import numpy as np

from ckd.utils import IDENTITY_FIELDS, rgba_digest
from test_reliability import render_stub
from utils import flower_image


def flower_analysis(service):
    image, corners, patches = flower_image()
    doc = service.create("synthetic.dng", io.BytesIO(b"test-only image substitute"))
    directory = service.directory(doc)
    doc["source"].update(width=1000, height=1000)
    doc["render"] = {**service.save_raster(directory, "synthetic-render", image), "camera_whitebalance": [2, 1, 1.5, 0]}
    doc["white_balance"] = {**service.save_raster(directory, "synthetic-wb", image), "rgba8888_sha256": rgba_digest(image)}
    doc["draft"].update(mode="flower_9", corners=corners)
    doc["draft"]["rois"] = [
        {"id": i + 1, "label": f"ROI {i + 1}", "points": p} for i, p in enumerate([patches[1], patches[2], patches[3]])
    ]
    for reservoir, analyte in zip(doc["draft"]["reservoirs"], ["ph", "urea", "creatinine"]):
        reservoir.update(analyte=analyte, roi_ids=[reservoir["id"]])
    doc = service.store.replace(doc, 0)
    for action in ("calibrate", "analyze"):
        doc = service.enqueue(doc["id"], doc["revision"], action)
        assert doc["job"]["status"] == "completed", doc["job"]
    return doc, image


def runs(service, doc):
    return sorted((service.directory(doc) / "runs").glob("run-*"))


def test_review_and_demographics_recompute_from_stored_measurements(client):
    _, service = client
    doc, _ = flower_analysis(service)
    assert len(runs(service, doc)) == 1
    measured = copy.deepcopy(doc["results"]["rois"])
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"][0]["review"] = "excluded"
    reviewed = service.save(doc["id"], doc["revision"], draft)
    assert reviewed["job"]["action"] == "analyze"
    assert reviewed["results"]["rois"] == measured
    assert reviewed["results"]["summaries"]["ph"]["value"] is None
    assert reviewed["results"]["reservoirs"][1]["calculation_status"] == "missing_input"
    draft = copy.deepcopy(reviewed["draft"])
    draft["reservoirs"][0]["review"] = "needs_review"
    draft.update(age=50, sex="female")
    predicted = service.save(doc["id"], reviewed["revision"], draft)
    assert predicted["results"]["prediction"]["status"] == "complete"
    assert len(runs(service, doc)) == 1
    reanalyzed = service.enqueue(doc["id"], predicted["revision"], "analyze")
    assert reanalyzed["results"]["reservoirs"] == predicted["results"]["reservoirs"]
    assert reanalyzed["results"]["prediction"] == predicted["results"]["prediction"]


def test_run_snapshots_store_values_only_and_keep_previous_numbers(client):
    _, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"][0]["review"] = "excluded"
    doc = service.save(doc["id"], doc["revision"], draft)
    doc = service.enqueue(doc["id"], doc["revision"], "analyze")
    first, second = runs(service, doc)
    assert not (first / "previous_results.json").exists()
    assert json.loads((second / "previous_results.json").read_text())["summaries"]["ph"]["value"] is None
    for run in (first, second):
        names = {p.name for p in run.iterdir()}
        assert {"analysis.json", "results.json", "coordinates.json", "manifest.json", "05_reservoirs.csv"} <= names
        assert not [n for n in names if n.lower().endswith((".zip", ".png", ".dng", ".cr2", ".npy"))]
        assert sum(p.stat().st_size for p in run.iterdir()) < 200_000
        manifest = json.loads((run / "manifest.json").read_text())
        for name, digest in manifest["files"].items():
            assert hashlib.sha256((run / name).read_bytes()).hexdigest() == digest


def test_superseded_cache_rasters_are_removed(client, monkeypatch):
    _, service = client
    image = np.full((8, 8, 3), 90, dtype=np.uint8)
    monkeypatch.setattr("ckd.service.render_raw", render_stub(image))
    monkeypatch.setattr("ckd.service.white_balance", lambda *args, **kwargs: (image, {"white_balance": [1, 1, 1, 0]}))
    doc = service.create("sample.dng", io.BytesIO(b"placeholder"))
    cache = service.directory(doc) / ".cache"
    doc = service.enqueue(doc["id"], doc["revision"], "render")
    first = doc["render"]["array"]
    doc = service.enqueue(doc["id"], doc["revision"], "render")
    assert sorted(p.name for p in cache.iterdir()) == sorted(
        [doc["render"]["array"].split("/")[-1], doc["render"]["preview"].split("/")[-1]]
    )
    assert doc["render"]["array"] != first
    assert doc["render"]["rgba8888_sha256"] == rgba_digest(image)
    draft = copy.deepcopy(doc["draft"])
    draft["white_balance"] = [{"x": 1, "y": 1}, {"x": 6, "y": 1}, {"x": 6, "y": 6}]
    doc = service.save(doc["id"], doc["revision"], draft)
    doc = service.enqueue(doc["id"], doc["revision"], "white_balance")
    balanced = doc["white_balance"]["array"]
    draft = copy.deepcopy(doc["draft"])
    draft["white_balance"] = [{"x": 2, "y": 1}, {"x": 6, "y": 1}, {"x": 6, "y": 6}]
    doc = service.save(doc["id"], doc["revision"], draft)
    assert not (service.directory(doc) / balanced).exists()
    assert (service.directory(doc) / doc["render"]["array"]).exists()


def test_export_is_built_on_demand_with_debug_files(client):
    api, service = client
    doc, image = flower_analysis(service)
    before = {p for p in service.directory(doc).rglob("*")}
    leftovers = set(glob.glob(os.path.join(tempfile.gettempdir(), "ckd-export-*")))
    response = api.get(f"/api/analyses/{doc['id']}/export")
    response.raise_for_status()
    with zipfile.ZipFile(io.BytesIO(response.content)) as bundle:
        names = set(bundle.namelist())
        manifest = json.loads(bundle.read("manifest.json"))
        assert names - {"manifest.json"} == set(manifest["files"])
        assert {"01_libraw_initial_rendered_rgba8888.bin", "02_libraw_explicit_wb_rgba8888.bin",
                "03_colorchecker_patch_measurements.csv", "04_roi_measurements.csv", "roi_overlay.png",
                "original/synthetic.dng"} <= names
        assert manifest["files"]["02_libraw_explicit_wb_rgba8888.bin"] == rgba_digest(image)
        raw = np.frombuffer(bundle.read("02_libraw_explicit_wb_rgba8888.bin"), dtype=np.uint8).reshape(1000, 1000, 4)
        np.testing.assert_array_equal(raw[..., :3], image)
        for name in ("results.csv", "05_reservoirs.csv", "06_analytes.csv", "07_prediction.csv",
                     "08_notes.csv", "03_colorchecker_patch_measurements.csv", "04_roi_measurements.csv"):
            row = next(csv.DictReader(io.StringIO(bundle.read(name).decode())))
            assert [row[field] for field in IDENTITY_FIELDS] == [doc["analysis_id"], doc["draft"]["title"], "synthetic.dng"]
        patches = list(csv.DictReader(io.StringIO(bundle.read("03_colorchecker_patch_measurements.csv").decode())))
        assert len(patches) == 9
        assert float(patches[0]["delta_e"]) == round(doc["calibration"]["delta_e"][0], 6)
    small = api.get(f"/api/analyses/{doc['id']}/export?debug_rasters=false")
    with zipfile.ZipFile(io.BytesIO(small.content)) as bundle:
        assert not [n for n in bundle.namelist() if n.endswith(".bin")]
        assert "04_roi_measurements.csv" in bundle.namelist()
    assert {p for p in service.directory(doc).rglob("*")} == before
    assert set(glob.glob(os.path.join(tempfile.gettempdir(), "ckd-export-*"))) <= leftovers


def test_an_export_imports_into_another_workspace(client, tmp_path):
    from ckd.projects import ProjectStore
    from ckd.projects.importer import ExportImporter

    api, service = client
    doc, _ = flower_analysis(service)
    response = api.get(f"/api/analyses/{doc['id']}/export?debug_rasters=0")
    archive = tmp_path / "export.zip"
    archive.write_bytes(response.content)
    with zipfile.ZipFile(archive) as bundle:
        assert json.loads(bundle.read("manifest.json"))["schema_name"] == "ckd_export"
        assert json.loads(bundle.read("results.json"))["schema_name"] == "ckd_results"
    imported = ExportImporter(ProjectStore(tmp_path / "other")).import_zip(archive)
    assert imported["analysis_id"] == doc["analysis_id"]
    assert imported["results"] == doc["results"]
