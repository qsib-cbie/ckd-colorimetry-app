import json
import time
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from skimage.color import lab2rgb, rgb2lab
from skimage.draw import polygon

from ckd.models import Draft, Reservoir
from ckd.utils import FLOWER_LAB, IDENTITY_FIELDS, marker_polygons

FIXTURES = Path(__file__).parent / "fixtures"

SWIFT_LAB_ATOL = 0.01
SWIFT_CONCENTRATION_ATOL = {"ph": 0.001, "urea": 0.05, "creatinine": 0.05}


def swift_reference(name):
    return json.loads((FIXTURES / "swift_core" / name).read_text())


def swift_lab(lab):
    return [lab[k] for k in ("l_star", "a_star", "b_star")]


def open_polygon(points):
    return points[:-1] if len(points) > 1 and points[0] == points[-1] else points


def assert_same_polygon(actual, expected):
    a = np.array([[p["x"], p["y"]] for p in open_polygon(actual)])
    e = np.array([[p["x"], p["y"]] for p in open_polygon(expected)])
    assert a.shape == e.shape
    assert any(
        np.allclose(a, np.roll(candidate, shift, axis=0), atol=1e-9, rtol=0)
        for candidate in (e, e[::-1])
        for shift in range(len(e))
    ), (a, e)


def oracle_number(value):
    return float(value) if isinstance(value, str) else value


def swift_draft(inputs, wb=None):
    reservoirs = {r["reservoir_id"]: r for r in inputs.get("reservoirs", [])}
    rois = inputs.get("rois", inputs.get("roi_results", []))
    return Draft(
        mode=inputs.get("mode", "flower_9"),
        age=inputs.get("age"),
        sex=inputs.get("sex"),
        classifier_model="full",
        white_balance=wb or [],
        corners=inputs.get("corners", []),
        manual_patches=[p["points"] for p in inputs.get("manual", [])],
        rois=[
            {
                "id": r["roi_id"],
                "label": r["roi_label"],
                "points": r["polygon"]["points"] or rectangle(),
            }
            for r in rois
        ],
        reservoirs=[
            Reservoir(
                id=i,
                analyte=r.get("analyte"),
                roi_ids=r.get("roi_ids", []),
                review=r.get("review_status", "needs_review"),
                reason=r.get("exclusion_reason") or "",
            )
            for i in range(1, 7)
            for r in [reservoirs.get(i, {})]
        ],
    ).model_dump()


def swift_roi_measurements(rois):
    return [
        {
            "id": r["roi_id"],
            "calibrated_median": swift_lab(r["calibrated_median"]),
            "calibrated_mean": swift_lab(r["calibrated_mean"]),
            "pixel_count": r["pixel_count"],
        }
        for r in rois
    ]


def assert_swift_concentrations(actual, expected, *, same_lab=True):
    tolerances = (
        {a: 1e-9 for a in ("ph", "urea", "creatinine")}
        if same_lab
        else SWIFT_CONCENTRATION_ATOL
    )
    want_results = expected["results"]
    assert set(actual["summaries"]) == {
        s["analyte"] for s in want_results["analyte_summaries"]
    }
    assert len(actual["reservoirs"]) == len(want_results["reservoir_results"])
    for a, e in zip(
        actual["reservoirs"],
        sorted(want_results["reservoir_results"], key=lambda r: r["reservoir_id"]),
    ):
        assert a["id"] == e["reservoir_id"]
        for key in (
            "analyte",
            "roi_ids",
            "unit",
            "equation_version",
            "calculation_status",
            "review_status",
        ):
            assert a[key] == e[key], (a["id"], key)
        np.testing.assert_allclose(
            a["average_lab"],
            swift_lab(e["average_lab"]),
            rtol=0,
            atol=1e-9 if same_lab else SWIFT_LAB_ATOL,
        )
        assert a["value"] == pytest.approx(
            e.get("calculated_value"), rel=0, abs=tolerances[a["analyte"]]
        )
        assert bool(a["warnings"]) == bool(e["warnings"])
    for e in want_results["analyte_summaries"]:
        a = actual["summaries"][e["analyte"]]
        assert a["included_ids"] == e["included_reservoir_ids"]
        assert a["unit"] == e["unit"]
        assert a["value"] == pytest.approx(
            e.get("final_value"), rel=0, abs=tolerances[e["analyte"]]
        )
    prediction = actual["prediction"]
    assert prediction["status"] == want_results["classification_status"]
    if "classification" in want_results:
        expected_prediction = want_results["classification"]
        assert prediction["classification"] == expected_prediction["label"]
        assert prediction["threshold"] == expected_prediction["threshold"]
        assert prediction["probability"] == pytest.approx(
            expected_prediction["probability"], rel=0, abs=1e-12 if same_lab else 0.005
        )


def assert_swift_csvs(tables, expected, *, same_lab=True):
    import csv
    import io

    mapping = {
        "05_reservoirs.csv": "05_reservoir_results.csv",
        "06_analytes.csv": "06_analyte_summary.csv",
        "07_prediction.csv": "07_prediction.csv",
    }
    numeric = {
        "average_l_star",
        "average_a_star",
        "average_b_star",
        "calculated_value",
        "final_value",
        "urea_mM",
        "creatinine_uM",
        "age_years",
        "probability",
        "threshold",
    }
    for table, swift_name in mapping.items():
        actual = list(csv.DictReader(io.StringIO(tables[table])))
        reference = list(csv.DictReader(io.StringIO(expected["csv"][swift_name])))
        assert len(actual) == len(reference), table
        for a, e in zip(actual, reference):
            a = {key: value for key, value in a.items() if key not in IDENTITY_FIELDS}
            assert a.keys() == e.keys(), table
            if "maximum_roi_count" in a:
                assert a["maximum_roi_count"] == "", table
            for key in a.keys() - {"messages", "message", "exclusion_reason", "maximum_roi_count"}:
                if key in numeric and e[key]:
                    tolerance = (
                        5.1e-7
                    )
                    if not same_lab:
                        if key.startswith("average_"):
                            tolerance += SWIFT_LAB_ATOL
                        elif key in ("calculated_value", "final_value"):
                            tolerance += SWIFT_CONCENTRATION_ATOL[e["analyte"]]
                        elif key in ("urea_mM", "creatinine_uM"):
                            tolerance += 0.05
                        elif key == "probability":
                            tolerance += 0.005
                    assert float(a[key]) == pytest.approx(
                        float(e[key]), rel=0, abs=tolerance
                    ), (table, key)
                else:
                    assert a[key] == e[key], (table, key)


def rgba_sha(image):
    import hashlib

    return hashlib.sha256(
        np.dstack((image, np.full(image.shape[:2], 255, dtype=np.uint8))).tobytes()
    ).hexdigest()


@pytest.fixture(
    scope="module",
    params=[
        ("iPhoneRAW.DNG", False),
        ("SampleImg1.CR2", False),
        ("_NOT_ACTUAL_TEST.dng", False),
        ("_NOT_ACTUAL_TEST.dng", True),
    ],
    ids=["DNG-Standard24", "CR2-Standard24", "DNG-Flower-auto", "DNG-Flower-manual"],
)
def pipeline_run(request, tmp_path_factory):
    from ckd.desktop import create_desktop_app
    from ckd.local import LocalAnalysisService

    name, manual = request.param
    ref = swift_reference(name + ".json")
    if manual:
        ref["inputs"], ref["expected"] = ref["manual_inputs"], ref["manual_expected"]
    directory = tmp_path_factory.mktemp("full-chain")
    with pipeline_context(directory) as (api, service):
        with (FIXTURES / name).open("rb") as f:
            response = api.post("/api/analyses", files={"file": (name, f)})
        response.raise_for_status()
        doc = response.json()
        url = f"/api/analyses/{doc['id']}"
        for action in ("render", "white_balance", "calibrate", "analyze"):
            if action == "white_balance":
                draft = swift_draft(
                    ref["inputs"], ref["white_balance_polygon"]["points"]
                )
                response = api.put(
                    url, json={"revision": doc["revision"], "draft": draft}
                )
                response.raise_for_status()
                doc = response.json()
            response = api.post(
                url + "/jobs", json={"revision": doc["revision"], "action": action}
            )
            response.raise_for_status()
            doc = response.json()
            assert doc["job"]["status"] == "completed", doc["job"]
        yield api, service, doc, ref


@pytest.fixture
def client(tmp_path, monkeypatch):
    from ckd.desktop import create_desktop_app
    from ckd.local import LocalAnalysisService

    service = LocalAnalysisService(tmp_path, inline=True)
    with TestClient(create_desktop_app(service=service, token="test"), headers={"X-CKD-Token": "test"}) as api:
        yield api, service


def quantized_flower_lab():
    return rgb2lab(
        np.round(lab2rgb(FLOWER_LAB.reshape(9, 1, 3)) * 255).astype(np.uint8)
    ).reshape(9, 3)


def rectangle(x=1, y=1, size=8):
    return [
        {"x": x, "y": y},
        {"x": x + size, "y": y},
        {"x": x + size, "y": y + size},
        {"x": x, "y": y + size},
    ]


def flower_image():
    corners = rectangle(50, 50, 900)
    patches = marker_polygons("flower_9", corners)
    image = np.full((1000, 1000, 3), 128, dtype=np.uint8)
    colors = (
        np.round(lab2rgb(FLOWER_LAB.reshape(9, 1, 3)) * 255)
        .astype(np.uint8)
        .reshape(9, 3)
    )
    for patch, color in zip(patches, colors):
        rr, cc = polygon(
            [p["y"] for p in patch], [p["x"] for p in patch], image.shape[:2]
        )
        image[rr, cc] = color
    return image, corners, patches


def draft_with_reservoirs(spec):
    reservoirs = [Reservoir(id=i) for i in range(1, 7)]
    rois, results = [], []
    for index, (analyte, labs) in enumerate(spec):
        reservoirs[index].analyte = analyte
        for lab in labs:
            roi_id = len(rois) + 1
            rois.append({"id": roi_id, "label": f"ROI {roi_id}", "points": rectangle()})
            reservoirs[index].roi_ids.append(roi_id)
            results.append(
                {
                    "id": roi_id,
                    "calibrated_median": lab,
                    "calibrated_mean": [100, 100, 100],
                    "pixel_count": roi_id * 100,
                }
            )
    return Draft(
        reservoirs=reservoirs, rois=rois, age=50, sex="female"
    ).model_dump(), results


def reference(name):
    return json.loads((FIXTURES / (name + "_full_color_analyzed_run.json")).read_text())


def legacy_coordinate_package(doc, name="iPhoneRAW.DNG"):
    ref = reference(name)
    valid = [
        r for r in ref["roi_measurements"] if r.get("lab_stats") and r.get("geometry")
    ]
    return {
        "schema_name": "qdaq_ckd_coordinate_package",
        "schema_version": 2,
        "coordinate_system": "top_left_image_pixels",
        "source_image_sha256": doc["source"]["sha256"],
        "source_image_filename": name,
        "image_dimensions": ref["source_image"]["dimensions"],
        "calibration_marker_kind": "standard_24",
        "calibration_mode": "standard_24_grid",
        "white_balance_polygon": {"points": ref["white_balance"]["manual_wb_polygon"]},
        "color_calibration_corners": list(ref["color_checker"]["corners"].values()),
        "reservoirs": [],
        "rois": [
            {
                "roi_id": i + 1,
                "roi_label": f"ROI {i + 1}",
                "polygon": {"points": r["geometry"]["polygon"]},
            }
            for i, r in enumerate(valid)
        ],
    }


def benchmark_live_api(base_url, output_path, token):
    import httpx

    report = []
    with httpx.Client(base_url=base_url, timeout=120, headers={"X-CKD-Token": token}) as api:
        for name in ("iPhoneRAW.DNG", "SampleImg1.CR2"):
            started = time.monotonic()
            with (FIXTURES / name).open("rb") as raw:
                response = api.post("/api/analyses", files={"file": (name, raw)})
            response.raise_for_status()
            doc = response.json()
            record = {
                "filename": name,
                "source_bytes": doc["source"]["bytes"],
                "upload_seconds": round(time.monotonic() - started, 3),
                "jobs": [],
                "analysis_id": doc["id"],
            }
            base = f"/api/analyses/{doc['id']}"
            for action in ("render", "white_balance", "calibrate", "analyze"):
                if action == "white_balance":
                    response = api.post(
                        base + "/coordinates",
                        json={
                            "revision": doc["revision"],
                            "package": legacy_coordinate_package(doc, name),
                        },
                    )
                    response.raise_for_status()
                    doc = response.json()
                response = api.post(
                    base + "/jobs", json={"revision": doc["revision"], "action": action}
                )
                response.raise_for_status()
                doc = response.json()
                deadline = time.monotonic() + 180
                while doc["job"]["status"] in ("queued", "running"):
                    if time.monotonic() > deadline:
                        raise TimeoutError(f"{action} did not finish")
                    time.sleep(0.25)
                    response = api.get(base)
                    response.raise_for_status()
                    doc = response.json()
                if doc["job"]["status"] != "completed":
                    raise RuntimeError(doc["job"])
                record["jobs"].append(doc["job"])
            started = time.monotonic()
            exported = api.get(base + "/export")
            exported.raise_for_status()
            record["export_seconds"] = round(time.monotonic() - started, 3)
            record.update(
                dimensions=[doc["source"]["width"], doc["source"]["height"]],
                export_bytes=len(exported.content),
                calibration_rmse=doc["calibration"]["rmse"],
                roi_count=len(doc["results"]["rois"]),
                versions=doc["results"]["versions"],
            )
            report.append(record)
    Path(output_path).write_text(json.dumps(report, indent=2) + "\n")
    return report


from contextlib import contextmanager


@contextmanager
def pipeline_context(directory):
    import os
    import subprocess
    import uuid
    import httpx
    from types import SimpleNamespace
    from ckd.desktop import create_desktop_app
    from ckd.local import LocalAnalysisService
    from ckd.projects import ProjectStore
    executable = os.environ.get("CKD_ENGINE_EXECUTABLE")
    if not executable:
        service = LocalAnalysisService(directory, inline=True)
        with TestClient(create_desktop_app(service=service, token="test"), headers={"X-CKD-Token": "test"}) as api:
            yield api, service
        return
    token = uuid.uuid4().hex
    env = {"PATH": "/usr/bin:/bin", "HOME": str(directory), "CKD_DESKTOP_TOKEN": token, "OMP_NUM_THREADS": "2"}
    with (directory / "engine.log").open("w") as log:
        process = subprocess.Popen([executable, "--workspace", str(directory), "--state-dir", str(directory / ".settings"), "--parent-pipe"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, env=env)
        try:
            info = json.loads(process.stdout.readline())
            origin = info["url"].split("/launch/")[0]
            with WaitingDesktopClient(base_url=origin, headers={"X-CKD-Token": token}, timeout=180) as api:
                for _ in range(100):
                    try:
                        api.get("/api/ready").raise_for_status()
                        break
                    except httpx.TransportError:
                        time.sleep(0.05)
                store = ProjectStore(directory)
                yield api, SimpleNamespace(directory=lambda doc: store.directory(doc["id"]))
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=10)


import httpx


class WaitingDesktopClient(httpx.Client):
    def post(self, url, **kwargs):
        response = super().post(url, **kwargs)
        if str(url).endswith("/jobs") and response.status_code == 202:
            deadline = time.monotonic() + 180
            while response.json()["job"]["status"] in ("queued", "running"):
                if time.monotonic() >= deadline:
                    raise TimeoutError("Packaged calculation did not finish")
                time.sleep(0.1)
                response = self.get(str(url).removesuffix("/jobs"))
                response.raise_for_status()
        return response
