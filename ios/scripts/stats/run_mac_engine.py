"""Run one CKD engine version on a RAW with a Mac analysis draft and write its outputs and stage timings."""

import argparse
import copy
import json
import resource
import sys
import time
from pathlib import Path


def scaled(points, factor):
    return [{"x": p["x"] * factor + 0.5, "y": p["y"] * factor + 0.5} for p in points]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api", required=True)
    parser.add_argument("--raw", required=True)
    parser.add_argument("--document", required=True)
    parser.add_argument("--scale", type=int, default=1)
    parser.add_argument("--identity")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    sys.path.insert(0, args.api)
    from ckd import utils
    from ckd.models import Draft, Reservoir

    draft = copy.deepcopy(json.loads(Path(args.document).read_text())["draft"])
    if args.scale != 1:
        draft["white_balance"] = scaled(draft["white_balance"], args.scale)
        draft["corners"] = scaled(draft["corners"], args.scale)
        draft["manual_patches"] = [scaled(patch, args.scale) for patch in draft["manual_patches"]]
        for roi in draft["rois"]:
            roi["points"] = scaled(roi["points"], args.scale)
    draft = {key: value for key, value in draft.items() if key in Draft.model_fields}
    draft["reservoirs"] = [{key: value for key, value in reservoir.items() if key in Reservoir.model_fields}
                           for reservoir in draft["reservoirs"]]
    draft = Draft.model_validate(draft).model_dump()

    stages = {}

    def stage(name, run):
        start = time.perf_counter()
        value = run()
        stages[name] = {
            "seconds": round(time.perf_counter() - start, 4),
            "peak_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576, 1),
        }
        return value

    initial, meta = stage("render", lambda: utils.render_raw(args.raw))
    balanced, balance = stage("white_balance", lambda: utils.white_balance(
        args.raw, initial, meta["camera_whitebalance"], draft["white_balance"]))
    calibration = stage("calibrate", lambda: utils.calibrate(balanced, draft["mode"], draft["corners"], draft["manual_patches"]))
    results = stage("analyze", lambda: utils.measure_rois(balanced, draft, calibration))
    output = {
        "versions": utils.versions(), "size": list(initial.shape[:2]), "stages": stages,
        "render_sha": utils.rgba_digest(initial), "wb_sha": utils.rgba_digest(balanced),
        "wb_multipliers": balance["white_balance"], "calibration": calibration, "results": results,
    }
    if args.identity:
        identity = json.loads(Path(args.identity).read_text())
        tables = utils.export_tables(results, identity)
        tables["03_colorchecker_patch_measurements.csv"] = utils.patch_measurements_csv(balanced, calibration, identity)
        tables["04_roi_measurements.csv"] = utils.roi_measurements_csv(balanced, draft, results, calibration, identity)
        output["tables"] = tables
    Path(args.out).write_text(json.dumps(output, default=lambda value: value.tolist() if hasattr(value, "tolist") else str(value)))


if __name__ == "__main__":
    main()
