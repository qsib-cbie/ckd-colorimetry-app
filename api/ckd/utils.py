"""Scientific, equation registry, classifier, uncertainty, export table, provenance and persistence helpers.
Marker references and geometry adapted from QDAQ CKD and the Epicore colorChecker
reference (A. J. Aranyosi, copyright 2017)."""

import csv
import hashlib
import io
import json
import math
import platform
import struct
import time
import zipfile
from contextlib import contextmanager
from datetime import datetime, timezone

import numpy as np
import rawpy
import skimage
from PIL import Image, ImageDraw
from skimage.color import rgb2lab
from skimage.draw import polygon

from . import __version__ as APP_VERSION
from .models import MAX_RESERVOIRS

CONFIG_VERSION = "ckd_research_2026_10_14"
FLOWER_VERSION = "flower9_printed_lab_regression_2026_07_21"
STANDARD_LAB = np.array(
    [
        [37.54, 14.37, 14.92],
        [62.73, 35.83, 56.5],
        [28.37, 15.42, -49.8],
        [95.19, -1.03, 2.93],
        [64.66, 19.27, 17.5],
        [39.43, 10.75, -45.17],
        [54.38, -39.72, 32.27],
        [81.29, -0.57, 0.44],
        [49.32, -3.82, -22.54],
        [50.57, 48.64, 16.67],
        [42.43, 51.05, 28.62],
        [66.89, -0.75, -0.06],
        [43.46, -12.74, 22.72],
        [30.1, 22.54, -20.87],
        [81.8, 2.67, 80.41],
        [50.76, -0.13, 0.14],
        [54.94, 9.61, -24.79],
        [71.77, -24.13, 58.19],
        [50.63, 51.28, -14.12],
        [35.63, -0.46, -0.48],
        [70.48, -32.26, -0.37],
        [71.51, 18.24, 67.37],
        [49.57, -29.71, -28.32],
        [20.64, 0.07, -0.46],
    ]
)
FLOWER_LAB = STANDARD_LAB[[13, 3, 15, 9, 14, 2, 1, 21, 6]] * [0.835, 0.868, 0.921] + [
    9.881,
    -2.364,
    -2.633,
]
RANGES = {"ph": (6.0, 7.0), "urea": (0.0, 500.0), "creatinine": (0.0, 200.0)}
IDENTITY_FIELDS = ["analysis_id", "analysis_title", "source_filename"]
UNITS = {"ph": "pH", "urea": "mM", "creatinine": "uM"}
EQUATIONS = {
    "ph": "ph_quadratic_screenshot_rounded_v1",
    "urea": "urea_ph_specific_screenshot_rounded_v1",
    "creatinine": "creatinine_inverse_screenshot_rounded_v1",
}
PH_EQUATION = {"quadratic": -10.392, "linear": 82.361, "intercept": -96.528}
CREATININE_EQUATION = {"offset": 0.705, "slope": 0.0112, "numerator": 0.856, "denominator": 0.00560}
UREA_MODELS = {
    "pH_6.0": [328.758, -3.707, 0.409, 0],
    "pH_6.5": [91.418, -0.014, 0, -1.639],
    "pH_7.0": [592.133, -5.940, -2.399, -0.925],
}
UREA_MODELS_AB = {
    "pH_6.0": [15.7643, 0, 1.7388, -0.3501],
    "pH_6.5": [43.5382, 0, 0.8451, -0.8451],
    "pH_7.0": [31.5956, 0, 0.7921, -0.7921],
}
UREA_CALIBRATIONS = {
    "lab": {"label": "L*a*b* (2026-07-21)", "version": EQUATIONS["urea"], "models": UREA_MODELS},
    "ab": {"label": "a*b* only (2026-10-12)", "version": "urea_ph_specific_ab_2026_10_12", "models": UREA_MODELS_AB},
}
UREA_MODEL_LIMITS = (6.25, 6.75)
CLASSIFIER = {"intercept": 6.28, "urea": 0.25, "creatinine": 0.15, "age": 0.03, "male": 0.42,
              "threshold": 0.305, "version": "g3_logistic_collaborator_v1"}
SINGLE_CLASSIFIERS = {
    "creatinine": {"intercept": -5.1855, "analyte": 0.2463, "age": 0.0494, "male": 0.319, "threshold": 0.579,
                   "auc": 0.923, "version": "g3_logistic_creatinine_age_sex_2026_10_12"},
    "urea": {"intercept": -6.0376, "analyte": 0.3449, "age": 0.0359, "male": -0.5728, "threshold": 0.422,
             "auc": 0.947, "version": "g3_logistic_urea_age_sex_2026_10_12"},
}
CLASSIFIER_LABELS = {"full": "Urea + creatinine + age + sex", "creatinine": "Creatinine + age + sex",
                     "urea": "Urea + age + sex"}
STANDARD_24_MAX_RMSE = 12

PNG_COMPRESSION_LEVEL = 1


@contextmanager
def timed_stage(timings, name):
    """Add the wall-clock seconds of a stage, including stages that fail."""
    start = time.perf_counter()
    try:
        yield
    finally:
        if timings is not None:
            timings[name] = timings.get(name, 0.0) + time.perf_counter() - start


class TimedBinaryWriter:
    """Time buffered file writes separately from PNG encoding."""

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


def save_png(image, path, timings=None, prefix="preview"):
    """Save every RGB pixel losslessly and record encoding versus file-write time.

    Write time includes flushing Python's buffer but not fsync.
    """
    with timed_stage(timings, f"{prefix}.prepare"):
        picture = Image.fromarray(image) if isinstance(image, np.ndarray) else image
    with path.open("wb") as stream:
        measured = TimedBinaryWriter(stream)
        start = time.perf_counter()
        picture.save(measured, format="PNG", compress_level=PNG_COMPRESSION_LEVEL)
        measured.flush()
        elapsed = time.perf_counter() - start
    if timings is not None:
        timings[f"{prefix}.png_encode"] = elapsed - measured.seconds
        timings[f"{prefix}.file_write"] = measured.seconds


def export_compression(path):
    # CR2 and PNG are already compressed; DNG compression varies, so DNG keeps deflate.
    return (
        zipfile.ZIP_STORED
        if path.suffix.lower() in (".png", ".cr2")
        else zipfile.ZIP_DEFLATED
    )


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def versions():
    return {
        "app": APP_VERSION,
        "engine": "0.1.1",
        "configuration": CONFIG_VERSION,
        "flower_reference": FLOWER_VERSION,
        "python": platform.python_version(),
        "rawpy": rawpy.__version__,
        "libraw": ".".join(map(str, rawpy.libraw_version)),
        "numpy": np.__version__,
        "scikit_image": skimage.__version__,
    }


def points_array(points):
    values = np.array([[p["x"], p["y"]] for p in points], dtype=float)
    if len(values) > 1 and np.array_equal(values[0], values[-1]):
        values = values[:-1]
    return values


def cross(a, b, c):
    return float((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]))


def segments_intersect(a, b, c, d):
    values = [cross(a, b, c), cross(a, b, d), cross(c, d, a), cross(c, d, b)]
    if values[0] * values[1] < 0 and values[2] * values[3] < 0:
        return True
    for value, p, q, r in [
        (values[0], a, b, c),
        (values[1], a, b, d),
        (values[2], c, d, a),
        (values[3], c, d, b),
    ]:
        if (
            abs(value) < 1e-9
            and np.all(r >= np.minimum(p, q) - 1e-9)
            and np.all(r <= np.maximum(p, q) + 1e-9)
        ):
            return True
    return False


def validate_polygon(points, width, height):
    p = points_array(points)
    if not 3 <= len(p) <= 128 or not np.isfinite(p).all():
        raise ValueError("A polygon needs 3 to 128 finite vertices.")
    if (p < 0).any() or (p[:, 0] > width - 1).any() or (p[:, 1] > height - 1).any():
        raise ValueError("Polygon vertices must stay inside the original image.")
    if len(np.unique(p, axis=0)) != len(p):
        raise ValueError("Polygon vertices must be unique.")
    area = (
        abs(np.dot(p[:, 0], np.roll(p[:, 1], 1)) - np.dot(p[:, 1], np.roll(p[:, 0], 1)))
        / 2
    )
    if area < 0.5:
        raise ValueError("Polygon area is too small.")
    n = len(p)
    for i in range(n):
        for j in range(i + 1, n):
            if j == i + 1 or (i == 0 and j == n - 1):
                continue
            if segments_intersect(p[i], p[(i + 1) % n], p[j], p[(j + 1) % n]):
                raise ValueError("A polygon must not cross or touch itself.")
    return p


def sample_rgb(image, points):
    p = validate_polygon(points, image.shape[1], image.shape[0])
    rr, cc = polygon(p[:, 1], p[:, 0], shape=image.shape[:2])
    if not len(rr):
        raise ValueError("The polygon contains no image pixels.")
    return image[rr, cc]


def lab_stats(image, points):
    lab = rgb2lab(sample_rgb(image, points).reshape(-1, 1, 3)).reshape(-1, 3)
    return {
        "median": np.median(lab, axis=0).tolist(),
        "mean": lab.mean(axis=0).tolist(),
        "standard_deviation": lab.std(axis=0).tolist(),
        "pixel_count": len(lab),
    }


JPEG_XL_MESSAGE = (
    "This DNG uses JPEG XL compression, which CKD Colorimetry cannot read. On the iPhone, "
    "choose the most compatible ProRAW format in the Camera settings and take the photo again."
)


def dng_uses_jpeg_xl(path):
    """True when a full-resolution image in this TIFF/DNG is JPEG XL compressed (compression 52546)."""
    try:
        with open(path, "rb") as handle:
            header = handle.read(8)
            if len(header) < 8 or header[:2] not in (b"II", b"MM"):
                return False
            order = "<" if header[:2] == b"II" else ">"
            if struct.unpack(order + "H", header[2:4])[0] != 42:
                return False
            pending, seen = [struct.unpack(order + "I", header[4:8])[0]], set()
            while pending and len(seen) < 64:
                offset = pending.pop()
                if not offset or offset in seen:
                    continue
                seen.add(offset)
                handle.seek(offset)
                raw_count = handle.read(2)
                if len(raw_count) < 2:
                    continue
                count = struct.unpack(order + "H", raw_count)[0]
                block = handle.read(12 * count + 4)
                tags = {}
                for index in range(min(count, (len(block) - 4) // 12)):
                    tag, kind, number, value = struct.unpack(order + "HHI4s", block[12 * index:12 * index + 12])
                    if tag in (254, 259) and number == 1:
                        tags[tag] = struct.unpack(order + ("H" if kind == 3 else "I"), value[:2] if kind == 3 else value)[0]
                    elif tag == 330 and kind in (4, 13):
                        if number == 1:
                            pending.append(struct.unpack(order + "I", value)[0])
                        else:
                            position = handle.tell()
                            handle.seek(struct.unpack(order + "I", value)[0])
                            pending.extend(struct.unpack(order + "I" * number, handle.read(4 * number)))
                            handle.seek(position)
                if tags.get(259) == 52546 and tags.get(254, 0) == 0:
                    return True
                if len(block) >= 4:
                    pending.append(struct.unpack(order + "I", block[-4:])[0])
    except (OSError, struct.error):
        return False
    return False


def render_raw(path, wb=None, bright=1.0, *, timings=None, prefix="render"):
    try:
        with timed_stage(timings, f"{prefix}.raw_open"):
            source = rawpy.imread(str(path))
    except rawpy.LibRawError as exc:
        if dng_uses_jpeg_xl(path):
            raise ValueError(JPEG_XL_MESSAGE) from exc
        raise
    with source as raw:
        if raw.sizes.width * raw.sizes.height > 50_000_000:
            raise ValueError("CKD Colorimetry supports images up to 50 megapixels.")
        args = dict(
            no_auto_bright=True,
            use_camera_wb=wb is None,
            use_auto_wb=False,
            output_color=rawpy.ColorSpace.raw,
            demosaic_algorithm=rawpy.DemosaicAlgorithm.VNG,
            output_bps=8,
            bright=bright,
        )
        if wb is not None:
            args["user_wb"] = wb
        with timed_stage(timings, f"{prefix}.raw_unpack"):
            try:
                raw.unpack()
            except rawpy.LibRawError as exc:
                if dng_uses_jpeg_xl(path):
                    raise ValueError(JPEG_XL_MESSAGE) from exc
                raise
        # LibRaw's postprocess demosaics and converts color in one call; this time covers both.
        with timed_stage(timings, f"{prefix}.raw_postprocess"):
            image = raw.postprocess(**args)
        meta = {
            "camera_whitebalance": list(raw.camera_whitebalance),
            "white_balance": wb,
            "brightness": bright,
            "width": image.shape[1],
            "height": image.shape[0],
            "demosaic": "VNG",
            "output_color": "raw",
            "bits": 8,
            "auto_bright": False,
        }
    return image, meta


def wb_multipliers(rgb, wb):
    if min(rgb) <= 0 or not np.isfinite(rgb).all():
        raise ValueError(
            "White-balance patch is black or invalid. Select a neutral illuminated area."
        )
    scale = np.array([rgb[1] / rgb[0], 1.0, rgb[1] / rgb[2], 1.0])
    scale /= np.sqrt(np.mean(scale**2))
    current = np.asarray(wb, dtype=float)
    norm = np.sqrt(np.mean(current**2))
    if norm <= 0:
        raise ValueError("Camera white-balance metadata is invalid.")
    result = scale**2 * current / norm
    result[3] = 0.0
    return result.tolist()


def white_balance(path, initial, camera_wb, points, *, timings=None):
    with timed_stage(timings, "white_balance.initial_sample"):
        first_wb = wb_multipliers(sample_rgb(initial, points).mean(axis=0), camera_wb)
    first, _ = render_raw(path, first_wb, timings=timings, prefix="white_balance.pass1")
    with timed_stage(timings, "white_balance.pass1_sample"):
        first_mean = sample_rgb(first, points).mean(axis=0)
        final_wb = wb_multipliers(first_mean, first_wb)
        brightness = float((180 / first_mean[1]) ** 2)
    final, meta = render_raw(
        path, final_wb, brightness, timings=timings, prefix="white_balance.pass2"
    )
    meta.update(
        {
            "first_pass_white_balance": first_wb,
            "first_pass_mean_rgb": first_mean.tolist(),
        }
    )
    return final, meta


def order_corners(points):
    p = points_array(points)
    if len(p) != 4:
        raise ValueError("Place exactly four marker corners.")
    center = p.mean(axis=0)
    cyclic = p[np.argsort(np.arctan2(p[:, 1] - center[1], p[:, 0] - center[0]))]
    signs = [
        cross(cyclic[i], cyclic[(i + 1) % 4], cyclic[(i + 2) % 4]) for i in range(4)
    ]
    if min(signs) <= 0:
        raise ValueError("Marker corners must form a convex quadrilateral.")
    return cyclic[[0, 1, 3, 2]]


def map_patch(corners, uv):
    tl, tr, bl, br = corners
    return [
        {"x": float(p[0]), "y": float(p[1])}
        for u, v in uv
        for p in [
            (1 - u) * (1 - v) * tl + u * (1 - v) * tr + (1 - u) * v * bl + u * v * br
        ]
    ]


def marker_polygons(mode, points):
    c = order_corners(points)
    if mode == "flower_9":
        centers = [
            (0.30, 0.30),
            (0.5, 0.18),
            (0.7, 0.3),
            (0.18, 0.5),
            (0.5, 0.5),
            (0.82, 0.5),
            (0.3, 0.7),
            (0.5, 0.82),
            (0.7, 0.7),
        ]
        patches = []
        for i, (u, v) in enumerate(centers):
            s = 0.075 if i == 4 else 0.065
            offset = np.array([[-s, -s], [s, -s], [s, s], [-s, s]])
            if i in (0, 2, 6, 8):
                t = math.pi / 4
                offset = offset @ np.array(
                    [[math.cos(t), math.sin(t)], [-math.sin(t), math.cos(t)]]
                )
            patches.append(map_patch(c, offset + [u, v]))
        return patches
    landscape = (np.linalg.norm(c[1] - c[0]) + np.linalg.norm(c[3] - c[2])) >= (
        np.linalg.norm(c[2] - c[0]) + np.linalg.norm(c[3] - c[1])
    )
    patches = []
    for x in range(6):
        for y in range(4):
            u, v = 0.05 + x / 6, 0.075 + y / 4
            uv = [(u, v), (u + 1 / 15, v), (u + 1 / 15, v + 0.1), (u, v + 0.1)]
            if not landscape:
                uv = [(b, a) for a, b in uv]
            patches.append(map_patch(c, uv))
    return patches


def fit_calibration(samples, reference):
    samples = np.asarray(samples, dtype=float)
    reference = np.asarray(reference, dtype=float)
    ld = np.column_stack([samples[:, 0], np.ones(len(samples))])
    abd = np.column_stack([samples[:, 1:], np.ones(len(samples))])
    if np.linalg.matrix_rank(ld) < 2 or np.linalg.matrix_rank(abd) < 3:
        raise ValueError("Calibration is degenerate. Select the correct color patches.")
    l, *_ = np.linalg.lstsq(ld, reference[:, 0], rcond=None)
    ab, *_ = np.linalg.lstsq(abd, reference[:, 1:], rcond=None)
    coeff = np.zeros((4, 3))
    coeff[0, 0], coeff[3, 0] = l
    coeff[1:, 1:] = ab
    corrected = np.column_stack([samples, np.ones(len(samples))]) @ coeff
    return {
        "coefficients": coeff.tolist(),
        "rmse": float(np.sqrt(np.mean((corrected - reference) ** 2))),
        "delta_e": np.linalg.norm(corrected - reference, axis=1).tolist(),
        "measured_lab": samples.tolist(),
        "reference_lab": reference.tolist(),
    }


def orientation_candidates(samples, mode, patches):
    if mode == "standard_24_grid":
        grid = np.arange(24).reshape(6, 4)
        options = [(-1, -1, 0), (1, -1, 20), (-1, 1, 3), (1, 1, 23)]
        dx, dy, _ = min(
            options,
            key=lambda o: (
                samples[o[2], 0] * math.ceil(float(np.linalg.norm(samples[o[2], 1:])))
            ),
        )
        return [("dark_corner_order", grid[::dx, ::dy].flatten())]
    if mode == "flower_9_manual":
        centers = np.array([points_array(p).mean(axis=0) for p in patches])
        center = int(np.argmin(np.linalg.norm(centers - centers.mean(axis=0), axis=1)))
        ring = [i for i in range(9) if i != center]
        ring.sort(key=lambda i: math.atan2(*(centers[i] - centers[center])[::-1]))
        reference_ring = [1, 2, 5, 8, 7, 6, 3, 0]
        candidates = []
        for direction in (1, -1):
            for shift in range(8):
                order = [0] * 9
                order[4] = center
                for pos, ref in enumerate(reference_ring):
                    order[ref] = ring[(shift + direction * pos) % 8]
                candidates.append((f"ring_{direction}_{shift}", order))
        return candidates
    candidates = []
    names = [
        "upright",
        "rotate90",
        "rotate180",
        "rotate270",
        "mirror_horizontal",
        "mirror_vertical",
        "mirror_main_diagonal",
        "mirror_anti_diagonal",
    ]
    orders = [[] for _ in names]
    for r in range(3):
        for c in range(3):
            coords = [
                (r, c),
                (c, 2 - r),
                (2 - r, 2 - c),
                (2 - c, r),
                (r, 2 - c),
                (2 - r, c),
                (c, r),
                (2 - c, 2 - r),
            ]
            for order, (a, b) in zip(orders, coords):
                order.append(a * 3 + b)
    return list(zip(names, orders))


def calibrate(image, mode, corners, manual):
    patches = manual if mode == "flower_9_manual" else marker_polygons(mode, corners)
    expected = 24 if mode == "standard_24_grid" else 9
    if len(patches) != expected:
        raise ValueError(f"Draw exactly {expected} calibration patches.")
    samples = np.array([lab_stats(image, p)["median"] for p in patches])
    reference = STANDARD_LAB if expected == 24 else FLOWER_LAB
    fits = []
    for name, order in orientation_candidates(samples, mode, patches):
        fit = fit_calibration(samples[order], reference)
        fit.update({"orientation": name, "sample_order": [int(i) for i in order]})
        fits.append(fit)
    fits.sort(key=lambda f: f["rmse"])
    best = fits[0]
    if expected == 24 and best["rmse"] > STANDARD_24_MAX_RMSE:
        raise ValueError(
            f"Standard 24 calibration RMSE {best['rmse']:.2f} exceeds {STANDARD_24_MAX_RMSE}. Check the marker corners."
        )
    best.update(
        {
            "confidence": fits[1]["rmse"] - best["rmse"] if len(fits) > 1 else None,
            "patches": patches,
            "mode": mode,
            "reference_version": "standard_24" if expected == 24 else FLOWER_VERSION,
        }
    )
    return best


def apply_calibration(lab, coefficients):
    return (np.append(lab, 1.0) @ np.asarray(coefficients)).tolist()


def urea_model(ph):
    if ph is None or not math.isfinite(ph):
        return None
    low, high = UREA_MODEL_LIMITS
    return "pH_6.0" if ph <= low else "pH_6.5" if ph <= high else "pH_7.0"


def ph_value(lab):
    q, k, c = PH_EQUATION["quadratic"], PH_EQUATION["linear"], PH_EQUATION["intercept"]
    d = k**2 - 4 * q * (c - lab[2])
    return (-k - math.sqrt(d)) / (2 * q) if d >= 0 else None


def creatinine_value(lab):
    e = CREATININE_EQUATION
    d = e["offset"] - e["slope"] * lab[1]
    return (e["numerator"] - math.sqrt(d)) / e["denominator"] if d >= 0 else None


def urea_value(lab, model, calibration="lab"):
    return float(np.dot(UREA_CALIBRATIONS[calibration]["models"][model], [1, *lab]))


EQUATION_FUNCTIONS = {"ph": ph_value, "creatinine": creatinine_value}


def equation_version(analyte, model=None, urea_calibration="lab"):
    if analyte == "urea":
        return UREA_CALIBRATIONS[urea_calibration]["version"] + (":" + model if model else "")
    return EQUATIONS[analyte]


INVALID_DOMAIN = "Invalid equation domain or negative concentration; cannot be included."
INVALID_INCLUDED = ("Invalid equation domain or negative concentration; included by the reviewer, "
                    "so it counts in the averages, the prediction and the export.")


def calculate(analyte, lab, ph=None, manual_model=None, urea_calibration="lab"):
    warnings, model = [], None
    value, status = None, "valid"
    if analyte != "urea":
        value = EQUATION_FUNCTIONS[analyte](lab)
    elif manual_model:
        model = manual_model
        value = urea_value(lab, model, urea_calibration)
    elif ph is None or not math.isfinite(ph):
        status = "missing_input"
        warnings.append("Reviewed pH is required for final urea, or choose a urea pH model.")
    else:
        model = urea_model(ph)
        value = urea_value(lab, model, urea_calibration)
        if not 6 <= ph <= 7:
            warnings.append(
                "Endpoint urea model used outside the pH calibration range."
            )
    if status == "valid" and (value is None or not math.isfinite(value) or value < 0):
        if value is not None and not math.isfinite(value):
            value = None
        status = "invalid_domain"
        warnings.append(INVALID_DOMAIN)
    if value is not None and not RANGES[analyte][0] <= value <= RANGES[analyte][1]:
        warnings.append("Outside the provisional software review range.")
    return {
        "value": value,
        "calculation_status": status,
        "warnings": warnings,
        "urea_ph_model": model,
        "unit": UNITS[analyte],
        "equation_version": equation_version(analyte, model if value is not None else None, urea_calibration),
    }


def reservoir_result(reservoir, measurements, ph=None, provisional=False, manual_model=None, urea_calibration="lab"):
    lab = np.mean(
        [measurements[i]["calibrated_median"] for i in reservoir["roi_ids"]], axis=0
    ).tolist()
    result = calculate(reservoir["analyte"], lab, ph, manual_model, urea_calibration)
    for roi_id in reservoir["roi_ids"]:
        if channels := measurements[roi_id].get("outside_calibration"):
            label = measurements[roi_id].get("label") or f"ROI {roi_id}"
            result["warnings"].append(f"{label} color is outside the calibration patch range ({', '.join(channels)}); "
                                      "the calibration extrapolates.")
    if provisional and result["calculation_status"] == "valid":
        result["calculation_status"] = "provisional_input"
        result["warnings"].append(
            "Urea uses provisional pH until eligible pH reviews are resolved."
        )
    status = result["calculation_status"]
    if status == "invalid_domain" and reservoir["review"] == "included" and result["value"] is not None:
        result["warnings"] = [INVALID_INCLUDED if w == INVALID_DOMAIN else w for w in result["warnings"]]
    review = (
        "included"
        if status == "invalid_domain" and reservoir["review"] == "included" and result["value"] is not None
        else "mathematically_invalid"
        if status == "invalid_domain"
        else "excluded"
        if reservoir["review"] == "excluded"
        else "needs_review"
        if status != "valid"
        else "included"
        if reservoir["review"] == "included"
        else "needs_review"
        if result["warnings"]
        else "automatically_included"
    )
    return {**reservoir, **result, "average_lab": lab, "review_status": review}


def outside_calibration_range(lab, reference, margin=0.0):
    reference = np.asarray(reference, dtype=float)
    return [name for name, value, low, high in zip("Lab", lab, reference.min(axis=0), reference.max(axis=0))
            if not low - margin <= value <= high + margin]


def calibration_flags(roi_results, calibration):
    reference = (calibration or {}).get("reference_lab")
    if not reference:
        return {}
    margin = calibration.get("rmse") or 0.0
    flags = {r["id"]: outside_calibration_range(r["calibrated_median"], reference, margin) for r in roi_results}
    return {roi_id: channels for roi_id, channels in flags.items() if channels}


def roi_value(analyte, lab, model, urea_calibration="lab"):
    result = calculate(analyte, lab, None, model, urea_calibration)
    return result["value"] if result["calculation_status"] == "valid" else None


def reservoir_uncertainty(result, measurements, coefficients=None, urea_calibration="lab"):
    analyte, model = result["analyte"], result.get("urea_ph_model")
    if analyte == "urea" and not model:
        return None
    rois = []
    for roi_id in result["roi_ids"]:
        roi = measurements[roi_id]
        spread = []
        if coefficients is not None and "median" in roi and "standard_deviation" in roi:
            median, sd = np.asarray(roi["median"]), np.asarray(roi["standard_deviation"])
            spread = [v for v in (roi_value(analyte, apply_calibration(median + sign * sd, coefficients), model,
                                            urea_calibration) for sign in (-1, 1)) if v is not None]
        value = roi_value(analyte, roi["calibrated_median"], model, urea_calibration)
        rois.append({"roi_id": roi_id, "value": value,
                     "pixel_low": min(spread) if spread else None, "pixel_high": max(spread) if spread else None,
                     "pixel_sd": float(np.mean([abs(v - value) for v in spread])) if spread and value is not None
                     else None})
    values = [r["value"] for r in rois if r["value"] is not None]
    roi_sd = float(np.std(values, ddof=1)) if len(values) > 1 else None
    single = rois[0]["pixel_sd"] if len(rois) == 1 else None
    return {
        "n_rois": len(rois),
        "roi_sd": roi_sd,
        "roi_min": min(values) if values else None,
        "roi_max": max(values) if values else None,
        "sd": roi_sd if roi_sd is not None else single,
        "sd_basis": "rois" if roi_sd is not None else "pixel" if single is not None else None,
        "rois": rois,
    }


def summary_spread(chosen):
    values = [r["value"] for r in chosen]
    if len(values) > 1:
        return float(np.std(values, ddof=1)), "reservoirs"
    spread = chosen[0].get("uncertainty") if chosen else None
    return (spread["sd"], spread["sd_basis"]) if spread else (None, None)


def biomarker_name(reservoir):
    if reservoir.get("analyte") == "custom":
        return reservoir.get("custom_name") or "Custom"
    return reservoir.get("analyte") or ""


def custom_result(reservoir, measurements):
    labs = [measurements[i]["calibrated_median"] for i in reservoir["roi_ids"]]
    warnings = [f"{measurements[i].get('label') or f'ROI {i}'} color is outside the calibration patch range "
                f"({', '.join(measurements[i]['outside_calibration'])})."
                for i in reservoir["roi_ids"] if measurements[i].get("outside_calibration")]
    return {**reservoir, "value": None, "unit": "", "calculation_status": "no_equation",
            "review_status": "not_applicable", "warnings": warnings, "urea_ph_model": None, "equation_version": "",
            "average_lab": np.mean(labs, axis=0).tolist(),
            "uncertainty": {"n_rois": len(labs),
                            "lab_sd": np.std(labs, axis=0, ddof=1).tolist() if len(labs) > 1 else None,
                            "rois": [{"roi_id": i, "lab": measurements[i]["calibrated_median"],
                                      "pixel_sd": measurements[i].get("standard_deviation")}
                                     for i in reservoir["roi_ids"]]}}


def is_included(result):
    if result["review_status"] == "included" and result["calculation_status"] == "invalid_domain":
        return result["value"] is not None
    return result["calculation_status"] == "valid" and result["review_status"] in (
        "included",
        "automatically_included",
    )


def classifier(urea, creatinine, age, sex):
    if (
        urea is None
        or creatinine is None
        or age is None
        or not all(math.isfinite(v) for v in (urea, creatinine, age))
        or age <= 0
        or sex not in ("male", "female")
    ):
        return {
            "status": "not_calculated",
            "reason": "Final urea, creatinine, age and sex are required.",
        }
    c = CLASSIFIER
    z = c["intercept"] - c["urea"] * urea - c["creatinine"] * creatinine - c["age"] * age + c["male"] * (sex == "male")
    p = math.exp(-z) / (1 + math.exp(-z)) if z >= 0 else 1 / (1 + math.exp(z))
    return {
        "status": "complete",
        "probability": p,
        "threshold": c["threshold"],
        "classification": "Predicted G3+" if p >= c["threshold"] else "Predicted G1-2",
        "urea_mM": urea,
        "creatinine_uM": creatinine,
        "age_years": age,
        "sex": sex,
        "equation_version": c["version"],
    }


def logistic(logit):
    return 1 / (1 + math.exp(-logit)) if logit >= 0 else math.exp(logit) / (1 + math.exp(logit))


def single_classifier(analyte, value, age, sex):
    if value is None or age is None or not all(math.isfinite(v) for v in (value, age)) or age <= 0 \
            or sex not in ("male", "female"):
        return {"status": "not_calculated", "reason": f"Final {analyte}, age and sex are required."}
    c = SINGLE_CLASSIFIERS[analyte]
    p = logistic(c["intercept"] + c["analyte"] * value + c["age"] * age + c["male"] * (sex == "male"))
    return {
        "status": "complete",
        "probability": p,
        "threshold": c["threshold"],
        "classification": "Predicted G3+" if p >= c["threshold"] else "Predicted G1-2",
        "urea_mM": value if analyte == "urea" else None,
        "creatinine_uM": value if analyte == "creatinine" else None,
        "age_years": age,
        "sex": sex,
        "equation_version": c["version"],
    }


def predict(urea, creatinine, age, sex, choice=None):
    available = [name for name, ready in (("full", urea is not None and creatinine is not None),
                                          ("creatinine", creatinine is not None), ("urea", urea is not None)) if ready]
    model = choice or (available[0] if available else "full")
    result = classifier(urea, creatinine, age, sex) if model == "full" else single_classifier(
        model, urea if model == "urea" else creatinine, age, sex)
    if not available and not choice:
        result["reason"] = "Final urea or creatinine, age and sex are required."
    return {**result, "model": model, "model_label": CLASSIFIER_LABELS[model],
            "model_source": "manual" if choice else "automatic", "available_models": available,
            "auc": SINGLE_CLASSIFIERS.get(model, {}).get("auc")}


def concentration_results(draft, roi_results, calibration=None):
    manual = draft.get("urea_ph_model")
    urea_calibration = draft.get("urea_calibration") or "lab"
    outside = calibration_flags(roi_results, calibration)
    flagged = [{"roi_id": roi_id, "channels": channels} for roi_id, channels in outside.items()]
    measurements = {r["id"]: {**r, "outside_calibration": outside.get(r["id"], [])} for r in roi_results}
    eligible = [r for r in draft["reservoirs"] if r["analyte"] and r["roi_ids"]]
    if not roi_results or (draft["mode"] == "standard_24_grid" and not eligible):
        return {
            "reservoirs": [],
            "summaries": {},
            "ph_ready_for_urea": False,
            "urea_ph_model": {"source": "manual" if manual else None, "selected": manual, "nearest": None},
            "outside_calibration": flagged,
            "prediction": classifier(None, None, draft["age"], draft["sex"]),
        }
    custom = [custom_result(r, measurements) for r in eligible if r["analyte"] == "custom"]
    eligible = [r for r in eligible if r["analyte"] != "custom"]
    ph_results = [
        reservoir_result(r, measurements) for r in eligible if r["analyte"] == "ph"
    ]
    included = [r["value"] for r in ph_results if is_included(r)]
    valid_ph = [r for r in ph_results if r["calculation_status"] == "valid"]
    ph_review_complete = bool(valid_ph) and all(
        r["review_status"] != "needs_review" for r in valid_ph
    )
    final_ph = (
        float(np.mean(included))
        if included and ph_review_complete
        else None
    )
    provisional_ph = (
        float(np.mean([r["value"] for r in valid_ph])) if valid_ph else None
    )
    results = ph_results + [
        reservoir_result(
            r,
            measurements,
            # With no manual model, excluding every reviewed pH gives urea no
            # input; only unresolved pH reviews provide provisional pH (QDAQ).
            final_ph if ph_review_complete else provisional_ph,
            not manual and not ph_review_complete and provisional_ph is not None,
            manual,
            urea_calibration,
        )
        for r in eligible
        if r["analyte"] != "ph"
    ]
    # Creatinine does not depend on pH, the urea model or the urea calibration.
    results = [
        reservoir_result(r, measurements) if r["analyte"] == "creatinine" else r
        for r in results
    ]
    coefficients = (calibration or {}).get("coefficients")
    results = [{**r, "uncertainty": reservoir_uncertainty(r, measurements, coefficients, urea_calibration)}
               for r in results] + custom
    summaries = {}
    for analyte in UNITS:
        chosen = [r for r in results if r["analyte"] == analyte and is_included(r)]
        sd, sd_basis = summary_spread(chosen)
        summaries[analyte] = {
            "value": float(np.mean([r["value"] for r in chosen])) if chosen else None,
            "sd": sd,
            "sd_basis": sd_basis,
            "unit": UNITS[analyte],
            "included_ids": [r["id"] for r in chosen],
            "values": [{"reservoir_id": r["id"], "value": r["value"], "condition": r.get("condition", ""),
                        "replicate": r.get("replicate", "")} for r in chosen],
            "min": min((r["value"] for r in chosen), default=None),
            "max": max((r["value"] for r in chosen), default=None),
            "note": "One included reservoir; no duplicate redundancy."
            if len(chosen) == 1
            else "",
        }
    return {
        "reservoirs": sorted(results, key=lambda r: r["id"]),
        "summaries": summaries,
        "ph_ready_for_urea": final_ph is not None,
        "outside_calibration": flagged,
        "urea_calibration": urea_calibration,
        "urea_ph_model": {
            "source": "manual" if manual else "measured" if final_ph is not None
            else "provisional" if provisional_ph is not None else None,
            "selected": manual or urea_model(final_ph if final_ph is not None else provisional_ph),
            "nearest": urea_model(final_ph if final_ph is not None else provisional_ph),
        },
        "prediction": predict(
            summaries["urea"]["value"],
            summaries["creatinine"]["value"],
            draft["age"],
            draft["sex"],
            draft.get("classifier_model"),
        ),
    }


def refresh_concentrations(draft, results, calibration=None):
    return {**results, **concentration_results(draft, results["rois"], calibration)}


VERSION_LABELS = {
    "app": "CKD Colorimetry app",
    "engine": "Scientific engine",
    "configuration": "Equations",
    "flower_reference": "Flower 9 reference colors",
    "rawpy": "rawpy",
    "libraw": "LibRaw",
    "numpy": "NumPy",
    "scikit_image": "scikit-image",
    "python": "Python",
}
MEASUREMENT_VERSIONS = {"engine", "flower_reference", "rawpy", "libraw", "numpy", "scikit_image"}
IOS_UNUSED_VERSIONS = {"python", "rawpy", "numpy", "scikit_image"}


def equation_info():
    low, high = UREA_MODEL_LIMITS
    return {
        "versions": versions(),
        "equations": EQUATIONS,
        "ranges": {name: {"minimum": lo, "maximum": hi, "unit": UNITS[name]} for name, (lo, hi) in RANGES.items()},
        "ph": PH_EQUATION,
        "creatinine": CREATININE_EQUATION,
        "urea": [
            {"model": name, "applies": applies, "coefficients": UREA_MODELS[name]}
            for name, applies in (("pH_6.0", f"pH ≤ {low}"), ("pH_6.5", f"{low} < pH ≤ {high}"), ("pH_7.0", f"pH > {high}"))
        ],
        "urea_calibrations": [
            {"key": key, "label": item["label"], "version": item["version"],
             "models": [{"model": name, "coefficients": coefficients} for name, coefficients in item["models"].items()]}
            for key, item in UREA_CALIBRATIONS.items()
        ],
        "classifier": CLASSIFIER,
        "classifiers": [
            {"model": name, "label": CLASSIFIER_LABELS[name], **coefficients}
            for name, coefficients in SINGLE_CLASSIFIERS.items()
        ],
        "calibration": {"flower_reference": FLOWER_VERSION, "standard_24_max_rmse": STANDARD_24_MAX_RMSE},
    }


def result_values(results):
    rows = [
        (f"Reservoir {r['id']} {r['analyte']}", r["value"], r["unit"], r["calculation_status"], r["review_status"])
        for r in results.get("reservoirs", [])
    ]
    rows += [
        (f"Final {name}", item["value"], item["unit"], None, None)
        for name, item in results.get("summaries", {}).items()
    ]
    prediction = results.get("prediction") or {}
    rows.append(("CKD prediction", prediction.get("probability"), "probability", prediction.get("status"),
                 prediction.get("classification")))
    return rows


def calculated_on(results):
    return "ios" if (results.get("versions") or {}).get("platform") == "ios" else "mac"


def same_value(a, b):
    if a is None or b is None:
        return a is None and b is None
    return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12)


def compare_results(draft, results, calibration=None):
    saved = results.get("versions") or {}
    current = versions()
    platform = calculated_on(results)
    rows = []
    for key, label in VERSION_LABELS.items():
        applies = not (platform == "ios" and key in IOS_UNUSED_VERSIONS)
        rows.append({"key": key, "label": label, "saved": saved.get(key), "current": current[key],
                     "applies": applies, "differs": applies and saved.get(key) != current[key]})
    differing = {row["key"] for row in rows if row["differs"]}
    remeasure = bool(differing & MEASUREMENT_VERSIONS)
    preview = None if remeasure else refresh_concentrations(draft, results, calibration)
    values = []
    for index, (label, value, unit, status, review) in enumerate(result_values(results)):
        after = result_values(preview)[index] if preview else None
        values.append({"label": label, "unit": unit, "saved": value, "saved_status": status, "saved_review": review,
                       "current": after[1] if after else None, "current_status": after[3] if after else None,
                       "changed": None if after is None
                       else not (same_value(after[1], value) and after[2:4] == (unit, status))})
    return {
        "outdated": bool(differing),
        "calculated_with": saved.get("app") or "1.2 or earlier",
        "calculated_on": platform,
        "current_app": current["app"],
        "affects_values": bool(differing & (MEASUREMENT_VERSIONS | {"configuration"})),
        "needs_remeasure": remeasure,
        "versions": rows,
        "values": values,
    }


def reset_changed_reviews(draft, before, after):
    previous = {r["id"]: (r["value"], r["calculation_status"]) for r in (before or {}).get("reservoirs", [])}
    changed = []
    for result in after["reservoirs"]:
        value, status = previous.get(result["id"], (None, None))
        if result["id"] in previous and not (same_value(value, result["value"]) and status == result["calculation_status"]):
            reservoir = next(r for r in draft["reservoirs"] if r["id"] == result["id"])
            if reservoir["review"] != "needs_review":
                reservoir.update(review="needs_review", reason="")
                changed.append(result["id"])
    return changed


def rgba_chunks(image, rows=256):
    for start in range(0, image.shape[0], rows):
        block = np.asarray(image[start : start + rows])
        rgba = np.empty(block.shape[:2] + (4,), dtype=np.uint8)
        rgba[..., :3] = block
        rgba[..., 3] = 255
        yield rgba.tobytes()


def rgba_digest(image):
    result = hashlib.sha256()
    for chunk in rgba_chunks(image):
        result.update(chunk)
    return result.hexdigest()


def roi_overlay(image, rois):
    overlay = Image.fromarray(np.asarray(image))
    painter = ImageDraw.Draw(overlay)
    for roi in rois:
        xy = [(p["x"], p["y"]) for p in roi["points"]]
        painter.line(xy + [xy[0]], fill="#08a89c", width=max(2, image.shape[1] // 600))
        painter.text(xy[0], f"ROI {roi['id']}", fill="#ffdf00")
    return overlay


def measure_rois(image, draft, calibration):
    results = []
    for roi in draft["rois"]:
        stats = lab_stats(image, roi["points"])
        results.append(
            {
                "id": roi["id"],
                "label": roi["label"],
                **stats,
                "calibrated_median": apply_calibration(
                    stats["median"], calibration["coefficients"]
                ),
                "calibrated_mean": apply_calibration(
                    stats["mean"], calibration["coefficients"]
                ),
            }
        )
    return {
        "schema_name": "ckd_results",
        "schema_version": 1,
        "rois": results,
        **concentration_results(draft, results, calibration),
        "versions": versions(),
        "calculated_at": now(),
        "review_ranges": RANGES,
        "scientific_status": "research_configuration_pending_validation",
    }


def csv_value(value):
    if isinstance(value, (list, dict)):
        return json.dumps(value)
    if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@")):
        return "'" + value
    return value


def with_identity(rows, fields, identity):
    if not identity:
        return rows, fields
    return [{**identity, **row} for row in rows], IDENTITY_FIELDS + fields if fields else None


def csv_text(rows, fields=None):
    output = io.StringIO()
    if rows or fields:
        writer = csv.DictWriter(output, fieldnames=fields or list(rows[0]))
        writer.writeheader()
        for row in rows:
            writer.writerow({k: csv_value(v) for k, v in row.items()})
    return output.getvalue()


def export_tables(results, identity=None):
    reservoir_fields = "reservoir_id,reservoir_label,analyte,roi_ids,roi_count,minimum_roi_count,maximum_roi_count,reservoir_completeness,average_l_star,average_a_star,average_b_star,calculated_value,unit,equation_version,calculation_status,review_status,included_in_summary,message_severity,exclusion_reason,messages".split(
        ","
    )
    reservoir_rows, notes = [], []
    for r in results["reservoirs"]:
        severity = (
            "error"
            if r["calculation_status"] == "invalid_domain"
            else "warning"
            if r["warnings"]
            else "info"
        )
        messages = r["warnings"] + [
            f"Reservoir LAB used the arithmetic mean of {len(r['roi_ids'])} ROI calibrated median(s).",
            f"Review status: {r['review_status']}.",
        ]
        reservoir_rows.append(
            dict(
                zip(
                    reservoir_fields,
                    [
                        r["id"],
                        f"Reservoir {r['id']}: {r['custom_name']}" if r.get("custom_name") and r["analyte"] == "custom"
                        else f"Reservoir {r['id']}",
                        r["analyte"],
                        ";".join(map(str, r["roi_ids"])),
                        len(r["roi_ids"]),
                        1,
                        "",
                        "valid",
                        *r["average_lab"],
                        r["value"],
                        r["unit"],
                        r["equation_version"],
                        r["calculation_status"],
                        r["review_status"],
                        "true" if is_included(r) else "false",
                        severity,
                        r["reason"],
                        " | ".join(messages),
                    ],
                )
            )
        )
        notes.extend(
            {
                "code": f"reservoir_{r['id']}_{index + 1}",
                "category": "result",
                "severity": severity,
                "message": message,
            }
            for index, message in enumerate(messages)
        )
    summary_fields = "analyte,included_reservoir_ids,excluded_reservoir_ids,final_value,unit,duplicate_count_used,aggregation_method,status,messages".split(
        ","
    )
    summary_rows = []
    for name, s in results["summaries"].items():
        n = len(s["included_ids"])
        excluded = [
            r["id"]
            for r in results["reservoirs"]
            if r["analyte"] == name and r["review_status"] == "excluded"
        ]
        summary_rows.append(
            dict(
                zip(
                    summary_fields,
                    [
                        name,
                        ";".join(map(str, s["included_ids"])),
                        ";".join(map(str, excluded)),
                        s["value"],
                        s["unit"],
                        n,
                        "arithmetic_mean_of_complete_reservoir_concentrations"
                        if n > 1
                        else "single_complete_reservoir"
                        if n
                        else "none",
                        "complete" if s["value"] is not None else "incomplete",
                        s["note"],
                    ],
                )
            )
        )
    prediction_fields = "urea_mM,creatinine_uM,age_years,sex,male_indicator,equation_version,probability,threshold,classification,status,message".split(
        ","
    )
    prediction = {k: results["prediction"].get(k, "") for k in prediction_fields}
    if prediction["status"] == "complete":
        prediction["male_indicator"] = int(prediction["sex"] == "male")
    prediction["message"] = results["prediction"].get("reason", "")
    labels = {r["id"]: r.get("label") or f"ROI {r['id']}" for r in results.get("rois", [])}
    for flag in results.get("outside_calibration", []):
        notes.append(
            {
                "code": "roi_outside_calibration_range",
                "category": "calibration",
                "severity": "warning",
                "message": f"{labels.get(flag['roi_id'], flag['roi_id'])} color is outside the calibration patch range "
                           f"({', '.join(flag['channels'])}).",
            }
        )
    if results.get("urea_calibration") == "ab":
        notes.append(
            {
                "code": "urea_calibration_ab",
                "category": "calculation",
                "severity": "info",
                "message": f"Urea used the {UREA_CALIBRATIONS['ab']['label']} calibration.",
            }
        )
    model = results["prediction"].get("model")
    if model and (model != "full" or results["prediction"].get("model_source") == "manual"):
        auc = results["prediction"].get("auc")
        notes.append(
            {
                "code": "prediction_model",
                "category": "prediction",
                "severity": "info",
                "message": f"Prediction used the {CLASSIFIER_LABELS[model]} model"
                           f" ({results['prediction'].get('model_source')} choice"
                           f"{f', AUC {auc}' if auc else ''}).",
            }
        )
    chosen = results.get("urea_ph_model") or {}
    if chosen.get("source") == "manual":
        notes.append(
            {
                "code": "urea_ph_model_manual",
                "category": "calculation",
                "severity": "info",
                "message": f"Urea used the manually selected {chosen['selected']} model.",
            }
        )
    notes.append(
        {
            "code": "research_validation_pending",
            "category": "validation",
            "severity": "info",
            "message": "Research configuration pending assay and classifier validation.",
        }
    )
    tables = {
        "results.csv": (results["rois"], None),
        "05_reservoirs.csv": (reservoir_rows, reservoir_fields),
        "06_analytes.csv": (summary_rows, summary_fields),
        "07_prediction.csv": ([prediction], prediction_fields),
        "08_notes.csv": (notes, None),
        "09_roi_results.csv": roi_result_rows(results),
        "10_reservoir_results.csv": reservoir_result_rows(results),
        "11_analyte_results.csv": analyte_result_rows(results),
        "12_prediction_details.csv": prediction_detail_rows(results),
    }
    return {name: csv_text(*with_identity(rows, fields, identity)) for name, (rows, fields) in tables.items()}


def joined(values):
    return ";".join(str(v) for v in values)


def analyte_context(results, reservoir):
    summary = results.get("summaries", {}).get(reservoir.get("analyte")) or {}
    return [summary.get("value"), summary.get("sd"), len(summary.get("included_ids", []))]


def urea_context(results, reservoir):
    if reservoir.get("analyte") != "urea":
        return [reservoir.get("urea_ph_model"), None]
    return [reservoir.get("urea_ph_model"), results.get("urea_calibration") or "lab"]


ROI_RESULT_FIELDS = (
    "reservoir_id,condition,replicate,biomarker,roi_id,roi_label,value,unit,value_sd,pixel_low,pixel_high,"
    "reservoir_value,reservoir_sd,sd_basis,reservoir_n_rois,reservoir_included,review_status,calculation_status,"
    "equation_version,urea_ph_model,urea_calibration,analyte_final_value,analyte_final_sd,analyte_n_reservoirs,"
    "pixel_count,raw_l_star,raw_a_star,raw_b_star,raw_mean_l_star,raw_mean_a_star,raw_mean_b_star,pixel_sd_l_star,"
    "pixel_sd_a_star,pixel_sd_b_star,calibrated_l_star,calibrated_a_star,calibrated_b_star,calibrated_mean_l_star,"
    "calibrated_mean_a_star,calibrated_mean_b_star,outside_calibration,warnings"
).split(",")


def roi_result_rows(results):
    owners = {roi_id: r for r in results.get("reservoirs", []) for roi_id in r["roi_ids"]}
    flags = {f["roi_id"]: ";".join(f["channels"]) for f in results.get("outside_calibration", [])}
    rows = []
    for roi in results.get("rois", []):
        reservoir = owners.get(roi["id"], {})
        spread = reservoir.get("uncertainty") or {}
        own = next((r for r in spread.get("rois", []) if r["roi_id"] == roi["id"]), {})
        pixel_sd = own.get("pixel_sd")
        rows.append(dict(zip(ROI_RESULT_FIELDS, [
            reservoir.get("id"), reservoir.get("condition"), reservoir.get("replicate"), biomarker_name(reservoir),
            roi["id"], roi.get("label"), own.get("value"), reservoir.get("unit"),
            pixel_sd if not isinstance(pixel_sd, list) else None, own.get("pixel_low"), own.get("pixel_high"),
            reservoir.get("value"), spread.get("sd"), spread.get("sd_basis"), len(reservoir.get("roi_ids", [])) or None,
            str(is_included(reservoir)).lower() if reservoir else None, reservoir.get("review_status"),
            reservoir.get("calculation_status"), reservoir.get("equation_version"), *urea_context(results, reservoir),
            *(analyte_context(results, reservoir) if reservoir else [None] * 3), roi.get("pixel_count"),
            *(roi.get("median") or [None] * 3), *(roi.get("mean") or [None] * 3),
            *(roi.get("standard_deviation") or [None] * 3), *roi["calibrated_median"],
            *(roi.get("calibrated_mean") or [None] * 3), flags.get(roi["id"]), joined(reservoir.get("warnings", [])),
        ])))
    return rows, ROI_RESULT_FIELDS


RESERVOIR_RESULT_FIELDS = (
    "reservoir_id,condition,replicate,biomarker,roi_ids,n_rois,value,unit,sd,sd_basis,roi_min,roi_max,"
    "average_l_star,average_a_star,average_b_star,calculation_status,review_status,included_in_average,"
    "exclusion_reason,equation_version,urea_ph_model,urea_calibration,analyte_final_value,analyte_final_sd,"
    "analyte_n_reservoirs,warnings"
).split(",")


def reservoir_result_rows(results):
    rows = []
    for r in results.get("reservoirs", []):
        spread = r.get("uncertainty") or {}
        rows.append(dict(zip(RESERVOIR_RESULT_FIELDS, [
            r["id"], r.get("condition"), r.get("replicate"), biomarker_name(r), joined(r["roi_ids"]), len(r["roi_ids"]),
            r["value"], r["unit"], spread.get("sd"), spread.get("sd_basis"), spread.get("roi_min"), spread.get("roi_max"),
            *r["average_lab"], r["calculation_status"], r["review_status"], str(is_included(r)).lower(),
            r.get("reason"), r["equation_version"], *urea_context(results, r), *analyte_context(results, r),
            joined(r["warnings"]),
        ])))
    return rows, RESERVOIR_RESULT_FIELDS


ANALYTE_RESULT_FIELDS = (
    "analyte,final_value,unit,sd,sd_basis,n_included,included_reservoir_ids,included_values,included_conditions,"
    "included_replicates,min,max,aggregation,excluded_reservoir_ids,needs_review_reservoir_ids,urea_calibration,"
    "urea_ph_model,urea_ph_model_source,note"
).split(",")


def analyte_result_rows(results):
    rows = []
    model = results.get("urea_ph_model") or {}
    for name, s in results.get("summaries", {}).items():
        reservoirs = [r for r in results.get("reservoirs", []) if r["analyte"] == name]
        values = s.get("values", [])
        rows.append(dict(zip(ANALYTE_RESULT_FIELDS, [
            name, s["value"], s["unit"], s.get("sd"), s.get("sd_basis"), len(s["included_ids"]), joined(s["included_ids"]),
            joined(v["value"] for v in values), joined(v["condition"] for v in values),
            joined(v["replicate"] for v in values), s.get("min"), s.get("max"),
            "mean" if len(values) > 1 else "single" if values else "none",
            joined(r["id"] for r in reservoirs if r["review_status"] == "excluded"),
            joined(r["id"] for r in reservoirs if r["review_status"] == "needs_review"),
            *((results.get("urea_calibration") or "lab", model.get("selected"), model.get("source"))
              if name == "urea" else (None, None, None)), s.get("note"),
        ])))
    return rows, ANALYTE_RESULT_FIELDS


PREDICTION_DETAIL_FIELDS = (
    "status,model,model_label,model_source,available_models,urea_mM,creatinine_uM,age_years,sex,probability,"
    "threshold,auc,classification,equation_version,urea_calibration,urea_ph_model,reason"
).split(",")


def prediction_detail_rows(results):
    p = results.get("prediction") or {}
    return [dict(zip(PREDICTION_DETAIL_FIELDS, [
        p.get("status"), p.get("model"), p.get("model_label"), p.get("model_source"), joined(p.get("available_models", [])),
        p.get("urea_mM"), p.get("creatinine_uM"), p.get("age_years"), p.get("sex"), p.get("probability"),
        p.get("threshold"), p.get("auc"), p.get("classification"), p.get("equation_version"),
        results.get("urea_calibration") or "lab", (results.get("urea_ph_model") or {}).get("selected"), p.get("reason"),
    ]))], PREDICTION_DETAIL_FIELDS


def fixed(value):
    return "" if value is None else f"{value:.6f}"


def lab_cells(lab):
    return [fixed(v) for v in lab] if lab is not None else ["", "", ""]


def lab_fields(prefix):
    return [f"{prefix}_{channel}_star_{kind}" for kind in ("median", "mean", "std") for channel in "lab"]


def calibrated_pixels(image, points, coefficients):
    lab = rgb2lab(sample_rgb(image, points).reshape(-1, 1, 3)).reshape(-1, 3)
    return np.column_stack([lab, np.ones(len(lab))]) @ np.asarray(coefficients)


def ordered_lab(stats):
    return [value for kind in ("median", "mean", "standard_deviation") for value in stats[kind]]


def patch_measurements_csv(image, calibration, identity=None):
    fields = ["patch_id", "geometry_orientation", "patch_order", "reference_position", "sampled_position",
              "grid_x", "grid_y", "polygon_points", "pixel_count", *lab_fields("raw"), *lab_fields("calibrated"),
              "reference_l_star", "reference_a_star", "reference_b_star", "corrected_residual_l_star",
              "corrected_residual_a_star", "corrected_residual_b_star", "delta_e"]
    rows = []
    for position, index in enumerate(calibration["sample_order"]):
        points = calibration["patches"][index]
        stats = lab_stats(image, points)
        corrected = calibrated_pixels(image, points, calibration["coefficients"])
        median = apply_calibration(stats["median"], calibration["coefficients"])
        reference = calibration["reference_lab"][position]
        grid = {"flower_9": (index % 3, index // 3), "standard_24_grid": (index // 4, index % 4)}.get(calibration["mode"], ("", ""))
        values = [position + 1, calibration["orientation"], index + 1, position + 1, index + 1, *grid,
                  ";".join(f"{fixed(p['x'])}:{fixed(p['y'])}" for p in points), stats["pixel_count"],
                  *[fixed(v) for v in ordered_lab(stats)], *lab_cells(median),
                  *lab_cells(apply_calibration(stats["mean"], calibration["coefficients"])),
                  *lab_cells(corrected.std(axis=0)), *lab_cells(reference),
                  *lab_cells(np.subtract(median, reference)), fixed(calibration["delta_e"][position])]
        rows.append(dict(zip(fields, values)))
    return csv_text(*with_identity(rows, fields, identity))


def roi_measurements_csv(image, draft, results, calibration, identity=None):
    fields = ["roi_id", "roi_label", "polygon_points", "pixel_count", *lab_fields("raw"), *lab_fields("calibrated")]
    points = {roi["id"]: roi["points"] for roi in draft["rois"]}
    rows = []
    for roi in results["rois"]:
        spread = calibrated_pixels(image, points[roi["id"]], calibration["coefficients"]).std(axis=0)
        values = [roi["id"], roi["label"], ";".join(f"{fixed(p['x'])}:{fixed(p['y'])}" for p in points[roi["id"]]),
                  roi["pixel_count"], *[fixed(v) for v in ordered_lab(roi)], *lab_cells(roi["calibrated_median"]),
                  *lab_cells(roi["calibrated_mean"]), *lab_cells(spread)]
        rows.append(dict(zip(fields, values)))
    return csv_text(*with_identity(rows, fields, identity))


def coordinate_package(doc):
    d, source = doc["draft"], doc["source"]
    return {
        "schema_name": "qdaq_ckd_coordinate_package",
        "schema_version": 2,
        "coordinate_system": "top_left_image_pixels",
        "source_image_filename": source["filename"],
        "source_image_sha256": source["sha256"],
        "image_dimensions": {"width": source["width"], "height": source["height"]},
        "calibration_marker_kind": "standard_24"
        if d["mode"] == "standard_24_grid"
        else "flower_9",
        "calibration_mode": d["mode"],
        "white_balance_polygon": {"points": d["white_balance"]},
        "color_calibration_corners": d["corners"],
        "manual_color_calibration_polygons": [
            {"points": p} for p in d["manual_patches"]
        ],
        "reservoir_geometry_version": "manual_polygon_v2",
        "reservoirs": [
            {
                "reservoir_id": r["id"],
                "label": f"Reservoir {r['id']}",
                "analyte": r["analyte"],
                "custom_name": r.get("custom_name", ""),
                "condition": r.get("condition", ""),
                "replicate": r.get("replicate", ""),
                "roi_ids": r["roi_ids"],
                "review_status": "needs_review",
                "exclusion_reason": None,
            }
            for r in d["reservoirs"]
        ],
        "rois": [
            {
                "roi_id": r["id"],
                "roi_label": r["label"],
                "polygon": {"points": r["points"]},
            }
            for r in d["rois"]
        ],
    }


def import_coordinates(package, doc):
    from .models import Draft

    if package.get("schema_name") != "qdaq_ckd_coordinate_package" or package.get(
        "schema_version"
    ) not in (1, 2):
        raise ValueError("Expected a QDAQ CKD coordinate package version 1 or 2.")
    if package.get("coordinate_system") != "top_left_image_pixels":
        raise ValueError("Coordinates must use top-left original image pixels.")
    source = doc["source"]
    if package.get("source_image_sha256") != source["sha256"] or package.get(
        "image_dimensions"
    ) != {"width": source["width"], "height": source["height"]}:
        raise ValueError(
            "Coordinate source hash or dimensions do not match this image."
        )
    mode = package.get("calibration_mode") or (
        "standard_24_grid"
        if package.get("calibration_marker_kind") == "standard_24"
        else "flower_9"
    )
    if len(package.get("reservoirs", [])) > MAX_RESERVOIRS:
        raise ValueError(f"Coordinate packages can contain at most {MAX_RESERVOIRS} reservoirs.")
    return Draft(
        title=doc["draft"]["title"],
        mode=mode,
        white_balance=(package.get("white_balance_polygon") or {}).get("points", []),
        corners=package.get("color_calibration_corners", []),
        manual_patches=[
            p["points"] for p in package.get("manual_color_calibration_polygons", [])
        ],
        rois=[
            {
                "id": r["roi_id"],
                "label": r["roi_label"],
                "points": r["polygon"]["points"],
            }
            for r in package.get("rois", [])
        ],
        reservoirs=[
            {
                "id": r["reservoir_id"],
                "analyte": r.get("analyte"),
                "custom_name": r.get("custom_name") or "",
                "condition": r.get("condition") or "",
                "replicate": r.get("replicate") or "",
                "roi_ids": r["roi_ids"],
            }
            for r in package.get("reservoirs", [])
        ],
    ).model_dump()
