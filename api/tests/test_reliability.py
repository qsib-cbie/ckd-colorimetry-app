import hashlib
import io
import json
import threading
import time
import zipfile
from collections import namedtuple

import numpy as np
import pytest
from fastapi.testclient import TestClient

from ckd.desktop import create_desktop_app
from ckd.local import INTERRUPTED, LocalAnalysisService
from ckd.projects import ProjectStore
from ckd.projects.importer import ExportImporter


def render_stub(image, started=None, release=None):
    def render(path, wb=None, bright=1.0, *, timings=None, prefix="render"):
        if started:
            started.set()
            assert release.wait(5)
        return image, {"camera_whitebalance": [2.0, 1.0, 1.5, 0.0], "white_balance": wb, "brightness": bright,
                       "width": image.shape[1], "height": image.shape[0], "demosaic": "VNG",
                       "output_color": "raw", "bits": 8, "auto_bright": False}
    return render


def test_finder_rename_during_a_job_records_a_retryable_failure(tmp_path, monkeypatch):
    started, release = threading.Event(), threading.Event()
    monkeypatch.setattr("ckd.service.render_raw", render_stub(np.zeros((4, 4, 3), np.uint8), started, release))
    service = LocalAnalysisService(tmp_path)
    try:
        doc = service.create("sample.dng", io.BytesIO(b"placeholder"))
        queued = service.enqueue(doc["id"], doc["revision"], "render")
        assert started.wait(5)
        (service.root / "sample").rename(service.root / "renamed in Finder")
        release.set()
        service.pending[queued["job"]["id"]].result(timeout=10)
        moved = service.store.list()[0]
        assert moved["project_path"] == "renamed in Finder"
        assert moved["job"]["status"] == "failed"
        assert "moved" in moved["job"]["error"]
        assert not service.job_active(moved)
        retried = service.enqueue(moved["id"], moved["revision"], "render")
        service.pending[retried["job"]["id"]].result(timeout=10)
        assert service.fetch(moved["id"])["job"]["status"] == "completed"
    finally:
        release.set()
        service.close()


def test_stale_running_job_is_shown_interrupted_and_does_not_block(client, isolated_trash):
    api, service = client
    doc = service.create("sample.dng", io.BytesIO(b"placeholder"))
    doc["job"] = {"id": "not-running-anywhere", "status": "running", "action": "render"}
    service.store.replace(doc, doc["revision"])
    shown = api.get(f"/api/analyses/{doc['id']}").json()
    assert shown["job"]["status"] == "failed" and shown["job"]["error"] == INTERRUPTED
    assert service.store.get(doc["id"])["job"]["status"] == "failed"
    assert api.post("/api/workspace", json={"path": str(service.root.parent / "other")}).status_code == 200


def test_trash_and_move_ignore_a_stale_job_status(tmp_path, isolated_trash):
    service = LocalAnalysisService(tmp_path / "workspace", inline=True)
    try:
        doc = service.create("sample.dng", io.BytesIO(b"placeholder"))
        doc["job"] = {"id": "stale", "status": "queued", "action": "render"}
        service.store.replace(doc, doc["revision"])
        assert service.store.move("sample", "Renamed")["path"] == "Renamed"
        service.store.trash("Renamed")
        assert service.store.list() == []
    finally:
        service.close()


def test_insufficient_disk_space_is_reported_before_queueing(client, monkeypatch):
    _, service = client
    doc = service.create("sample.dng", io.BytesIO(b"placeholder"))
    usage = namedtuple("usage", "total used free")
    monkeypatch.setattr("ckd.local.shutil.disk_usage", lambda path: usage(10**9, 10**9 - 1024, 1024))
    with pytest.raises(ValueError, match="free disk space"):
        service.enqueue(doc["id"], doc["revision"], "render")
    assert service.store.get(doc["id"])["job"] is None


def test_truncated_cache_is_rebuilt_atomically(client, monkeypatch):
    _, service = client
    image = np.arange(4 * 5 * 3, dtype=np.uint8).reshape(4, 5, 3)
    monkeypatch.setattr("ckd.local.render_raw", render_stub(image))
    doc = service.create("sample.dng", io.BytesIO(b"placeholder"))
    directory = service.directory(doc)
    doc["source"].update(width=5, height=4)
    doc["render"] = service.save_raster(directory, "r1-render", image)
    doc = service.store.replace(doc, doc["revision"])
    array = directory / doc["render"]["array"]
    array.write_bytes(b"")
    rebuilt = service.cached_image(doc)
    np.testing.assert_array_equal(rebuilt, image)
    np.testing.assert_array_equal(np.load(array), image)
    assert not list(directory.rglob("*.part"))


def test_quit_cancels_queued_jobs_and_they_reopen_as_interrupted(tmp_path, monkeypatch):
    service = LocalAnalysisService(tmp_path)
    started, release = threading.Event(), threading.Event()
    calls = []

    def calculation(analysis_id, job_id):
        calls.append(analysis_id)
        started.set()
        assert release.wait(5)

    monkeypatch.setattr(service, "run", calculation)
    a = service.create("a.dng", io.BytesIO(b"a"))
    b = service.create("b.dng", io.BytesIO(b"b"))
    service.enqueue(a["id"], 0, "render")
    assert started.wait(5)
    service.enqueue(b["id"], 0, "render")
    closing = threading.Thread(target=service.close)
    closing.start()
    time.sleep(0.2)
    release.set()
    closing.join(10)
    assert calls == [a["id"]]
    reopened = LocalAnalysisService(tmp_path)
    try:
        assert reopened.fetch(b["id"])["job"]["status"] == "failed"
    finally:
        reopened.close()


def export_archive(path, document):
    payloads = {"analysis.json": json.dumps(document).encode(), "original/sample.dng": b"original RAW bytes"}
    manifest = {"schema_name": "ckd_web_export", "schema_version": 1,
                "files": {name: hashlib.sha256(data).hexdigest() for name, data in payloads.items()}}
    with zipfile.ZipFile(path, "w") as output:
        for name, data in payloads.items():
            output.writestr(name, data)
        output.writestr("manifest.json", json.dumps(manifest))
    return path


def exported_document():
    from ckd.models import Draft, Reservoir
    return {
        "id": "a98fe940-95db-4951-8d83-f998377753c6", "revision": 0, "created_at": "2026-09-28", "updated_at": "2026-09-28",
        "source": {"filename": "sample.dng", "file": "original/sample.dng",
                   "sha256": hashlib.sha256(b"original RAW bytes").hexdigest()},
        "draft": Draft(reservoirs=[Reservoir(id=i) for i in range(1, 7)]).model_dump(),
        "render": None, "white_balance": None, "calibration": None, "results": None, "export": None, "job": None,
    }


def hidden_staging(root):
    return [p.name for p in root.iterdir() if p.name.startswith((".archive-", ".backup-", ".import-"))]


def test_imports_leave_no_hidden_staging_copies(tmp_path):
    target = ProjectStore(tmp_path / "workspace")
    ExportImporter(target).import_zip(export_archive(tmp_path / "export.zip", exported_document()))
    assert len(target.list()) == 1
    assert hidden_staging(target.root) == []


def test_invalid_exported_document_leaves_nothing_behind(tmp_path):
    document = exported_document()
    document["draft"]["unknown_field"] = True
    target = ProjectStore(tmp_path / "workspace")
    with pytest.raises(ValueError):
        ExportImporter(target).import_zip(export_archive(tmp_path / "export.zip", document))
    library = target.library()
    assert library["folders"] == [] and library["analyses"] == []
    assert hidden_staging(target.root) == []


@pytest.mark.parametrize("name, content", [("notes.db", b"not a zip"), ("broken.zip", b"not a zip"), ("other.zip", None)])
def test_unsupported_import_files_get_a_clear_message(tmp_path, name, content):
    service = LocalAnalysisService(tmp_path / "workspace", inline=True)
    path = tmp_path / name
    if content is None:
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("readme.txt", "unrelated")
    else:
        path.write_bytes(content)
    with TestClient(create_desktop_app(service, token="t", state_dir=tmp_path / "settings"), headers={"X-CKD-Token": "t"}) as api:
        response = api.post("/api/import", json={"path": str(path)})
    assert response.status_code == 422
    assert "not a CKD export" in response.json()["detail"]
    assert hidden_staging(service.root) == []
