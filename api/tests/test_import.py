import hashlib
import json
import zipfile

import pytest

from ckd.projects import ProjectStore
from ckd.projects.importer import ExportImporter
from test_projects import project


def test_imported_document_preserves_original_results_and_review(project, tmp_path):
    store, doc = project
    doc["results"] = {"saved": [1, 2, 3]}
    doc["draft"]["reservoirs"][0]["review"] = "excluded"
    before = (store.directory(doc["id"]) / doc["source"]["file"]).read_bytes()
    destination = ProjectStore(tmp_path / "imported")
    imported = ExportImporter(destination).import_document(doc, store.directory(doc["id"]))
    assert imported["results"] == doc["results"]
    assert imported["draft"] == doc["draft"]
    assert imported["analysis_id"] == doc["analysis_id"]
    assert (destination.directory(imported["id"]) / imported["source"]["file"]).read_bytes() == before
    assert (store.directory(doc["id"]) / doc["source"]["file"]).read_bytes() == before
    assert "owner_id" not in imported


def test_missing_caches_do_not_discard_imported_results(project, tmp_path):
    store, doc = project
    doc["results"] = {"saved": True}
    doc["render"] = {"array": "missing.npy", "preview": "missing.png"}
    doc["job"] = {"status": "running"}
    imported = ExportImporter(ProjectStore(tmp_path / "imported")).import_document(doc, store.directory(doc["id"]))
    assert imported["render"]["array"] == ".cache/missing.npy"
    assert imported["results"] == {"saved": True}
    assert imported["job"]["status"] == "failed"


def test_corrupt_original_is_not_imported(project, tmp_path):
    store, doc = project
    doc["source"]["sha256"] = "wrong"
    target = ProjectStore(tmp_path / "imported")
    with pytest.raises(ValueError, match="hash"):
        ExportImporter(target).import_document(doc, store.directory(doc["id"]))
    assert target.list() == []


def test_export_zip_import_verifies_manifest(project, tmp_path):
    store, doc = project
    payloads = {"analysis.json": json.dumps(doc).encode(), "original/sample.dng": b"original RAW bytes"}
    archive = tmp_path / "export.zip"
    manifest = {"schema_name": "ckd_web_export", "schema_version": 1,
                "files": {name: hashlib.sha256(data).hexdigest() for name, data in payloads.items()}}
    with zipfile.ZipFile(archive, "w") as output:
        for name, data in payloads.items():
            output.writestr(name, data)
        output.writestr("manifest.json", json.dumps(manifest))
    target = ProjectStore(tmp_path / "imported")
    imported = ExportImporter(target).import_zip(archive)
    assert imported["source"]["sha256"] == doc["source"]["sha256"]
    with zipfile.ZipFile(archive, "a") as output:
        output.writestr("../escape", "bad")
    with pytest.raises(ValueError, match="unsafe"):
        ExportImporter(target).import_zip(archive)
