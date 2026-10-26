import copy
import io
import json
import shutil
import uuid
from pathlib import Path

import pytest

from ckd.models import Draft, Reservoir
from ckd.projects import Conflict, ProjectStore
from ckd.projects.utils import atomic_json, file_digest, inside


@pytest.fixture
def project(tmp_path):
    store = ProjectStore(tmp_path / "workspace")
    directory = store.allocate("Sample A")
    source = directory / "original" / "sample.dng"
    source.write_bytes(b"original RAW bytes")
    document = {
        "id": str(uuid.uuid4()), "revision": 0, "created_at": "2026-09-28", "updated_at": "2026-09-28",
        "source": {"filename": source.name, "file": "original/sample.dng", "sha256": file_digest(source)},
        "draft": Draft(reservoirs=[Reservoir(id=i) for i in range(1, 7)]).model_dump(),
        "render": None, "white_balance": None, "calibration": None, "results": None, "export": None, "job": None,
    }
    return store, store.create(document, directory)


def test_project_is_self_contained_and_copies_are_independent(project, tmp_path):
    store, doc = project
    first = store.directory(doc["id"])
    second = first.with_name("Sample B")
    shutil.copytree(first, second)
    copied_store = ProjectStore(store.root)
    projects = copied_store.list()
    assert len(projects) == 2
    assert len({item["id"] for item in projects}) == 2
    assert len({item["analysis_id"] for item in projects}) == 1
    second_doc = next(item for item in projects if item["project_path"] == "Sample B")
    second_doc["draft"]["title"] = "Independent copy"
    copied_store.replace(second_doc, second_doc["revision"])
    assert store.get(doc["id"])["draft"]["title"] != "Independent copy"
    external = tmp_path / "different-computer"
    shutil.copytree(second, external)
    opened = ProjectStore(external).list()[0]
    assert opened["draft"]["title"] == "Independent copy"
    assert file_digest(external / opened["source"]["file"]) == doc["source"]["sha256"]


def test_atomic_revisions_and_previous_save(project):
    store, doc = project
    stale = copy.deepcopy(doc)
    doc["draft"]["title"] = "Saved"
    updated = store.replace(doc, 0)
    assert updated["revision"] == 1
    with pytest.raises(Conflict):
        store.replace(stale, 0)
    previous = json.loads((store.directory(doc["id"]) / ".analysis.previous.json").read_text())
    assert previous["revision"] == 0
    assert "project_path" not in previous


def test_failed_atomic_write_preserves_last_save(project, monkeypatch):
    store, doc = project
    path = store.directory(doc["id"]) / store.filename
    original = path.read_bytes()
    from ckd.projects import utils
    def fail_replace(source, destination):
        raise OSError("disk unavailable")
    monkeypatch.setattr(utils.os, "replace", fail_replace)
    with pytest.raises(OSError):
        atomic_json(path, {"changed": True})
    assert path.read_bytes() == original


def test_folders_move_and_finder_rename(project):
    store, doc = project
    store.create_folder("Experiment A")
    result = store.move(doc["project_path"], "Renamed", "Experiment A")
    moved = store.get(result["id"])
    assert moved["analysis_id"] == doc["analysis_id"]
    assert moved["project_path"] == "Experiment A/Renamed"
    store.directory(moved["id"]).rename(store.root / "Finder name")
    refreshed = store.library()
    assert refreshed["analyses"][0]["project_path"] == "Finder name"
    assert refreshed["problems"] == []


@pytest.mark.parametrize("relative", ["../outside", "/tmp/outside", "Sample A/../../outside"])
def test_workspace_rejects_escaping_paths(project, relative):
    store, _ = project
    with pytest.raises(ValueError):
        inside(store.root, relative)


def test_symlinks_and_artifact_paths_are_rejected(project, tmp_path):
    store, doc = project
    (store.root / "link").symlink_to(tmp_path, target_is_directory=True)
    with pytest.raises(ValueError):
        store.create_folder("bad", "link")
    path = store.directory(doc["id"]) / store.filename
    value = json.loads(path.read_text())
    value["source"]["file"] = "../../secret"
    atomic_json(path, value)
    assert store.library()["problems"]


def test_busy_projects_cannot_be_moved_or_trashed(project):
    store, doc = project
    doc["job"] = {"status": "running"}
    store.replace(doc, doc["revision"])
    with pytest.raises(Conflict):
        store.move(doc["project_path"], "Busy")
    with pytest.raises(Conflict):
        store.trash(doc["project_path"])


def test_trash_moves_folder_without_deleting_data(project, tmp_path, monkeypatch):
    store, doc = project
    from ckd.projects import store as module
    destination = tmp_path / "trash" / "Sample A"
    destination.parent.mkdir()
    monkeypatch.setattr(module, "trash_path", lambda path: shutil.move(str(path), destination))
    store.trash(doc["project_path"])
    assert store.list() == []
    assert (destination / doc["source"]["file"]).read_bytes() == b"original RAW bytes"


def test_folder_operations_cannot_modify_project_internals(project):
    store, doc = project
    with pytest.raises(ValueError):
        store.create_folder("nested", doc["project_path"])
    with pytest.raises(ValueError):
        store.move(doc["project_path"] + "/original", "renamed")
    with pytest.raises(ValueError):
        store.trash(doc["project_path"] + "/original")


def test_unknown_schema_is_reported_without_modification(project):
    store, doc = project
    path = store.directory(doc["id"]) / store.filename
    value = json.loads(path.read_text())
    value["schema_version"] = 999
    atomic_json(path, value)
    before = path.read_bytes()
    assert "Unsupported project" in store.library()["problems"][0]["error"]
    assert path.read_bytes() == before
