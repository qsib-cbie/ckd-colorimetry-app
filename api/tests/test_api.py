import copy
import csv
import hashlib
import io
import json
import threading
import zipfile

import pytest
from ckd.local import LocalAnalysisService
from ckd.projects import Conflict, ProjectStore
from ckd.utils import versions
from utils import FIXTURES, flower_image, legacy_coordinate_package, rectangle


def test_api_rejects_bad_upload_and_cross_origin(client):
    api, _ = client
    assert (
        api.post("/api/analyses", files={"file": ("bad.png", b"nope")}).status_code
        == 422
    )
    assert (
        api.post("/api/analyses", files={"file": ("empty.dng", b"")}).status_code == 422
    )
    assert (
        api.post(
            "/api/analyses",
            headers={"Origin": "https://unrelated.example"},
            files={"file": ("x.dng", b"123")},
        ).status_code
        == 403
    )
    assert api.get("/api/analyses/missing").status_code == 404


def test_corrupt_raw_is_a_visible_retryable_job_error(client):
    api, _ = client
    doc = api.post(
        "/api/analyses", files={"file": ("bad.dng", b"invalid raw image")}
    ).json()
    doc = api.post(
        f"/api/analyses/{doc['id']}/jobs",
        json={"revision": doc["revision"], "action": "render"},
    ).json()
    assert doc["job"]["status"] == "failed"
    assert doc["job"]["error"]
    assert doc["job"]["timings_seconds"]["render.raw_open"] >= 0
    assert doc["render"] is None
    retried = api.post(
        f"/api/analyses/{doc['id']}/jobs",
        json={"revision": doc["revision"], "action": "render"},
    )
    assert retried.status_code == 202
    assert retried.json()["job"]["id"] != doc["job"]["id"]


def test_atomic_revisions_busy_conflicts_and_geometry(client):
    _, service = client
    doc = service.create("sample.dng", io.BytesIO(b"raw placeholder"))
    doc["source"].update(width=1000, height=1000)
    doc = service.store.replace(doc, 0)
    draft = copy.deepcopy(doc["draft"])
    draft["title"] = "saved"
    saved = service.save(doc["id"], doc["revision"], draft)
    with pytest.raises(Conflict):
        service.save(doc["id"], doc["revision"], draft)
    with pytest.raises(Conflict):
        service.store.replace(doc, doc["revision"])
    invalid = copy.deepcopy(draft)
    invalid["white_balance"] = rectangle(-1, 0)
    with pytest.raises(ValueError, match="inside"):
        service.save(doc["id"], saved["revision"], invalid)
    release = threading.Event()
    service.pending["busy"] = service.worker.submit(release.wait, 5)
    saved["job"] = {"id": "busy", "status": "running"}
    busy = service.store.replace(saved, saved["revision"])
    try:
        with pytest.raises(Conflict, match="active"):
            service.save(doc["id"], busy["revision"], draft)
    finally:
        release.set()


def test_worker_crash_becomes_visible_and_stale_delivery_is_ignored(client):
    _, service = client
    doc = service.create("sample.dng", io.BytesIO(b"raw placeholder"))
    doc["job"] = {
        "id": "stopped-job",
        "status": "running",
        "action": "render",
        "queued_at": doc["created_at"],
    }
    doc = service.store.replace(doc, 0)
    service.close()
    restarted = LocalAnalysisService(service.root, inline=True)
    recovered = restarted.fetch(doc["id"])
    restarted.close()
    assert recovered["job"]["status"] == "failed"
    assert "Retry" in recovered["job"]["error"]
    service.run(doc["id"], "stopped-job")
    assert service.store.get(doc["id"]) == recovered


def test_geometry_and_ph_review_clear_downstream_decisions(client):
    _, service = client
    doc = service.create("sample.dng", io.BytesIO(b"raw placeholder"))
    doc["source"].update(width=1000, height=1000)
    doc["draft"]["reservoirs"][0].update(analyte="ph", review="included")
    doc["draft"]["reservoirs"][1].update(analyte="urea", review="included")
    doc["white_balance"] = {"array": "unused.npy", "preview": "unused.png"}
    doc["calibration"] = {"test": True}
    doc["results"] = {"rois": [], "versions": versions()}
    doc = service.store.replace(doc, 0)
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"][0]["review"] = "excluded"
    saved = service.save(doc["id"], doc["revision"], draft)
    assert saved["draft"]["reservoirs"][1]["review"] == "needs_review"
    assert saved["results"] is not None and saved["calibration"] is not None
    draft = copy.deepcopy(saved["draft"])
    draft["white_balance"] = rectangle()
    changed = service.save(doc["id"], saved["revision"], draft)
    assert changed["white_balance"] is None and changed["calibration"] is None
    assert all(r["review"] == "needs_review" for r in changed["draft"]["reservoirs"])


@pytest.mark.raw
def test_real_dng_full_api_lifecycle_export_integrity_reopen_import(client):
    api, service = client
    with (FIXTURES / "iPhoneRAW.DNG").open("rb") as file:
        response = api.post("/api/analyses", files={"file": ("iPhoneRAW.DNG", file)})
    assert response.status_code == 201
    doc = response.json()
    base = f"/api/analyses/{doc['id']}"
    doc = api.post(
        base + "/jobs", json={"revision": doc["revision"], "action": "render"}
    ).json()
    assert doc["job"]["status"] == "completed", doc["job"]
    package = legacy_coordinate_package(doc)
    wrong = copy.deepcopy(package)
    wrong["source_image_sha256"] = "0" * 64
    assert (
        api.post(
            base + "/coordinates", json={"revision": doc["revision"], "package": wrong}
        ).status_code
        == 422
    )
    doc = api.post(
        base + "/coordinates", json={"revision": doc["revision"], "package": package}
    ).json()
    assert doc["draft"]["mode"] == "standard_24_grid"
    for action in ["white_balance", "calibrate", "analyze"]:
        doc = api.post(
            base + "/jobs", json={"revision": doc["revision"], "action": action}
        ).json()
        assert doc["job"]["status"] == "completed", doc["job"]
    assert len(doc["results"]["rois"]) >= 12
    assert doc["results"]["prediction"]["status"] == "not_calculated"
    assert api.get(base + "/preview").headers["content-type"] == "image/png"
    response = api.get(base + "/export")
    assert response.headers["content-disposition"].startswith('attachment; filename="iPhoneRAW_')
    with zipfile.ZipFile(io.BytesIO(response.content)) as bundle:
        manifest = json.loads(bundle.read("manifest.json"))
        for filename, sha in manifest["files"].items():
            assert hashlib.sha256(bundle.read(filename)).hexdigest() == sha
        assert manifest["versions"] == doc["results"]["versions"]
        for stage, raster in (("01_libraw_initial_rendered", doc["render"]), ("02_libraw_explicit_wb", doc["white_balance"])):
            metadata = json.loads(bundle.read(f"{stage}_raster.json"))
            assert metadata["rgba8888_sha256"] == raster["rgba8888_sha256"]
            assert manifest["files"][f"{stage}_rgba8888.bin"] == raster["rgba8888_sha256"]
        patches = list(csv.DictReader(io.StringIO(bundle.read("03_colorchecker_patch_measurements.csv").decode())))
        assert len(patches) == 24 and patches[0]["analysis_id"] == doc["analysis_id"]
        rois = list(csv.DictReader(io.StringIO(bundle.read("04_roi_measurements.csv").decode())))
        assert [int(r["pixel_count"]) for r in rois] == [r["pixel_count"] for r in doc["results"]["rois"]]
        assert manifest["versions"]["configuration"] == "ckd_research_2026_10_14"
        assert json.loads(bundle.read("coordinates.json"))["schema_version"] == 2
        assert json.loads(bundle.read("results.json"))["rois"] == doc["results"]["rois"]
        assert (
            bundle.read("08_notes.csv").decode().splitlines()[0]
            == "analysis_id,analysis_title,source_filename,code,category,severity,message"
        )
        assert (
            "reservoir_id,reservoir_label,analyte,roi_ids,roi_count,minimum_roi_count,maximum_roi_count"
            in bundle.read("05_reservoirs.csv").decode()
        )
        prediction = list(
            csv.DictReader(io.StringIO(bundle.read("07_prediction.csv").decode()))
        )[0]
        assert (
            prediction["status"] == "not_calculated" and prediction["age_years"] == ""
        )
    reopened = ProjectStore(service.root).get(doc["id"])
    assert reopened == doc
    exported = api.get(base + "/coordinates").json()
    exported["schema_version"] = 1
    exported.pop("calibration_mode")
    imported = api.post(
        base + "/coordinates", json={"revision": doc["revision"], "package": exported}
    ).json()
    assert imported["results"] is None and imported["calibration"] is None
    assert imported["draft"]["mode"] == "standard_24_grid"


def test_flower_service_to_concentration_and_manual_calibration(client, monkeypatch):
    _, service = client
    image, corners, patches = flower_image()
    doc = service.create("synthetic.dng", io.BytesIO(b"test-only image substitute"))
    directory = service.directory(doc)
    doc["source"].update(width=1000, height=1000)
    doc["render"] = service.save_raster(directory, "synthetic", image)
    doc["white_balance"] = doc["render"]
    doc["draft"]["mode"] = "flower_9"
    doc["draft"]["corners"] = corners
    doc["draft"]["rois"] = [
        {"id": i + 1, "label": f"ROI {i + 1}", "points": p}
        for i, p in enumerate([patches[1], patches[2], patches[3]])
    ]
    for r, a in zip(doc["draft"]["reservoirs"], ["ph", "urea", "creatinine"]):
        r.update(analyte=a, roi_ids=[r["id"]])
    doc = service.store.replace(doc, 0)
    for action in ["calibrate", "analyze"]:
        doc = service.enqueue(doc["id"], doc["revision"], action)
        assert doc["job"]["status"] == "completed", doc["job"]
    assert len(doc["results"]["reservoirs"]) == 3
    assert doc["results"]["ph_ready_for_urea"]
    assert doc["results"]["summaries"]["urea"]["value"] is not None
    draft = copy.deepcopy(doc["draft"])
    draft.update(mode="flower_9_manual", corners=[], manual_patches=patches[::-1])
    doc = service.save(doc["id"], doc["revision"], draft)
    doc = service.enqueue(doc["id"], doc["revision"], "calibrate")
    assert doc["job"]["status"] == "completed"
    assert doc["calibration"]["rmse"] < 0.3
