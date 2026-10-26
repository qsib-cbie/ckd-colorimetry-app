"""Compare iOS (CKDKit), the current Mac engine and the previous Mac release on the pipeline fixtures."""

import csv
import io
import json
import math
import re
import statistics
import sys
from pathlib import Path

CASES = [
    ("cr2_standard24", "Standard 24, Canon CR2 20.2 MP"),
    ("dng_standard24", "Standard 24, iPhone ProRAW 12.2 MP"),
    ("dng_flower_auto", "Flower 9 automatic, test DNG"),
    ("dng_flower_manual", "Flower 9 manual, test DNG"),
    ("prores48", "Standard 24, ProRAW 48.8 MP (2x copy)"),
]
STAGES = ["render", "white_balance", "calibrate", "analyze"]
RUNS = (1, 2, 3)


def load(path):
    return json.loads(Path(path).read_text())


def footprint(path):
    match = re.search(r"(\d+)\s+peak memory footprint", Path(path).read_text())
    return int(match.group(1)) / 1048576 if match else None


def rel(a, b):
    if a is None or b is None:
        return 0.0 if a is None and b is None else math.inf
    if a == b:
        return 0.0
    return abs(a - b) / max(abs(a), abs(b), 1e-300)


def flat(value):
    if isinstance(value, (list, tuple)):
        for item in value:
            yield from flat(item)
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        yield float(value)


def max_difference(a, b, measure):
    left, right = list(flat(a)), list(flat(b))
    if len(left) != len(right):
        return math.inf
    return max((measure(x, y) for x, y in zip(left, right)), default=0.0)


def values(results):
    rows = [(f"R{r['id']} {r['analyte']}", r["value"], r["calculation_status"]) for r in results["reservoirs"] if r["analyte"]]
    rows += [(f"Final {name}", summary["value"], None) for name, summary in results["summaries"].items()]
    prediction = results.get("prediction") or {}
    rows.append(("Prediction", prediction.get("probability"), prediction.get("status")))
    return rows


def roi_values(results, key):
    return {roi["id"]: roi[key] for roi in results["rois"]}


def cell_difference(a, b):
    if a.startswith("["):
        return max_difference(json.loads(a), json.loads(b), rel)
    return rel(float(a), float(b))


def table_cells(a, b):
    total = same = 0
    worst = 0.0
    for name in sorted(set(a) | set(b)):
        left = list(csv.reader(io.StringIO(a.get(name, ""))))
        right = list(csv.reader(io.StringIO(b.get(name, ""))))
        if len(left) != len(right):
            return None
        for row_a, row_b in zip(left, right):
            if len(row_a) != len(row_b):
                return None
            for cell_a, cell_b in zip(row_a, row_b):
                total += 1
                if cell_a == cell_b:
                    same += 1
                    continue
                try:
                    worst = max(worst, cell_difference(cell_a, cell_b))
                except ValueError:
                    worst = math.inf
    return total, same, worst


def compare(x, y, tables=False):
    calibrated_x, calibrated_y = roi_values(x["results"], "calibrated_median"), roi_values(y["results"], "calibrated_median")
    raw_x, raw_y = roi_values(x["results"], "median"), roi_values(y["results"], "median")
    out = {
        "render_identical": x["render_sha"] == y["render_sha"],
        "wb_identical": x["wb_sha"] == y["wb_sha"],
        "wb_multiplier_max_rel": max_difference(x["wb_multipliers"], y["wb_multipliers"], rel),
        "orientation_same": x["calibration"].get("orientation") == y["calibration"].get("orientation"),
        "coefficients_max_abs": max_difference(x["calibration"]["coefficients"], y["calibration"]["coefficients"],
                                               lambda p, q: abs(p - q)),
        "rmse": [x["calibration"]["rmse"], y["calibration"]["rmse"]],
        "roi_calibrated_max_abs": max(max_difference(calibrated_x[k], calibrated_y[k], lambda p, q: abs(p - q)) for k in calibrated_y),
        "roi_raw_lab_max_abs": max(max_difference(raw_x[k], raw_y[k], lambda p, q: abs(p - q)) for k in raw_y),
    }
    out["values"] = [{"label": label, "a": a, "b": b, "rel": rel(a, b), "status_same": status_a == status_b}
                     for (label, a, status_a), (_, b, status_b) in zip(values(x["results"]), values(y["results"]))]
    out["values_max_rel"] = max((v["rel"] for v in out["values"]), default=0.0)
    out["statuses_same"] = all(v["status_same"] for v in out["values"])
    if tables and "tables" in x and "tables" in y:
        out["tables"] = table_cells(x["tables"], y["tables"])
    return out


def short(value):
    return "inf" if value == math.inf else ("0" if value == 0 else f"{value:.1e}")


def main():
    root = Path(sys.argv[1])
    report = {"cases": []}
    for name, label in CASES:
        directory = root / "runs" / name
        if not directory.exists():
            continue
        runs = {who: [load(directory / f"{who}-{i}.json") for i in RUNS] for who in ("mac21", "mac20")}
        runs["ios"] = [load(directory / f"ios-{i}" / "ios.json") for i in RUNS]
        case = {
            "name": name, "label": label, "size": runs["mac21"][0]["size"],
            "times": {who: {s: statistics.median(r["stages"][s]["seconds"] for r in group) for s in STAGES}
                      for who, group in runs.items()},
            "footprint_mb": {who: statistics.median(footprint(directory / f"{who}-{i}.time") for i in RUNS) for who in runs},
            "ios_vs_mac21": compare(runs["ios"][0], runs["mac21"][0], tables=True),
            "mac20_vs_mac21": compare(runs["mac20"][0], runs["mac21"][0]),
            "versions": {"mac20": runs["mac20"][0]["versions"], "mac21": runs["mac21"][0]["versions"]},
        }
        report["cases"].append(case)
    (root / "report.json").write_text(json.dumps(report, indent=1, default=str))

    print("== iOS (CKDKit on macOS) vs current Mac")
    for case in report["cases"]:
        d, t = case["ios_vs_mac21"], case["ios_vs_mac21"].get("tables")
        print(f"{case['name']:18s} render={d['render_identical']} wb={d['wb_identical']} orient={d['orientation_same']} "
              f"coef={short(d['coefficients_max_abs'])} roiLAB={short(d['roi_calibrated_max_abs'])} "
              f"values={short(d['values_max_rel'])} statuses={d['statuses_same']}"
              + (f" tables={t[1]}/{t[0]} worst={short(t[2])}" if t else ""))
    print("== Previous Mac release vs current Mac")
    for case in report["cases"]:
        d = case["mac20_vs_mac21"]
        print(f"{case['name']:18s} render={d['render_identical']} wb={d['wb_identical']} coef={short(d['coefficients_max_abs'])} "
              f"roiLAB={short(d['roi_calibrated_max_abs'])} values={short(d['values_max_rel'])} statuses={d['statuses_same']}")
    print("== Median seconds per stage and peak footprint (MB)")
    for case in report["cases"]:
        times, memory = case["times"], case["footprint_mb"]
        print(f"{case['name']:18s} " + "  ".join(
            f"{who}: " + " ".join(f"{s} {times[who][s]:.3f}" for s in STAGES) + f" mem {memory[who]:.0f}" for who in ("ios", "mac21", "mac20")))


if __name__ == "__main__":
    main()
