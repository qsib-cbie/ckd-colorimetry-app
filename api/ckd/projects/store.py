import collections
import copy
import os
import uuid
from pathlib import Path

from ..utils import APP_VERSION, now
from .utils import (atomic_json, file_lock, inside, portable_document, project_key, publish_directory,
                    read_json, safe_name, trash_path, unique_directory, validate_document)


HISTORY_LIMIT = 20
HISTORY_KEYS = ("draft", "render", "white_balance", "calibration", "results")


class Conflict(ValueError):
    pass


def job_in_progress(document):
    return (document.get("job") or {}).get("status") in ("queued", "running")


class ProjectStore:
    filename = "analysis.ckd.json"

    def __init__(self, root):
        self.root = Path(root).expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.paths = {}
        self.active = job_in_progress

    def discover(self):
        projects, folders, problems = [], [], []
        for directory, children, files in os.walk(self.root, followlinks=False):
            path = Path(directory)
            children[:] = sorted(name for name in children if not name.startswith(".") and not (path / name).is_symlink())
            relative = path.relative_to(self.root).as_posix()
            if self.filename in files:
                children[:] = []
                key = project_key(relative)
                self.paths[key] = relative
                try:
                    projects.append(self.get(key))
                except (ValueError, OSError, KeyError) as exc:
                    problems.append({"path": relative, "error": str(exc)})
            elif relative != ".":
                parent = path.parent.relative_to(self.root).as_posix()
                folders.append({"id": relative, "name": path.name, "parent_id": None if parent == "." else parent})
        return projects, folders, problems

    def directory(self, key):
        if key not in self.paths:
            self.discover()
        if key not in self.paths:
            raise KeyError("Analysis not found. Refresh the folder after moving it in Finder.")
        path = inside(self.root, self.paths[key])
        if not (path / self.filename).is_file():
            raise KeyError("Analysis not found. Refresh the folder after moving it in Finder.")
        return path

    def get(self, key):
        path = self.directory(key)
        document = read_json(path / self.filename)
        validate_document(document)
        document["analysis_id"] = document["id"]
        document["id"] = key
        document["project_path"] = path.relative_to(self.root).as_posix()
        document["read_only"] = not os.access(path, os.W_OK)
        for artifact in (document["source"], document.get("render"), document.get("white_balance"), document.get("export")):
            if artifact:
                for name in ("file", "array", "preview"):
                    if artifact.get(name):
                        inside(path, artifact[name])
        return document

    def parent_directory(self, relative=None):
        path = inside(self.root, relative or ".")
        if not path.is_dir():
            raise ValueError("The destination folder no longer exists.")
        for parent in [path, *path.parents]:
            if not parent.is_relative_to(self.root):
                break
            if (parent / self.filename).exists():
                raise ValueError("Choose a workspace folder outside an existing analysis.")
        return path

    def allocate(self, name, parent=None):
        directory = unique_directory(self.parent_directory(parent), name)
        (directory / "original").mkdir()
        (directory / ".cache").mkdir()
        (directory / "runs").mkdir()
        return directory

    def create(self, document, directory):
        relative = directory.relative_to(self.root).as_posix()
        key = project_key(relative)
        target = inside(self.root, relative) / self.filename
        with file_lock(directory):
            if target.exists():
                raise Conflict("This analysis already exists.")
            value = {**portable_document(document), "saved_with": APP_VERSION}
            validate_document(value)
            atomic_json(target, value)
        self.paths[key] = relative
        return self.get(key)

    def publish(self, document, staged, name, parent=None):
        self.create(document, staged)
        destination = publish_directory(staged, self.parent_directory(parent), name)
        self.paths.clear()
        return self.get(project_key(destination.relative_to(self.root).as_posix()))

    def replace(self, document, expected_revision):
        path = self.directory(document["id"])
        with file_lock(path):
            current = self.get(document["id"])
            if current["revision"] != expected_revision:
                raise Conflict("This analysis changed elsewhere. Reload before saving.")
            if current["analysis_id"] != document.get("analysis_id", document["id"]):
                raise Conflict("The analysis folder was replaced. Reopen it before saving.")
            result = copy.deepcopy(document)
            result["revision"] = expected_revision + 1
            result["updated_at"] = now()
            value = {**portable_document(result), "saved_with": APP_VERSION}
            validate_document(value)
            self.remember(path, current, result)
            atomic_json(path / self.filename, value, backup=True)
        return self.get(document["id"])

    def remember(self, path, current, result):
        if all(current.get(key) == result.get(key) for key in HISTORY_KEYS):
            return
        history = path / ".history"
        history.mkdir(exist_ok=True)
        atomic_json(history / f"rev-{current['revision']:06d}.json", portable_document(current))
        for stale in sorted(history.glob("rev-*.json"))[:-HISTORY_LIMIT]:
            stale.unlink(missing_ok=True)

    def history(self, key):
        versions = []
        for entry in sorted((self.directory(key) / ".history").glob("rev-*.json"), reverse=True):
            try:
                document = read_json(entry)
                validate_document(document)
                versions.append(document)
            except (ValueError, OSError):
                continue
        return versions

    def restore(self, relative):
        path = inside(self.root, relative)
        if not path.is_dir():
            raise ValueError("The analysis folder no longer exists.")
        candidates = [path / ".analysis.previous.json", *sorted((path / ".history").glob("rev-*.json"), reverse=True)]
        for candidate in candidates:
            try:
                document = read_json(candidate)
                validate_document(document)
            except (ValueError, OSError):
                continue
            with file_lock(path):
                target = path / self.filename
                if target.exists():
                    target.rename(path / f".analysis.unreadable-{uuid.uuid4().hex[:8]}.json")
                atomic_json(target, document)
            self.paths.clear()
            return {"path": relative}
        raise ValueError("No earlier readable version of this analysis was found.")

    def reassign_id(self, key):
        path = self.directory(key)
        with file_lock(path):
            current = self.get(key)
            if self.active(current):
                raise Conflict("A calculation is active. Wait before changing this analysis ID.")
            previous = current["analysis_id"]
            current.update(analysis_id=str(uuid.uuid4()), revision=current["revision"] + 1, updated_at=now(),
                           copied_from={"analysis_id": previous, "copied_at": now()})
            value = {**portable_document(current), "saved_with": APP_VERSION}
            validate_document(value)
            atomic_json(path / self.filename, value, backup=True)
        return self.get(key)

    def list(self):
        projects, _, _ = self.discover()
        return sorted(projects, key=lambda item: item["updated_at"], reverse=True)

    def library(self):
        projects, folders, problems = self.discover()
        counts = collections.Counter(doc["analysis_id"] for doc in projects)
        return {"root": str(self.root), "folders": folders, "analyses": [
            {**{key: doc[key] for key in ("id", "analysis_id", "project_path", "draft", "source", "updated_at", "job", "read_only")},
             "duplicate_id": counts[doc["analysis_id"]] > 1}
            for doc in projects
        ], "problems": problems}

    def create_folder(self, name, parent=None):
        path = unique_directory(self.parent_directory(parent), name)
        return {"path": path.relative_to(self.root).as_posix()}

    def assert_idle(self, path):
        projects, _, problems = self.discover()
        for problem in problems:
            if inside(self.root, problem["path"]).is_relative_to(path):
                raise Conflict("Repair the unreadable analysis before moving this folder.")
        for doc in projects:
            if self.directory(doc["id"]).is_relative_to(path) and self.active(doc):
                raise Conflict("A calculation is active. Wait before moving or deleting this folder.")

    def find_job(self, job_id):
        projects, _, _ = self.discover()
        for doc in projects:
            if (doc.get("job") or {}).get("id") == job_id:
                return doc
        raise KeyError("Analysis not found. Refresh the folder after moving it in Finder.")

    def move(self, relative, name, parent=None):
        source = inside(self.root, relative)
        if source == self.root:
            raise ValueError("Move the workspace itself using Finder after closing it.")
        if not source.is_dir():
            raise ValueError("The folder no longer exists.")
        self.parent_directory(source.parent.relative_to(self.root))
        destination = self.parent_directory(parent) / safe_name(name)
        if destination == source:
            return {"path": relative, "id": project_key(relative)}
        if destination.is_relative_to(source):
            raise ValueError("A folder cannot contain itself.")
        self.assert_idle(source)
        if destination.exists():
            raise Conflict("A folder with this name already exists.")
        source.rename(destination)
        self.paths.clear()
        relative = destination.relative_to(self.root).as_posix()
        return {"path": relative, "id": project_key(relative)}

    def trash(self, relative):
        source = inside(self.root, relative)
        if source == self.root or not source.is_dir():
            raise ValueError("Select a folder inside the workspace.")
        self.parent_directory(source.parent.relative_to(self.root))
        self.assert_idle(source)
        trash_path(source)
        self.paths.clear()
