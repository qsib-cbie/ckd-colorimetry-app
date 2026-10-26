import copy
import json
import shutil
import stat
import tempfile
import zipfile
from pathlib import Path

from .utils import (archive_names, atomic_json, copy_file, file_digest, inside, portable_document,
                    project_staging, validate_document)


class ExportImporter:
    def __init__(self, store):
        self.store = store

    def import_document(self, document, source_root, source_name=None, parent=None, extras=None):
        document = copy.deepcopy(document)
        source_root = Path(source_root).resolve()
        source = inside(source_root, source_name or document["source"]["file"])
        if file_digest(source) != document["source"]["sha256"]:
            raise ValueError("The original image hash does not match the saved analysis.")
        original = "original/" + Path(document["source"]["filename"].replace("\\", "/")).name
        document["source"]["file"] = original
        document["analysis_id"] = document.get("analysis_id", document["id"])
        for key in ("owner_id", "access"):
            document.pop(key, None)
        caches = []
        for field in ("render", "white_balance"):
            if document.get(field):
                for key in ("array", "preview"):
                    old = document[field][key]
                    new = ".cache/" + Path(old).name
                    caches.append((inside(source_root, old), new))
                    document[field][key] = new
        export = None
        if document.get("export"):
            old = document["export"]["file"]
            export = inside(source_root, old)
            if export.is_file():
                document["export"]["file"] = "runs/imported-0001/" + Path(old).name
            else:
                document["export"], export = None, None
        if (document.get("job") or {}).get("status") in ("queued", "running"):
            document["job"].update(status="failed", error="This job was interrupted before import. Retry the calculation.")
        validate_document(portable_document(document))
        with project_staging(self.store.parent_directory(parent)) as staged:
            copy_file(source, staged / original)
            for candidate, new in caches:
                if candidate.exists():
                    copy_file(candidate, staged / new)
            if export:
                copy_file(export, staged / document["export"]["file"])
            snapshot = staged / "runs" / "imported-0001"
            snapshot.mkdir(parents=True, exist_ok=True)
            atomic_json(snapshot / "analysis.json", portable_document(document))
            if document.get("results") is not None:
                atomic_json(snapshot / "results.json", document["results"])
            for name, candidate in (extras or {}).items():
                if name not in ("analysis.json", "results.json", "manifest.json") and not name.startswith("original/"):
                    copy_file(candidate, inside(snapshot, name))
            atomic_json(snapshot / "manifest.json", {
                "schema_name": "ckd_imported_run", "schema_version": 1,
                "source_sha256": document["source"]["sha256"],
                "files": {p.relative_to(snapshot).as_posix(): file_digest(p) for p in snapshot.rglob("*") if p.is_file()},
            })
            return self.store.publish(document, staged, document["draft"]["title"], parent)

    def import_zip(self, path, parent=None):
        with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory(prefix="ckd-import-") as temporary:
            staged = Path(temporary)
            names = archive_names((i.filename, i.file_size, not i.is_dir() and not stat.S_ISLNK(i.external_attr >> 16)) for i in archive.infolist())
            manifest = json.loads(archive.read("manifest.json"))
            if manifest.get("schema_name") not in ("ckd_export", "ckd_web_export") or manifest.get("schema_version") != 1:
                raise ValueError("Choose a CKD result ZIP containing an original image and analysis.json.")
            if names != set(manifest["files"]) | {"manifest.json"}:
                raise ValueError("The export manifest does not match its contents.")
            for name, expected in manifest["files"].items():
                destination = inside(staged, name)
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as incoming, destination.open("xb") as output:
                    shutil.copyfileobj(incoming, output, 1024 * 1024)
                if file_digest(destination) != expected:
                    raise ValueError(f"Export checksum mismatch: {name}")
            document = json.loads((staged / "analysis.json").read_text())
            return self.import_document(document, staged, "original/" + document["source"]["filename"], parent,
                                        {name: staged / name for name in manifest["files"]})
