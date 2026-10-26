import copy
import fcntl
import hashlib
import json
import os
import re
import tempfile
import uuid
import shutil
from contextlib import contextmanager
from pathlib import Path

from .. import __version__ as APP_VERSION


def safe_name(value):
    name = re.sub(r'[\x00-\x1f/:\\]', "-", str(value)).strip().strip(".")[:120]
    if not name:
        raise ValueError("Enter a folder name.")
    return name


def inside(root, relative):
    root = Path(root).resolve()
    value = Path(relative)
    if value.is_absolute() or ".." in value.parts:
        raise ValueError("Choose a path inside the open workspace.")
    candidate = root / value
    for part in [candidate, *candidate.parents]:
        if part == root:
            break
        if part.is_symlink():
            raise ValueError("Symbolic links are not supported inside projects.")
    if not candidate.resolve().is_relative_to(root):
        raise ValueError("Choose a path inside the open workspace.")
    return candidate


def project_key(relative):
    return uuid.uuid5(uuid.NAMESPACE_URL, "ckd-project:" + str(relative)).hex


def read_json(path):
    if path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("Project metadata is too large.")
    try:
        return json.loads(path.read_text())
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"Cannot read {path.name}. Restore the last valid project backup.") from exc


def atomic_json(path, value, backup=False):
    payload = json.dumps(value, indent=2, allow_nan=False).encode() + b"\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    if backup and path.exists():
        atomic_json(path.with_name(".analysis.previous.json"), read_json(path))
    with tempfile.NamedTemporaryFile(prefix=".ckd-save-", dir=path.parent, delete=False) as output:
        output.write(payload)
        output.flush()
        os.fsync(output.fileno())
        temporary = Path(output.name)
    os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextmanager
def file_lock(directory, name=".ckd.lock", blocking=True):
    descriptor = os.open(directory / name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield
    finally:
        os.close(descriptor)


def unique_directory(parent, name):
    name = safe_name(name)
    for suffix in range(10000):
        candidate = parent / (name if suffix == 0 else f"{name} ({suffix + 1})")
        try:
            candidate.mkdir()
            return candidate
        except FileExistsError:
            continue
    raise ValueError("Too many folders have this name.")


def portable_document(document):
    result = copy.deepcopy(document)
    result["id"] = result.get("analysis_id", result["id"])
    result["analysis_id"] = result["id"]
    result["schema_name"], result["schema_version"] = "ckd_project", 1
    for key in ("project_path", "read_only"):
        result.pop(key, None)
    return result


def version_tuple(value):
    try:
        return tuple(int(part) for part in str(value).split(".")[:3])
    except ValueError:
        return ()


def validate_document(document):
    try:
        check_document(document)
    except ValueError as exc:
        saved_with = document.get("saved_with")
        if saved_with and version_tuple(saved_with) > version_tuple(APP_VERSION):
            raise ValueError(f"This analysis was saved by CKD Colorimetry {saved_with}. "
                             "Update this app to open it.") from exc
        raise


def check_document(document):
    if document.get("schema_name") != "ckd_project" or document.get("schema_version") != 1:
        raise ValueError("Unsupported project version. Open this folder with a compatible CKD app.")
    required = ("id", "revision", "source", "draft", "created_at", "updated_at")
    if any(key not in document for key in required) or not isinstance(document["revision"], int):
        raise ValueError("The project metadata is incomplete.")
    from ..models import Draft
    Draft.model_validate(document["draft"])
    paths = [document["source"].get("file", "")]
    for name in ("render", "white_balance"):
        if document.get(name):
            paths.extend(document[name].get(key, "") for key in ("array", "preview"))
    if document.get("export"):
        paths.append(document["export"].get("file", ""))
    for value in paths:
        path = Path(value)
        if not value or path.is_absolute() or ".." in path.parts:
            raise ValueError("The project contains an invalid artifact path.")


def file_digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def trash_path(path):
    from send2trash import send2trash
    send2trash(str(path))


def copy_file(source, destination):
    if source.is_symlink() or not source.is_file():
        raise ValueError(f"Missing or unsupported source file: {source.name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as incoming, destination.open("xb") as output:
        shutil.copyfileobj(incoming, output, 1024 * 1024)


@contextmanager
def project_staging(parent, prefix=".import-"):
    path = parent / (prefix + uuid.uuid4().hex)
    path.mkdir()
    try:
        yield path
    finally:
        if path.exists():
            trash_path(path)


def write_raw(stream, destination, limit=100 * 1024 * 1024):
    total = 0
    with destination.open("xb") as output:
        while chunk := stream.read(1024 * 1024):
            total += len(chunk)
            if total > limit:
                raise ValueError("Maximum RAW file size is 100 MB.")
            output.write(chunk)
        if not total:
            raise ValueError("The image is empty.")
        output.flush()
        os.fsync(output.fileno())
    return total


def publish_directory(staged, parent, name):
    destination = unique_directory(parent, name)
    try:
        staged.rename(destination)
    except BaseException:
        trash_path(destination)
        raise
    return destination


def archive_names(entries):
    names = set()
    total = 0
    for name, size, regular in entries:
        path = Path(name)
        if name in names or not regular or path.is_absolute() or ".." in path.parts or "\\" in name:
            raise ValueError("The archive contains duplicate or unsafe paths.")
        names.add(name)
        total += size
        if size > 1024 ** 3 or total > 4 * 1024 ** 3:
            raise ValueError("The archive exceeds the supported import size.")
    return names
