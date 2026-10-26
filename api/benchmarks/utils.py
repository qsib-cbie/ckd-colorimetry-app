"""Benchmark helpers."""

import copy
import hashlib
import io
import json
import os
import platform
import time
import zipfile
from contextlib import contextmanager, nullcontext
from pathlib import Path
from unittest.mock import patch

import numpy as np
import rawpy
from PIL import Image

from ckd import service as service_module, utils as engine_utils
from ckd.models import Draft, Reservoir
from ckd.local import LocalAnalysisService
from ckd.utils import digest, versions


def pixel_hash(image):
    return hashlib.sha256(memoryview(np.ascontiguousarray(image))).hexdigest()


def load_draft(path):
    ref = json.loads(path.read_text())
    if "inputs" not in ref:
        return Draft.model_validate(ref.get("draft", ref)).model_dump()
    inputs = ref["inputs"]
    draft = Draft(
        mode=inputs["mode"],
        white_balance=ref["white_balance_polygon"]["points"],
        corners=inputs.get("corners", []),
        rois=[
            {
                "id": r["roi_id"],
                "label": r["roi_label"],
                "points": r["polygon"]["points"],
            }
            for r in inputs["rois"]
        ],
        reservoirs=[Reservoir(id=i) for i in range(1, 7)],
    ).model_dump()
    return draft


class WriteTimer:
    def __init__(self, stream):
        self.stream = stream
        self.seconds = 0.0

    def write(self, data):
        start = time.perf_counter()
        try:
            return self.stream.write(data)
        finally:
            self.seconds += time.perf_counter() - start

    def flush(self):
        start = time.perf_counter()
        try:
            return self.stream.flush()
        finally:
            self.seconds += time.perf_counter() - start

    def __getattr__(self, name):
        return getattr(self.stream, name)


@contextmanager
def profile(variant, stages):
    read = rawpy.imread
    save = Image.Image.save
    np_save = np.save
    zip_write = zipfile.ZipFile.write

    def add(key, elapsed):
        stages[key] = stages.get(key, 0.0) + elapsed

    class RawProxy:
        def __init__(self, raw):
            self.raw = raw
            self.unpacked = False

        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.raw.close()

        def __getattr__(self, name):
            return getattr(self.raw, name)

        def unpack(self):
            start = time.perf_counter()
            self.raw.unpack()
            add("raw_unpack", time.perf_counter() - start)
            self.unpacked = True

        def postprocess(self, **kwargs):
            if not self.unpacked:
                self.unpack()
            start = time.perf_counter()
            result = self.raw.postprocess(**kwargs)
            add("raw_postprocess", time.perf_counter() - start)
            return result

    def read_raw(*args, **kwargs):
        start = time.perf_counter()
        raw = read(*args, **kwargs)
        add("raw_open", time.perf_counter() - start)
        return RawProxy(raw)

    def save_png(image, file, *args, **kwargs):
        if not isinstance(file, (str, Path)) or Path(file).suffix.lower() != ".png":
            return save(image, file, *args, **kwargs)
        if variant != "baseline":
            kwargs["compress_level"] = 1
        start = time.perf_counter()
        with open(file, "wb") as output:
            measured = WriteTimer(output)
            save(image, measured, format="PNG", **kwargs)
            measured.flush()
        elapsed = time.perf_counter() - start
        add("png_encode", elapsed - measured.seconds)
        add("png_write", measured.seconds)

    def save_array(*args, **kwargs):
        start = time.perf_counter()
        result = np_save(*args, **kwargs)
        add("npy_save", time.perf_counter() - start)
        return result

    def write_member(
        bundle, filename, arcname=None, compress_type=None, compresslevel=None
    ):
        if variant == "png1-zip" and Path(filename).suffix.lower() in (".png", ".cr2"):
            compress_type = zipfile.ZIP_STORED
        start = time.perf_counter()
        result = zip_write(bundle, filename, arcname, compress_type, compresslevel)
        add("zip_members", time.perf_counter() - start)
        return result

    with (
        patch.object(rawpy, "imread", read_raw),
        patch.object(Image.Image, "save", save_png),
        patch.object(np, "save", save_array),
        patch.object(zipfile.ZipFile, "write", write_member),
    ):
        yield


def fingerprint(service, doc, archive):
    directory = service.directory(doc)
    checks, sizes = {}, {}
    for stage in ("render", "white_balance"):
        raster = doc[stage]
        array = np.load(directory / raster["array"], mmap_mode="r", allow_pickle=False)
        with Image.open(directory / raster["preview"]) as png:
            np.testing.assert_array_equal(np.asarray(png), array)
        checks[stage + "_pixels"] = pixel_hash(array)
        sizes[stage + "_preview"] = (directory / raster["preview"]).stat().st_size
    checks["calibration"] = doc["calibration"]
    checks["results"] = doc["results"]
    with zipfile.ZipFile(archive) as bundle:
        manifest = json.loads(bundle.read("manifest.json"))
        for name, expected in manifest["files"].items():
            actual = bundle.read(name)
            assert hashlib.sha256(actual).hexdigest() == expected, name
            if name.endswith(".png"):
                with Image.open(io.BytesIO(actual)) as png:
                    checks[name] = pixel_hash(np.asarray(png))
            elif name != "analysis.json":
                checks[name] = expected
        checks["original_sha256"] = doc["source"]["sha256"]
    sizes["export"] = archive.stat().st_size
    return checks, sizes


def benchmark(source, draft_path, variants, repeat, output, expected_path=None):
    if any(v != "native" for v in variants) and hasattr(engine_utils, "save_png"):
        raise ValueError(
            "Experimental variants require the 1.0 baseline on PYTHONPATH. "
            "Use --variants native to measure the current implementation."
        )
    output.mkdir(parents=True, exist_ok=False)
    source = source.resolve()
    draft = load_draft(draft_path)
    report = {
        "case": source.name,
        "source_sha256": digest(source),
        "threads": os.environ.get("OMP_NUM_THREADS"),
        "platform": platform.platform(),
        "versions": versions(),
        "implementation_sha256": {
            "utils.py": digest(Path(engine_utils.__file__)),
            "service.py": digest(Path(service_module.__file__)),
        },
        "runs": [],
    }
    baseline_checks = json.loads(expected_path.read_text()) if expected_path else None
    for round_index in range(repeat):
        order = variants if round_index % 2 == 0 else list(reversed(variants))
        for variant in order:
            service = LocalAnalysisService(output / f"{variant}-{round_index}", inline=True)
            with source.open("rb") as raw:
                doc = service.create(source.name, raw)
            doc["draft"] = copy.deepcopy(draft)
            doc = service.store.replace(doc, doc["revision"])
            jobs = []
            for action in ("render", "white_balance", "calibrate", "analyze"):
                stages = {}
                with nullcontext() if variant == "native" else profile(variant, stages):
                    doc = service.enqueue(doc["id"], doc["revision"], action)
                assert doc["job"]["status"] == "completed", doc["job"]
                jobs.append(
                    {
                        "action": action,
                        "seconds": doc["job"]["seconds"],
                        "stages": {k: round(v, 6) for k, v in stages.items()},
                        "job_timings": doc["job"].get("timings_seconds", {}),
                    }
                )
            started = time.perf_counter()
            _, archive = service.export_archive(doc["id"], include_rasters=False)
            jobs.append({"action": "export", "seconds": round(time.perf_counter() - started, 3)})
            try:
                checks, sizes = fingerprint(service, doc, archive)
            finally:
                archive.unlink(missing_ok=True)
            if baseline_checks is None:
                baseline_checks = checks
            assert checks == baseline_checks, (
                "Pixels or results differ between runs"
            )
            (output / "fingerprint.json").write_text(
                json.dumps(checks, indent=2) + "\n"
            )
            run = {
                "round": round_index + 1,
                "variant": variant,
                "jobs": jobs,
                "bytes": sizes,
                "identical": True,
            }
            report["runs"].append(run)
            (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(
                json.dumps(
                    {
                        "case": source.name,
                        "round": round_index + 1,
                        "variant": variant,
                        "seconds": {j["action"]: j["seconds"] for j in jobs},
                        "bytes": sizes,
                        "identical": True,
                    }
                ),
                flush=True,
            )
            service.close()
