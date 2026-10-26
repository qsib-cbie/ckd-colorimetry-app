import copy
import io
import shutil
import threading
import time
from pathlib import Path
from unittest.mock import Mock

import pytest
from fastapi.testclient import TestClient

from ckd.desktop import create_desktop_app
from ckd.local import LocalAnalysisService
from ckd.projects import ProjectStore
from ckd.projects.utils import project_key
from utils import FIXTURES, assert_swift_concentrations, swift_draft, swift_reference


@pytest.fixture
def desktop(tmp_path):
    service = LocalAnalysisService(tmp_path / "workspace", inline=True)
    app = create_desktop_app(service, token="test-desktop-token", state_dir=tmp_path / "settings")
    with TestClient(app, headers={"X-CKD-Token": "test-desktop-token"}) as api:
        yield api, service


def test_private_api_launch_cookie_and_origins(tmp_path):
    app = create_desktop_app(token="private-token", state_dir=tmp_path)
    with TestClient(app) as api:
        assert api.get("/api/ready").status_code == 403
        assert api.get("/launch/private-token", follow_redirects=False).status_code == 303
        assert api.get("/api/ready").json()["mode"] == "desktop"
        assert api.get("/launch/private-token").status_code == 403
        assert api.post("/api/workspace", headers={"Origin": "https://unrelated.example"}, json={"path": str(tmp_path)}).status_code == 403


def test_workspace_and_native_folder_operations(desktop, tmp_path):
    api, service = desktop
    assert api.get("/api/workspace").json()["root"] == str(service.root)
    assert api.post("/api/folders", json={"name": "Study A"}).json()["path"] == "Study A"
    assert api.post("/api/folders/move", json={"path": "Study A", "name": "Study B"}).status_code == 200
    assert api.get("/api/library").json()["folders"][0]["name"] == "Study B"
    assert api.post("/api/folders", json={"name": "Bad", "parent": "../outside"}).status_code == 422
    opened = api.post("/api/workspace", json={"path": str(tmp_path / "second")})
    assert opened.status_code == 200
    assert str(tmp_path / "second") in opened.json()["recent"]


def test_recent_workspaces_report_home_and_missing_folders(desktop, tmp_path):
    api, _ = desktop
    for name in ("gone", "kept"):
        assert api.post("/api/workspace", json={"path": str(tmp_path / name)}).status_code == 200
    (tmp_path / "gone").rename(tmp_path / "renamed")
    info = api.get("/api/workspace").json()
    assert info["home"] == str(Path.home())
    assert info["missing"] == [str(tmp_path / "gone")]
    forgotten = api.post("/api/workspace/forget", json={"path": str(tmp_path / "gone")}).json()
    assert str(tmp_path / "gone") not in forgotten["recent"]
    assert forgotten["recent"][0] == str(tmp_path / "kept")


def test_two_engines_cannot_open_the_same_workspace(tmp_path):
    first = LocalAnalysisService(tmp_path)
    try:
        with pytest.raises(ValueError, match="already open"):
            LocalAnalysisService(tmp_path)
    finally:
        first.close()
    LocalAnalysisService(tmp_path).close()


@pytest.mark.parametrize("failure", ["occupied", "not-directory", "settings"])
def test_failed_workspace_switch_preserves_current_workspace(desktop, tmp_path, monkeypatch, failure):
    api, service = desktop
    target = tmp_path / "unavailable"
    occupied = None
    if failure == "occupied":
        occupied = LocalAnalysisService(target)
    elif failure == "not-directory":
        target.write_text("not a workspace")
    else:
        monkeypatch.setattr("ckd.desktop.atomic_json", Mock(side_effect=OSError("settings are read-only")))
    try:
        response = api.post("/api/workspace", json={"path": str(target)})
        assert response.status_code in (409, 422)
        assert api.get("/api/workspace").json()["root"] == str(service.root)
        assert not service.closed
        with pytest.raises(ValueError, match="already open"):
            LocalAnalysisService(service.root)
        assert api.post("/api/folders", json={"name": "Still editable"}).status_code == 200
        if failure == "settings":
            LocalAnalysisService(target).close()
    finally:
        if occupied:
            occupied.close()


def test_workspace_opens_when_an_interrupted_job_cannot_be_rewritten(tmp_path, monkeypatch):
    service = LocalAnalysisService(tmp_path, inline=True)
    doc = service.create("sample.dng", io.BytesIO(b"raw"))
    doc["job"] = {"status": "running", "id": "interrupted", "action": "render"}
    service.store.replace(doc, doc["revision"])
    service.close()
    with monkeypatch.context() as patch:
        patch.setattr(ProjectStore, "replace", Mock(side_effect=OSError("disk unavailable")))
        unwritable = LocalAnalysisService(tmp_path)
        try:
            assert unwritable.fetch(doc["id"])["job"]["status"] == "failed"
        finally:
            unwritable.close()
    reopened = LocalAnalysisService(tmp_path)
    assert reopened.store.get(doc["id"])["job"]["status"] == "failed"
    reopened.close()


@pytest.mark.parametrize("failure", ["empty", "oversize", "read", "metadata"])
def test_rejected_uploads_leave_no_visible_analysis(desktop, tmp_path, monkeypatch, failure):
    _, service = desktop
    discarded = tmp_path / "discarded-upload"
    monkeypatch.setattr("ckd.projects.utils.trash_path", lambda path: shutil.move(str(path), discarded))
    if failure == "empty":
        stream = io.BytesIO(b"")
    elif failure == "oversize":
        stream = Mock(read=Mock(side_effect=[b"x" * (1024 * 1024)] * 101))
    elif failure == "read":
        stream = Mock(read=Mock(side_effect=[b"partial original", OSError("source unavailable")]))
    else:
        stream = io.BytesIO(b"original")
        monkeypatch.setattr("ckd.projects.store.atomic_json", Mock(side_effect=OSError("disk unavailable")))
    with pytest.raises((ValueError, OSError)):
        service.create("broken.dng", stream)
    library = service.store.library()
    assert library["analyses"] == [] and library["folders"] == [] and library["problems"] == []
    assert not list(service.root.glob(".import-*"))
    assert (discarded / "original" / "broken.dng").exists()


def test_upload_publishes_complete_project_without_overwriting_a_namesake(desktop, monkeypatch):
    _, service = desktop
    first = service.create("sample.dng", io.BytesIO(b"first original"))
    rename = type(service.root).rename
    observed = []
    def check_publication(staged, destination):
        if staged.name.startswith(".import-"):
            document = service.store.get(project_key(staged.relative_to(service.root).as_posix()))
            observed.append(document["source"]["bytes"])
            assert (staged / document["source"]["file"]).read_bytes() == b"second original"
        return rename(staged, destination)
    monkeypatch.setattr(type(service.root), "rename", check_publication)
    second = service.create("sample.dng", io.BytesIO(b"second original"))
    assert observed == [len(b"second original")]
    assert first["project_path"] == "sample" and second["project_path"] == "sample (2)"
    assert (service.directory(first) / first["source"]["file"]).read_bytes() == b"first original"
    assert len(service.store.list()) == 2


def test_interrupted_job_is_recoverable_after_restart(tmp_path):
    service = LocalAnalysisService(tmp_path, inline=True)
    doc = service.create("sample.dng", io.BytesIO(b"raw"))
    doc["job"] = {"status": "running", "id": "interrupted", "action": "render"}
    service.store.replace(doc, doc["revision"])
    service.close()
    reopened = LocalAnalysisService(tmp_path, inline=True)
    try:
        recovered = reopened.fetch(doc["id"])
        assert recovered["job"]["status"] == "failed"
        assert "Retry" in recovered["job"]["error"]
    finally:
        reopened.close()


def test_background_worker_is_serial_and_api_stays_responsive(tmp_path, monkeypatch):
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
    try:
        service.enqueue(a["id"], 0, "render")
        assert started.wait(2)
        queued = service.enqueue(b["id"], 0, "render")
        assert calls == [a["id"]]
        assert service.fetch(b["id"])["job"]["status"] == "queued"
        release.set()
        service.pending[queued["job"]["id"]].result(timeout=5)
    finally:
        release.set()
        service.close()
    assert calls == [a["id"], b["id"]]


def test_modified_original_is_rejected(desktop):
    api, service = desktop
    doc = api.post("/api/analyses", files={"file": ("sample.dng", b"original")}).json()
    (service.directory(doc) / doc["source"]["file"]).write_bytes(b"modified")
    response = api.post(f"/api/analyses/{doc['id']}/jobs", json={"revision": 0, "action": "render"})
    assert response.json()["job"]["status"] == "failed"
    assert "original image changed" in response.json()["job"]["error"]


@pytest.mark.raw
def test_local_raw_pipeline_and_cache_recovery(desktop):
    api, service = desktop
    name = "_NOT_ACTUAL_TEST.dng"
    reference = swift_reference(name + ".json")
    reference["inputs"], reference["expected"] = reference["manual_inputs"], reference["manual_expected"]
    with (FIXTURES / name).open("rb") as source:
        response = api.post("/api/analyses", files={"file": (name, source)})
    response.raise_for_status()
    doc = response.json()
    base = f"/api/analyses/{doc['id']}"
    for action in ("render", "white_balance", "calibrate", "analyze"):
        if action == "white_balance":
            draft = swift_draft(reference["inputs"], reference["white_balance_polygon"]["points"])
            response = api.put(base, json={"revision": doc["revision"], "draft": draft})
            response.raise_for_status()
            doc = response.json()
        response = api.post(base + "/jobs", json={"revision": doc["revision"], "action": action})
        response.raise_for_status()
        doc = response.json()
        assert doc["job"]["status"] == "completed", doc["job"]
    assert_swift_concentrations(doc["results"], reference["expected"], same_lab=False)
    assert api.get(base + "/export").status_code == 200
    runs = list((service.directory(doc) / "runs").glob("run-*"))
    assert len(runs) == 1
    assert all((run / "analysis.json").exists() for run in runs)
    assert not [p for p in service.directory(doc).rglob("*") if p.suffix.lower() in (".zip", ".dng") and "original" not in p.parts]
    old_results = copy.deepcopy(doc["results"])
    cache = service.directory(doc) / ".cache"
    cache.rename(cache.with_name("previous-cache"))
    assert api.get(base + "/preview").status_code == 200
    assert service.fetch(doc["id"])["results"] == old_results
