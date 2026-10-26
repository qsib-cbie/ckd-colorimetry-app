import copy
import errno
import hashlib
import io
import json
import os
import resource
import time
import zipfile

import numpy as np
from .models import Draft
from .projects import Conflict
from .projects.store import job_in_progress
from .projects.utils import inside, portable_document
from .utils import (
    PNG_COMPRESSION_LEVEL,
    calibrate,
    compare_results,
    coordinate_package,
    digest,
    export_compression,
    export_tables,
    import_coordinates,
    measure_rois,
    now,
    order_corners,
    patch_measurements_csv,
    refresh_concentrations,
    render_raw,
    reset_changed_reviews,
    rgba_chunks,
    rgba_digest,
    roi_measurements_csv,
    roi_overlay,
    save_png,
    timed_stage,
    validate_polygon,
    versions,
    white_balance,
)


def write_raster(array, preview, image, timings=None):
    with timed_stage(timings, "raster.npy_write"):
        partial = array.with_name(array.name + ".part")
        with partial.open("wb") as output:
            np.save(output, image, allow_pickle=False)
        os.replace(partial, array)
    partial = preview.with_name(preview.name + ".part")
    save_png(image, partial, timings)
    os.replace(partial, preview)


UREA_INPUTS = ("urea_ph_model", "urea_calibration")
RESULT_INPUTS = ("reservoirs", "age", "sex", "classifier_model", *UREA_INPUTS)
DRAFT_DEFAULTS = {"urea_ph_model": None, "urea_calibration": "lab", "classifier_model": None}


def stored_calibration(doc):
    return doc.get("calibration")


def reservoir_assignments(draft):
    return {r["id"]: (r["analyte"], r["roi_ids"]) for r in draft["reservoirs"] if r["analyte"] or r["roi_ids"]}


def failure_message(exc):
    if isinstance(exc, BlockingIOError):
        return "Another CKD process is processing this analysis. Retry when it finishes."
    if isinstance(exc, FileNotFoundError):
        return "Project files moved or disappeared during processing. Refresh the folders and retry."
    if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
        return "The disk is full. Free some space and retry the calculation."
    return str(exc)[:500] or type(exc).__name__


class AnalysisEngine:
    def job_active(self, doc):
        return job_in_progress(doc)

    def fetch(self, analysis_id):
        return self.store.get(analysis_id)

    def locate(self, analysis_id, job_id):
        return self.store.get(analysis_id)

    def persist(self, doc):
        try:
            return self.store.replace(doc, doc["revision"])
        except KeyError:
            located = self.locate(doc["id"], doc["job"]["id"])
            doc["id"] = located["id"]
            return self.store.replace(doc, doc["revision"])

    def editable(self, doc, revision):
        if doc["revision"] != revision:
            raise Conflict(
                "This analysis changed on disk. Reload before saving."
            )
        if self.job_active(doc):
            raise Conflict(
                "A calculation is active. Wait for it to finish before editing."
            )

    def validate_draft(self, draft, doc):
        width, height = doc["source"].get("width"), doc["source"].get("height")
        if width is None:
            raise ValueError("Render the RAW image before editing geometry.")
        polygons = [(r["label"], r["points"]) for r in draft["rois"]]
        polygons += [(f"Calibration patch {i + 1}", p) for i, p in enumerate(draft["manual_patches"])]
        if draft["white_balance"]:
            polygons.append(("White-balance area", draft["white_balance"]))
        if draft["corners"]:
            corners = order_corners(draft["corners"])[[0, 1, 3, 2]]
            polygons.append(("Marker corners", [{"x": float(x), "y": float(y)} for x, y in corners]))
        for label, p in polygons:
            try:
                validate_polygon(p, width, height)
            except ValueError as exc:
                raise ValueError(f"{label}: {exc}") from exc

    def save(self, analysis_id, revision, draft, imported=False):
        doc = self.fetch(analysis_id)
        self.editable(doc, revision)
        draft = Draft.model_validate(draft).model_dump()
        self.validate_draft(draft, doc)
        incoming = copy.deepcopy(draft)
        old = doc["draft"]
        wb_changed = imported or old["white_balance"] != draft["white_balance"]
        cal_changed = wb_changed or any(
            old[k] != draft[k] for k in ("mode", "corners", "manual_patches")
        )
        geometry_changed = (
            cal_changed
            or old["rois"] != draft["rois"]
            or reservoir_assignments(old) != reservoir_assignments(draft)
        )
        previous_reviews = {r["id"]: r["review"] for r in old["reservoirs"]}
        if geometry_changed:
            for r in draft["reservoirs"]:
                r["review"], r["reason"] = "needs_review", ""
        elif any(old.get(k, DRAFT_DEFAULTS[k]) != draft[k] for k in UREA_INPUTS) or any(
            r["analyte"] == "ph" and r["review"] != previous_reviews.get(r["id"])
            for r in draft["reservoirs"]
        ):
            for r in draft["reservoirs"]:
                if r["analyte"] == "urea":
                    r["review"], r["reason"] = "needs_review", ""
        before = copy.deepcopy(doc)
        restored = None if imported or not geometry_changed else self.restorable(doc, incoming)
        if restored:
            for key in ("render", "white_balance", "calibration", "results"):
                doc[key] = restored[key]
            doc["export"], doc["draft"] = None, incoming
            saved = self.store.replace(doc, revision)
            self.discard_rasters(before, saved)
            return saved
        if wb_changed:
            doc["white_balance"] = None
        if cal_changed:
            doc["calibration"] = None
        if geometry_changed:
            doc["results"] = None
        elif doc["results"] and any(old.get(k, DRAFT_DEFAULTS.get(k)) != draft[k] for k in RESULT_INPUTS):
            if compare_results(old, doc["results"])["affects_values"]:
                raise Conflict(
                    "These results were calculated with a different version. "
                    "Open Differences and recompute before changing reviews."
                )
            doc["results"] = refresh_concentrations(draft, doc["results"], stored_calibration(doc))
        if old != draft or imported:
            doc["export"] = None
        doc["draft"] = draft
        saved = self.store.replace(doc, revision)
        self.discard_rasters(before, saved)
        return saved

    def restorable(self, doc, draft):
        for version in self.store.history(doc["id"]):
            if version["draft"] == draft and version["source"]["sha256"] == doc["source"]["sha256"]:
                return version
        return None

    def import_package(self, analysis_id, revision, package):
        doc = self.fetch(analysis_id)
        self.editable(doc, revision)
        try:
            draft = import_coordinates(package, doc)
        except (KeyError, TypeError) as exc:
            raise ValueError(
                "The coordinate package is incomplete or malformed."
            ) from exc
        return self.save(analysis_id, revision, draft, imported=True)

    def save_raster(self, directory, name, image, timings=None):
        write_raster(directory / f"{name}.npy", directory / f"{name}.png", image, timings)
        return {"array": f"{name}.npy", "preview": f"{name}.png"}

    def run(self, analysis_id, job_id):
        doc = self.locate(analysis_id, job_id)
        if (
            not doc.get("job")
            or doc["job"]["id"] != job_id
            or doc["job"]["status"] != "queued"
        ):
            return
        doc["job"].update(status="running", started_at=now())
        doc = self.persist(doc)
        before = copy.deepcopy(doc)
        start = time.monotonic()
        timings = {}
        directory = artifact = None
        try:
            directory = self.directory(doc)
            source = directory / doc["source"]["file"]
            draft, action = doc["draft"], doc["job"]["action"]
            artifact = f"r{doc['revision']}-{action}"
            if action == "render":
                image, meta = render_raw(source, timings=timings)
                doc["render"] = {
                    **meta,
                    **self.save_raster(directory, artifact, image, timings),
                    "rgba8888_sha256": self.raster_digest(image, timings),
                }
                doc["source"].update(width=meta["width"], height=meta["height"])
                (
                    doc["white_balance"],
                    doc["calibration"],
                    doc["results"],
                    doc["export"],
                ) = None, None, None, None
            elif action == "white_balance":
                with timed_stage(timings, "raster.mmap_open"):
                    initial = np.load(
                        directory / doc["render"]["array"],
                        mmap_mode="r",
                        allow_pickle=False,
                    )
                image, meta = white_balance(
                    source,
                    initial,
                    doc["render"]["camera_whitebalance"],
                    draft["white_balance"],
                    timings=timings,
                )
                doc["white_balance"] = {
                    **meta,
                    **self.save_raster(directory, artifact, image, timings),
                    "rgba8888_sha256": self.raster_digest(image, timings),
                }
                doc["calibration"], doc["results"], doc["export"] = None, None, None
            else:
                raster = doc["white_balance"] or doc["render"]
                with timed_stage(timings, "raster.mmap_open"):
                    image = np.load(
                        directory / raster["array"], mmap_mode="r", allow_pickle=False
                    )
                if action == "calibrate":
                    with timed_stage(timings, "calibration"):
                        doc["calibration"] = calibrate(
                            image,
                            draft["mode"],
                            draft["corners"],
                            draft["manual_patches"],
                        )
                    doc["results"], doc["export"] = None, None
                elif action == "analyze":
                    with timed_stage(timings, "roi_measurements_and_concentrations"):
                        doc["results"] = measure_rois(image, draft, doc["calibration"])
                    doc["export"] = None
                    with timed_stage(timings, "run_snapshot"):
                        self.record_run(doc, before["results"])
                elif action == "recompute":
                    self.recompute(doc, directory, source, image, artifact, timings)
            doc["job"].update(
                status="completed",
                finished_at=now(),
                seconds=round(time.monotonic() - start, 3),
                process_peak_rss=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                rss_units="bytes" if os.uname().sysname == "Darwin" else "KiB",
            )
        except Exception as exc:
            doc = before
            doc["job"].update(
                status="failed",
                finished_at=now(),
                error=failure_message(exc),
            )
            if directory and artifact:
                self.discard_artifact(directory, artifact)
        doc["job"]["timings_seconds"] = {k: round(v, 6) for k, v in timings.items()}
        doc.setdefault("job_history", []).append(copy.deepcopy(doc["job"]))
        saved = self.persist(doc)
        self.discard_rasters(before, saved)

    def recompute(self, doc, directory, source, image, artifact, timings):
        draft, previous = doc["draft"], doc["results"]
        if compare_results(draft, previous)["needs_remeasure"]:
            image, meta = render_raw(source, timings=timings)
            doc["render"] = {
                **meta,
                **self.save_raster(directory, artifact + "-render", image, timings),
                "rgba8888_sha256": self.raster_digest(image, timings),
            }
            if doc["white_balance"]:
                image, meta = white_balance(
                    source, image, meta["camera_whitebalance"], draft["white_balance"], timings=timings
                )
                doc["white_balance"] = {
                    **meta,
                    **self.save_raster(directory, artifact + "-white_balance", image, timings),
                    "rgba8888_sha256": self.raster_digest(image, timings),
                }
            with timed_stage(timings, "calibration"):
                doc["calibration"] = calibrate(
                    image, draft["mode"], draft["corners"], draft["manual_patches"]
                )
            with timed_stage(timings, "roi_measurements_and_concentrations"):
                results = measure_rois(image, draft, doc["calibration"])
        else:
            results = {
                **refresh_concentrations(draft, previous, stored_calibration(doc)),
                "versions": versions(),
                "calculated_at": now(),
            }
        if reset_changed_reviews(draft, previous, results):
            results = refresh_concentrations(draft, results, stored_calibration(doc))
        doc["results"], doc["export"] = results, None
        with timed_stage(timings, "run_snapshot"):
            self.record_run(doc, previous)

    def comparison(self, doc):
        if not doc["results"]:
            raise ValueError("Analyze before comparing results.")
        return compare_results(doc["draft"], doc["results"], stored_calibration(doc))

    def raster_digest(self, image, timings=None):
        with timed_stage(timings, "raster.rgba_hash"):
            return rgba_digest(image)

    def record_run(self, doc, previous):
        return None

    def discard_artifact(self, directory, artifact):
        for folder in (directory, directory / ".cache"):
            for leftover in folder.glob(artifact + "*"):
                if leftover.name.endswith((".npy", ".png", ".part")):
                    try:
                        leftover.unlink(missing_ok=True)
                    except OSError:
                        pass

    def discard_rasters(self, before, after):
        keep = {
            raster[key]
            for raster in (after.get("render"), after.get("white_balance"))
            if raster
            for key in ("array", "preview")
        }
        try:
            directory = self.directory(after)
        except KeyError:
            return
        for raster in (before.get("render"), before.get("white_balance")):
            for key in ("array", "preview") if raster else ():
                name = raster.get(key) or ""
                if name.startswith(".cache/") and name not in keep:
                    try:
                        inside(directory, name).unlink(missing_ok=True)
                    except (OSError, ValueError):
                        pass

    def export_bundle(self, doc, image, path, initial=None):
        directory = self.directory(doc)
        results, draft = doc["results"], doc["draft"]
        identity = export_identity(doc)
        manifest = {
            "schema_name": "ckd_export",
            "schema_version": 1,
            "analysis_id": doc["analysis_id"],
            "revision": doc["revision"],
            "exported_at": now(),
            "versions": results.get("versions", {}),
            "exported_with": versions(),
            "source": doc["source"],
            "coordinate_system": "top_left_image_pixels",
            "files": {},
        }
        members = {
            "coordinates.json": json_bytes(coordinate_package(doc)),
            "results.json": json_bytes(results),
            "analysis.json": json_bytes({**portable_document(doc), "job": None, "export": None}),
        }
        tables = export_tables(results, identity)
        tables["04_roi_measurements.csv"] = roi_measurements_csv(
            image, draft, results, doc["calibration"], identity
        )
        if doc["calibration"]:
            tables["03_colorchecker_patch_measurements.csv"] = patch_measurements_csv(
                image, doc["calibration"], identity
            )
        members.update((name, text.encode()) for name, text in tables.items())
        rasters = []
        if initial is not None:
            rasters.append(("01_libraw_initial_rendered", "libraw_initial_camera_wb_rendered_input", initial, doc["render"]))
            if doc["white_balance"]:
                rasters.append(("02_libraw_explicit_wb", "libraw_explicit_wb_analysis_input", image, doc["white_balance"]))
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=1) as bundle:
            for name, data in members.items():
                bundle.writestr(name, data)
                manifest["files"][name] = hashlib.sha256(data).hexdigest()
            overlay = io.BytesIO()
            roi_overlay(image, draft["rois"]).save(overlay, format="PNG", compress_level=PNG_COMPRESSION_LEVEL)
            bundle.writestr("roi_overlay.png", overlay.getvalue(), compress_type=zipfile.ZIP_STORED)
            manifest["files"]["roi_overlay.png"] = hashlib.sha256(overlay.getvalue()).hexdigest()
            original = directory / doc["source"]["file"]
            name = "original/" + doc["source"]["filename"]
            bundle.write(original, name, compress_type=export_compression(original))
            manifest["files"][name] = digest(original)
            for prefix, stage, raster, meta in rasters:
                name = f"{prefix}_rgba8888.bin"
                value = hashlib.sha256()
                with bundle.open(name, "w") as output:
                    for chunk in rgba_chunks(raster):
                        value.update(chunk)
                        output.write(chunk)
                manifest["files"][name] = value.hexdigest()
                data = json_bytes({
                    "schema_name": "qdaq_ckd_sweat_debug_raster",
                    "schema_version": 1,
                    "stage": stage,
                    "coordinate_system": "top_left_image_pixels",
                    "width": raster.shape[1],
                    "height": raster.shape[0],
                    "source_numpy_dtype": "uint8",
                    "format": "raw_interleaved_rgba8888",
                    "byte_order": "R,G,B,A",
                    "row_stride_bytes": raster.shape[1] * 4,
                    "rgba8888_filename": name,
                    "rgba8888_sha256": value.hexdigest(),
                    "source_image_filename": doc["source"]["filename"],
                    "source_image_sha256": doc["source"]["sha256"],
                    "render_method": "rawpy_libraw_postprocess",
                    "render_parameters": {k: v for k, v in meta.items() if k not in ("array", "preview")},
                })
                bundle.writestr(f"{prefix}_raster.json", data)
                manifest["files"][f"{prefix}_raster.json"] = hashlib.sha256(data).hexdigest()
            bundle.writestr("manifest.json", json.dumps(manifest, indent=2))
        return path


def json_bytes(value):
    return json.dumps(value, indent=2, allow_nan=False).encode()


def export_identity(doc):
    return {
        "analysis_id": doc["analysis_id"],
        "analysis_title": doc["draft"]["title"],
        "source_filename": doc["source"]["filename"],
    }
