import copy
import hashlib
import os
import shutil
import sys
import tempfile
import threading
import traceback
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

from .models import Draft, Reservoir
from .projects import Conflict, ProjectStore
from .projects.store import job_in_progress
from .projects.utils import (atomic_json, copy_file, file_digest, file_lock, inside, portable_document, project_staging,
                             safe_name, write_raw)
from .service import AnalysisEngine, export_identity, failure_message, json_bytes, write_raster
from .utils import JPEG_XL_MESSAGE, coordinate_package, dng_uses_jpeg_xl, export_tables, now, render_raw, white_balance

INTERRUPTED = "Processing was interrupted. Retry the calculation."
SPACE_MARGIN = 32 * 1024 * 1024


def report_worker_failure(future):
    if not future.cancelled() and future.exception():
        traceback.print_exception(future.exception(), file=sys.stderr)


class LocalAnalysisService(AnalysisEngine):
    def __init__(self, data_dir, inline=False):
        self.store = ProjectStore(data_dir)
        self.root = self.store.root
        self.lease = file_lock(self.root, ".ckd-workspace.lock", blocking=False)
        try:
            self.lease.__enter__()
        except BlockingIOError as exc:
            raise ValueError("This workspace is already open in another CKD process.") from exc
        self.closed = False
        self.inline = inline
        self.pending = {}
        self.failures = {}
        self.cache_locks = {}
        self.guard = threading.RLock()
        self.store.active = self.job_active
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ckd-analysis")
        try:
            self.recover_jobs()
        except BaseException:
            self.close()
            raise

    def directory(self, doc):
        return self.store.directory(doc["id"])

    def close(self):
        if not self.closed:
            self.worker.shutdown(wait=True, cancel_futures=True)
            self.lease.__exit__(None, None, None)
            self.closed = True

    def recover_jobs(self):
        for doc in self.store.list():
            if job_in_progress(doc):
                doc["job"].update(status="failed", finished_at=now(), error=INTERRUPTED)
                try:
                    self.store.replace(doc, doc["revision"])
                except (OSError, ValueError, KeyError):
                    traceback.print_exc()

    def job_active(self, doc):
        if not job_in_progress(doc):
            return False
        with self.guard:
            future = self.pending.get(doc["job"].get("id"))
            return future is not None and not future.done()

    def fetch(self, analysis_id):
        return self.settle(self.store.get(analysis_id))

    def settle(self, doc):
        if not job_in_progress(doc) or self.job_active(doc):
            return doc
        with self.guard:
            current = self.store.get(doc["id"])
            if not job_in_progress(current) or self.job_active(current):
                return current
            current["job"].update(status="failed", finished_at=now(),
                                  error=self.failures.get(current["job"].get("id"), INTERRUPTED))
            try:
                return self.store.replace(current, current["revision"])
            except (OSError, ValueError, KeyError):
                traceback.print_exc()
                return current

    def locate(self, analysis_id, job_id):
        try:
            return self.store.get(analysis_id)
        except KeyError:
            return self.store.find_job(job_id)

    def require_space(self, doc, action):
        pixels = (doc["source"].get("width") or 0) * (doc["source"].get("height") or 0)
        rasters = {"render": 7 * pixels or 6 * doc["source"].get("bytes", 0), "white_balance": 7 * pixels,
                   "recompute": 14 * pixels if doc["results"] and self.comparison(doc)["needs_remeasure"] else 0}
        needed = rasters.get(action, 0) + SPACE_MARGIN
        free = shutil.disk_usage(self.directory(doc)).free
        if free < needed:
            raise ValueError(f"Not enough free disk space for this calculation: about {needed // 2**20} MB needed, "
                             f"{free // 2**20} MB available. Free some space and retry.")

    def create(self, filename, stream, parent=None):
        filename = Path(filename.replace("\\", "/")).name
        if Path(filename).suffix.lower() not in (".dng", ".cr2"):
            raise ValueError("Import an original DNG or CR2 file.")
        with project_staging(self.store.parent_directory(parent)) as directory:
            for name in ("original", ".cache", "runs"):
                (directory / name).mkdir()
            source = directory / "original" / filename
            total = write_raw(stream, source)
            if dng_uses_jpeg_xl(source):
                raise ValueError(JPEG_XL_MESSAGE)
            doc = {
                "id": str(uuid.uuid4()), "revision": 0, "created_at": now(), "updated_at": now(),
                "source": {"filename": filename, "file": "original/" + filename, "sha256": file_digest(source), "bytes": total},
                "draft": Draft(title=Path(filename).stem, mode="flower_9_manual", reservoirs=[Reservoir(id=i) for i in range(1, 7)]).model_dump(),
                "render": None, "white_balance": None, "calibration": None, "results": None, "export": None, "job": None,
            }
            return self.store.publish(doc, directory, Path(filename).stem, parent)

    def duplicate(self, analysis_id):
        doc = self.fetch(analysis_id)
        if self.job_active(doc):
            raise Conflict("A calculation is active. Duplicate the analysis when it finishes.")
        directory = self.directory(doc)
        parent = Path(doc["project_path"]).parent.as_posix()
        parent = None if parent == "." else parent
        duplicate = copy.deepcopy(doc)
        for key in ("project_path", "read_only", "job_history"):
            duplicate.pop(key, None)
        duplicate.update(analysis_id=str(uuid.uuid4()), revision=0, created_at=now(), updated_at=now(), job=None,
                         export=None, copied_from={"analysis_id": doc["analysis_id"], "title": doc["draft"]["title"],
                                                   "copied_at": now()})
        duplicate["id"] = duplicate["analysis_id"]
        duplicate["draft"]["title"] = (doc["draft"]["title"] + " copy")[:120]
        with project_staging(self.store.parent_directory(parent)) as staged:
            paths = [doc["source"]["file"]] + [raster[key] for raster in (doc["render"], doc["white_balance"])
                                                if raster for key in ("array", "preview")]
            for relative in paths:
                source = inside(directory, relative)
                if source.is_file():
                    copy_file(source, inside(staged, relative))
            for name in ("runs", ".cache"):
                (staged / name).mkdir(exist_ok=True)
            return self.store.publish(duplicate, staged, duplicate["draft"]["title"], parent)

    def rename(self, analysis_id, title):
        title = title.strip()
        name = safe_name(title)
        doc = self.fetch(analysis_id)
        if self.job_active(doc):
            raise Conflict("A calculation is active. Rename the analysis when it finishes.")
        saved = self.save(analysis_id, doc["revision"], {**doc["draft"], "title": title})
        relative = Path(saved["project_path"])
        parent = None if relative.parent == Path(".") else relative.parent.as_posix()
        target = self.store.parent_directory(parent)
        candidate = name
        for suffix in range(2, 1000):
            if candidate == relative.name or not (target / candidate).exists():
                break
            candidate = f"{name} ({suffix})"
        return self.store.move(relative.as_posix(), candidate, parent)

    def enqueue(self, analysis_id, revision, action):
        with self.guard:
            doc = self.fetch(analysis_id)
            self.editable(doc, revision)
            if action not in ("render", "white_balance", "calibrate", "analyze", "recompute"):
                raise ValueError("Unknown calculation.")
            if action == "recompute" and not doc["results"]:
                raise ValueError("Analyze before recomputing results.")
            if action != "render" and not doc["render"]:
                raise ValueError("Render the RAW image first.")
            if action == "white_balance" and not doc["draft"]["white_balance"]:
                raise ValueError("Draw a white-balance polygon first.")
            if action == "calibrate" and not doc["white_balance"]:
                raise ValueError("Apply white balance before calibration.")
            if action == "analyze" and (not doc["calibration"] or not doc["draft"]["rois"]):
                raise ValueError("Calibrate and draw at least one ROI before analyzing.")
            self.require_space(doc, action)
            job_id = uuid.uuid4().hex
            doc["job"] = {"id": job_id, "action": action, "status": "queued", "queued_at": now(), "error": None}
            doc = self.store.replace(doc, revision)
            if self.inline:
                self.run(doc["id"], job_id)
            else:
                self.pending = {key: future for key, future in self.pending.items() if not future.done()}
                future = self.worker.submit(self.run, doc["id"], job_id)
                future.add_done_callback(report_worker_failure)
                self.pending[job_id] = future
            return self.fetch(doc["id"])

    def save_raster(self, directory, name, image, timings=None):
        (directory / ".cache").mkdir(exist_ok=True)
        return super().save_raster(directory, ".cache/" + Path(name).name, image, timings)

    def cached_image(self, doc, balanced=False):
        directory = self.directory(doc)
        raster = doc["white_balance"] if balanced else doc["render"]
        if not raster:
            raise ValueError("This image has not been processed yet.")
        path = inside(directory, raster["array"])
        preview = inside(directory, raster["preview"])
        with self.guard:
            lock = self.cache_locks.setdefault(str(path), threading.Lock())
        with lock:
            if preview.is_file():
                try:
                    image = np.load(path, mmap_mode="r", allow_pickle=False)
                    if image.ndim == 3 and image.shape[2] == 3 and image.dtype == np.uint8 and image.shape[:2] == (
                            doc["source"].get("height", image.shape[0]), doc["source"].get("width", image.shape[1])):
                        return image
                except (OSError, ValueError, EOFError):
                    pass
            source = inside(directory, doc["source"]["file"])
            if file_digest(source) != doc["source"]["sha256"]:
                raise ValueError("The original image changed. Restore the matching original before processing.")
            initial, meta = render_raw(source)
            if balanced:
                image, _ = white_balance(source, initial, meta["camera_whitebalance"], doc["draft"]["white_balance"])
            else:
                image = initial
            path.parent.mkdir(parents=True, exist_ok=True)
            preview.parent.mkdir(parents=True, exist_ok=True)
            write_raster(path, preview, image)
            return image

    def run(self, analysis_id, job_id):
        try:
            doc = self.locate(analysis_id, job_id)
        except KeyError:
            self.failures[job_id] = "The analysis folder moved before processing started. Retry the calculation."
            return
        if (doc.get("job") or {}).get("id") != job_id or doc["job"]["status"] != "queued":
            return
        try:
            directory = self.directory(doc)
            with file_lock(directory, ".ckd-processing.lock", blocking=False):
                source = inside(directory, doc["source"]["file"])
                if file_digest(source) != doc["source"]["sha256"]:
                    raise ValueError("The original image changed. Restore it before processing.")
                if doc["job"]["action"] != "render":
                    self.cached_image(doc, bool(doc["white_balance"]))
                    if doc["job"]["action"] == "white_balance":
                        self.cached_image(doc)
                super().run(doc["id"], job_id)
        except Exception as exc:
            self.failures[job_id] = message = failure_message(exc)
            try:
                saved = self.locate(doc["id"], job_id)
                if (saved.get("job") or {}).get("id") == job_id and job_in_progress(saved):
                    saved["job"].update(status="failed", finished_at=now(), error=message)
                    if saved["job"]["action"] == "analyze":
                        saved["results"], saved["export"] = doc["results"], doc["export"]
                    self.store.replace(saved, saved["revision"])
            except Exception:
                traceback.print_exc()

    def record_run(self, doc, previous):
        directory = self.directory(doc)
        runs = directory / "runs"
        runs.mkdir(exist_ok=True)
        identity = export_identity(doc)
        files = {
            "analysis.json": json_bytes({**portable_document(doc), "job": None, "export": None}),
            "results.json": json_bytes(doc["results"]),
            "coordinates.json": json_bytes(coordinate_package(doc)),
            **{name: text.encode() for name, text in export_tables(doc["results"], identity).items()},
        }
        if previous and previous != doc["results"]:
            files["previous_results.json"] = json_bytes(previous)
        with project_staging(runs, ".run-") as staged:
            for name, data in files.items():
                (staged / name).write_bytes(data)
            atomic_json(staged / "manifest.json", {
                "schema_name": "ckd_run_snapshot", "schema_version": 1, "created_at": now(),
                "analysis_id": doc["analysis_id"], "revision": doc["revision"],
                "source_sha256": doc["source"]["sha256"], "versions": doc["results"].get("versions", {}),
                "files": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()},
            })
            staged.rename(runs / f"run-{doc['revision']:06d}-{uuid.uuid4().hex[:8]}")

    def export_archive(self, analysis_id, include_rasters=True):
        doc = self.fetch(analysis_id)
        if not doc["results"]:
            raise ValueError("Analyze before exporting results.")
        if self.job_active(doc):
            raise Conflict("A calculation is active. Export when it finishes.")
        pixels = (doc["source"].get("width") or 0) * (doc["source"].get("height") or 0)
        needed = doc["source"].get("bytes", 0) + 4 * pixels + (8 * pixels if include_rasters else 0) + SPACE_MARGIN
        if shutil.disk_usage(tempfile.gettempdir()).free < needed:
            raise ValueError(f"Not enough free disk space to build this export: about {needed // 2**20} MB needed.")
        image = self.cached_image(doc, bool(doc["white_balance"]))
        initial = self.cached_image(doc) if include_rasters else None
        handle, name = tempfile.mkstemp(prefix="ckd-export-", suffix=".zip")
        os.close(handle)
        path = Path(name)
        try:
            self.export_bundle(doc, image, path, initial)
        except BaseException:
            path.unlink(missing_ok=True)
            raise
        return doc, path
