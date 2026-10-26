"""Build a source-based oracle without importing the web implementation.

Only this explicit regeneration tool needs QDAQ and macOS/Swift. Pytest reads the
reviewed JSON fixtures and never updates its own expected values.
"""

import hashlib
import json
import math
import copy
import subprocess
from pathlib import Path

import numpy as np
import rawpy

HERE = Path(__file__).parent
FIXTURES = HERE.parent / "fixtures"
ROOT = HERE.parents[2]
VIEW = "QDAQ/Views/Analysis/CKDSweat/CKDSweatAnalysisView.swift"
SOURCE_PATHS = [
    VIEW,
    "QDAQ/Models/Analysis.swift",
    "QDAQ/Models/Analysis/AnalysisConfiguration.swift",
    "QDAQ/Views/Analysis/CKDSweat/CKDConcentrationPipeline.swift",
    "QDAQ/Views/Analysis/CKDSweat/CKDCalibrationMarker.swift",
    "QDAQ/Views/Analysis/CKDSweat/CKDReservoirModels.swift",
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def between(text, start, end):
    assert text.count(start) == 1, start
    return text[text.index(start) : text.index(end, text.index(start))]


def compile_reference(qdaq, build):
    build.mkdir(parents=True, exist_ok=True)
    sources = {p: (qdaq / p).read_text() for p in SOURCE_PATHS}
    view = sources[VIEW]
    numeric = view[view.index("struct QCamROIResult: Codable") :]
    # UIKit image presentation is the only omitted method. Full-resolution
    # RGBA sampling, LAB conversion, calibration and ROI methods are unchanged.
    numeric = numeric.replace(
        between(numeric, "    func uiImage()", "    func whiteBalanceFactors"), ""
    )
    review = between(
        view,
        "    private func rebuildReservoirResults()",
        "    private func seedDefaultColorCheckerGrid()",
    ).replace("private func rebuildReservoirResults", "func rebuildReservoirResults", 1)
    adapter = (
        """
final class ReferenceReviewState {
    var reservoirs: [QCamReservoir]
    var results: [QCamROIResult]
    var reservoirResults: [QCamReservoirResult] = []
    var analyteSummaries: [QCamAnalyteSummary] = []
    var classification: QCamCKDClassification?
    let calibrationMarkerKind: QCamCalibrationMarkerKind
    let ageText: String
    let selectedSex: QCamSex?
    let analysisConfig = SweatCKDCAMAnalysisConfig()
    init(reservoirs: [QCamReservoir], results: [QCamROIResult],
         marker: QCamCalibrationMarkerKind, age: Double?, sex: QCamSex?) {
        self.reservoirs = reservoirs; self.results = results
        self.calibrationMarkerKind = marker
        self.ageText = age.map { String($0) } ?? ""
        self.selectedSex = sex
    }
"""
        + review
        + "\n}\n"
    )
    extracted = "import Foundation\nimport CoreGraphics\n"
    extracted += (
        between(sources[SOURCE_PATHS[2]], "protocol AnalysisConfiguration", "\n") + "\n"
    )
    extracted += between(
        sources[SOURCE_PATHS[1]],
        "struct SweatCKDCAMAnalysisConfig:",
        "/// Swift wrapper",
    )
    extracted += between(view, "enum QCamError:", "struct QCamRawImport")
    extracted += between(view, "struct QCamImageDimensions:", "struct QCamRect:")
    extracted += numeric + adapter
    for path in SOURCE_PATHS[3:]:
        extracted += "\n" + sources[path]
    (build / "Core.swift").write_text(extracted)
    (build / "main.swift").write_text((HERE / "Harness.swift").read_text())
    subprocess.run(
        [
            "swiftc",
            "-O",
            str(build / "Core.swift"),
            str(build / "main.swift"),
            "-o",
            str(build / "oracle"),
        ],
        check=True,
    )
    return {
        "qdaq_commit": subprocess.check_output(
            ["git", "-C", str(qdaq), "rev-parse", "HEAD"], text=True
        ).strip(),
        "sources": {p: sha((qdaq / p).read_bytes()) for p in SOURCE_PATHS},
        "extracted_core_sha256": sha(extracted.encode()),
        "harness_sha256": sha((HERE / "Harness.swift").read_bytes()),
        "generator_sha256": sha(Path(__file__).read_bytes()),
        "swift_version": subprocess.check_output(
            ["swiftc", "--version"], text=True, stderr=subprocess.STDOUT
        ).strip(),
        "rawpy_version": rawpy.__version__,
        "libraw_version": list(rawpy.libraw_version),
        "execution": "QDAQ numerical source on macOS, not an iOS app or device run",
    }


def invoke(build, data):
    result = subprocess.run(
        [str(build / "oracle")],
        input=json.dumps(data),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(result.stdout)


def render(path, wb=None, brightness=1):
    # Independently declared settings. No ckd module is imported by this tool.
    with rawpy.imread(str(path)) as raw:
        image = raw.postprocess(
            demosaic_algorithm=rawpy.DemosaicAlgorithm.VNG,
            output_color=rawpy.ColorSpace.raw,
            output_bps=8,
            no_auto_bright=True,
            use_camera_wb=wb is None,
            use_auto_wb=False,
            user_wb=wb,
            bright=brightness,
        )
        return image, list(raw.camera_whitebalance)


def raster_input(build, image):
    data = np.dstack((image, np.full(image.shape[:2], 255, dtype=np.uint8))).tobytes()
    (build / "raster.rgba").write_bytes(data)
    return {
        "rgba_path": str(build / "raster.rgba"),
        "width": image.shape[1],
        "height": image.shape[0],
    }, sha(data)


def generate_references(qdaq, output):
    build = ROOT / "tmp" / "swift-reference"
    provenance = compile_reference(qdaq, build)
    output.mkdir(parents=True, exist_ok=True)
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    units = invoke(build, unit_inputs())
    (output / "units.json").write_text(
        json.dumps(units, indent=2, allow_nan=False) + "\n"
    )
    for name in ("iPhoneRAW.DNG", "SampleImg1.CR2", "_NOT_ACTUAL_TEST.dng"):
        pipeline = pipeline_reference(build, name)
        (output / (name + ".json")).write_text(
            json.dumps(pipeline, indent=2, allow_nan=False) + "\n"
        )
        print(f"Generated Swift core checkpoints: {name}", flush=True)


def pipeline_reference(build, name):
    source = FIXTURES / name
    if name == "_NOT_ACTUAL_TEST.dng":
        package = json.loads(
            (FIXTURES / "synthetic-flower-coordinates.json").read_text()
        )
    else:
        legacy = json.loads(
            (FIXTURES / (name + "_full_color_analyzed_run.json")).read_text()
        )
        package = {
            "calibration_mode": "standard_24_grid",
            "white_balance_polygon": {
                "points": legacy["white_balance"]["manual_wb_polygon"]
            },
            "color_calibration_corners": list(
                legacy["color_checker"]["corners"].values()
            ),
            "reservoirs": [],
            "rois": [],
        }
        for r in legacy["roi_measurements"]:
            if r.get("lab_stats") and r.get("geometry"):
                i = len(package["rois"]) + 1
                package["rois"].append(
                    {
                        "roi_id": i,
                        "roi_label": f"ROI {i}",
                        "polygon": {"points": r["geometry"]["polygon"]},
                    }
                )
    initial, camera = render(source)
    raster, initial_hash = raster_input(build, initial)
    first = invoke(
        build,
        {
            **raster,
            "action": "wb",
            "polygon": package["white_balance_polygon"],
            "wb": camera,
        },
    )
    once, _ = render(source, first["multipliers"])
    raster, first_hash = raster_input(build, once)
    second = invoke(
        build,
        {
            **raster,
            "action": "wb",
            "polygon": package["white_balance_polygon"],
            "wb": first["multipliers"],
        },
    )
    final, _ = render(source, second["multipliers"], second["brightness"])
    raster, final_hash = raster_input(build, final)
    if name != "_NOT_ACTUAL_TEST.dng":
        # Refuse to bless a changed decoder output as a new reference.
        assert (
            final_hash
            == legacy["python_rendered_raster"]["rendered_raster"]["rgba8888"]["sha256"]
        )
    inputs = {
        "action": "pipeline",
        "mode": package["calibration_mode"],
        "corners": package["color_calibration_corners"],
        "rois": package["rois"],
        "reservoirs": package["reservoirs"],
        "age": 50,
        "sex": "female",
        "filename": name,
    }
    result = invoke(build, {**raster, **inputs})
    output = {
        "source_sha256": sha(source.read_bytes()),
        "dimensions": [raster["width"], raster["height"]],
        "inputs": inputs,
        "white_balance_polygon": package["white_balance_polygon"],
        "camera_whitebalance": camera,
        "initial_rgba_sha256": initial_hash,
        "first_pass_rgba_sha256": first_hash,
        "final_rgba_sha256": final_hash,
        "first_pass": first,
        "second_pass": second,
        "expected": result,
    }
    if name == "_NOT_ACTUAL_TEST.dng":
        manual = [p["polygon"] for p in result["calibration"]["patches"]]
        # Deliberately scramble the manual selection order; no web geometry.
        order = [8, 2, 5, 0, 7, 1, 4, 6, 3]
        manual_inputs = {
            **inputs,
            "mode": "flower_9_manual",
            "manual": [manual[i] for i in order],
        }
        output["manual_inputs"] = manual_inputs
        output["manual_expected"] = invoke(build, {**raster, **manual_inputs})
        excluded = copy.deepcopy(inputs)
        excluded["reservoirs"][0]["review_status"] = "excluded"
        output["excluded_ph_expected"] = invoke(build, {**raster, **excluded})
    return output


def lab_dict(values):
    return dict(zip(("l_star", "a_star", "b_star"), values))


def reservoir_case(name, spec, age=50, sex="female"):
    rois, reservoirs = [], []
    for i, (analyte, labs, review) in enumerate(spec, 1):
        ids = []
        for value in labs:
            roi_id = len(rois) + 1
            ids.append(roi_id)
            rois.append(
                {
                    "roi_id": roi_id,
                    "roi_label": f"R{i}.{len(ids)}",
                    "polygon": {"points": []},
                    "raw_median": lab_dict([0, 0, 0]),
                    "raw_mean": lab_dict([0, 0, 0]),
                    "raw_standard_deviation": lab_dict([0, 0, 0]),
                    "calibrated_median": lab_dict(value),
                    "calibrated_mean": lab_dict([99, -30, 0]),
                    "pixel_count": roi_id**2 * 37,
                }
            )
        reservoirs.append(
            {
                "reservoir_id": i,
                "label": f"Reservoir {i}",
                "analyte": analyte,
                "roi_ids": ids,
                "review_status": review,
                "exclusion_reason": None,
            }
        )
    return {
        "name": name,
        "roi_results": rois,
        "reservoirs": reservoirs,
        "age": age,
        "sex": sex,
    }


def unit_inputs():
    equations = []
    for value in (5.5, 5.999, 6, 6.25, 6.5, 6.75, 7, 7.001, 7.5):
        equations.append(
            {
                "name": f"ph_{value}",
                "analyte": "ph",
                "lab": [50, 0, -10.392 * value**2 + 82.361 * value - 96.528],
            }
        )
    for analyte, axis, values in (
        ("ph", 2, [100, "nan", "inf", "-inf"]),
        ("creatinine", 1, [-20, 0, 3, 40, 0.705 / 0.0112, 63, "nan", "inf", "-inf"]),
    ):
        for value in values:
            lab_values = [50, 0, 20]
            lab_values[axis] = value
            equations.append(
                {
                    "name": f"{analyte}_domain_{value}",
                    "analyte": analyte,
                    "lab": lab_values,
                }
            )
    for ph in (
        None,
        "nan",
        "inf",
        "-inf",
        5.5,
        6,
        6.25,
        math.nextafter(6.25, math.inf),
        6.5,
        6.75,
        math.nextafter(6.75, math.inf),
        7,
        7.5,
    ):
        equations.append(
            {"name": f"urea_ph_{ph}", "analyte": "urea", "lab": [60, 5, 20], "ph": ph}
        )
    for values in ([100, 0, 100], [0, 0, -300], ["nan", 0, 0], ["inf", 0, 0]):
        equations.append(
            {"name": f"urea_lab_{values}", "analyte": "urea", "lab": values, "ph": 6.5}
        )
    fits = [
        {
            "measured": [
                [10, 2, 5],
                [25, -5, 4],
                [50, 15, -10],
                [75, -12, -6],
                [90, 0, 18],
            ],
            "reference": [
                [20, 4, 2],
                [30, -2, 5],
                [55, 8, -9],
                [70, -11, -3],
                [95, 1, 14],
            ],
        },
        {
            "measured": [[10, 1, 2], [20, 1, 2], [30, 1, 2], [40, 1, 2]],
            "reference": [[10, 1, 2]] * 4,
        },
        {
            "measured": [[10, 1, 2], [10, 2, 4], [10, 3, 3], [10, 4, 1]],
            "reference": [[10, 1, 2]] * 4,
        },
    ]
    base = [
        ("ph", [[50, 0, 0]], "needs_review"),
        ("urea", [[60, 5, 20]], "needs_review"),
        ("creatinine", [[50, 3, 20]], "needs_review"),
    ]
    cases = [reservoir_case("one_each", base)]
    for n in (1, 2, 3, 4):
        cases.append(
            reservoir_case(
                f"{n}_unequal_area_rois",
                [("ph", [[50, 0, b] for b in range(n)], "needs_review")] + base[1:],
            )
        )
    cases.append(
        reservoir_case(
            "duplicates_after_conversion",
            base
            + [
                ("ph", [[50, 0, 2], [50, 0, 4]], "needs_review"),
                ("urea", [[55, 6, 18], [70, 5, 23]], "needs_review"),
                ("creatinine", [[55, 10, 30], [65, 20, 40]], "needs_review"),
            ],
        )
    )
    for review in ("needs_review", "included", "excluded"):
        cases.append(
            reservoir_case(
                f"flagged_ph_{review}", base + [("ph", [[50, 0, -100]], review)]
            )
        )
        cases.append(
            reservoir_case(
                f"only_ph_{review}", [("ph", [[50, 0, 0]], review)] + base[1:]
            )
        )
        cases.append(
            reservoir_case(
                f"invalid_ph_{review}", base + [("ph", [[50, 0, 100]], review)]
            )
        )
        cases.append(
            reservoir_case(
                f"negative_urea_{review}", base + [("urea", [[100, 0, 100]], review)]
            )
        )
        cases.append(
            reservoir_case(
                f"negative_creatinine_{review}",
                base + [("creatinine", [[50, -20, 20]], review)],
            )
        )
        cases.append(
            reservoir_case(
                f"flagged_urea_{review}", base + [("urea", [[0, 0, -300]], review)]
            )
        )
    cases.extend(
        [
            reservoir_case("missing_ph", base[1:]),
            reservoir_case("missing_age", base, age=None),
            reservoir_case("missing_sex", base, sex=None),
        ]
    )
    classifiers = [
        {"urea": u, "creatinine": c, "age": age, "sex": sex}
        for u, c, age, sex in [
            (20, 12, 50, "female"),
            (20, 12, 50, "male"),
            (0, 0, 30, "female"),
            (500, 200, 90, "male"),
            (10000, 0, 30, "female"),
            (20, 12, 0, "female"),
            (20, 12, -1, "female"),
            (20, 12, "nan", "female"),
            (20, 12, "inf", "female"),
            (None, 12, 50, "female"),
            (20, None, 50, "male"),
        ]
    ]
    threshold_urea = (6.28 - 0.03 * 50 - math.log(1 / 0.305 - 1)) / 0.25
    for offset in (-1e-7, 1e-7):
        classifiers.append(
            {
                "urea": threshold_urea + offset,
                "creatinine": 0,
                "age": 50,
                "sex": "female",
            }
        )
    sampling = []
    rgb = [[(i * 13) % 256, (i * 7) % 256, (i * 19) % 256] for i in range(64)]
    polygons = {
        "inclusive_image_edges": [(0, 0), (7, 0), (7, 7), (0, 7)],
        "fractional_vertices": [(1.25, 1.25), (6.75, 1.75), (5.25, 6.75), (0.75, 5.25)],
        "diagonal_boundary": [(1, 1), (6, 1), (1, 6)],
        "concave": [(1, 1), (6, 1), (6, 6), (4, 4), (1, 6)],
        "reversed_closed": [(1, 1), (1, 6), (6, 1), (1, 1)],
    }
    for name, points in polygons.items():
        sampling.append(
            {
                "name": name,
                "width": 8,
                "height": 8,
                "rgb": rgb,
                "polygon": {"points": [{"x": x, "y": y} for x, y in points]},
            }
        )
    for color in (
        [0, 0, 0],
        [255, 255, 255],
        [255, 0, 0],
        [0, 255, 0],
        [0, 0, 255],
        [10, 10, 10],
        [11, 11, 11],
    ):
        sampling.append(
            {
                "name": f"uniform_{color}",
                "width": 2,
                "height": 2,
                "rgb": [color] * 4,
                "polygon": {
                    "points": [
                        {"x": x, "y": y} for x, y in [(0, 0), (1, 0), (1, 1), (0, 1)]
                    ]
                },
            }
        )
    return {
        "action": "units",
        "equations": equations,
        "fits": fits,
        "reservoirs": cases,
        "classifiers": classifiers,
        "sampling": sampling,
    }
