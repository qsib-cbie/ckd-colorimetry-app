import csv
import io

import pytest

from ckd.utils import calculate, concentration_results, export_tables
from utils import draft_with_reservoirs


def roi_rows(draft, rois, calibration=None):
    results = {"rois": rois, **concentration_results(draft, rois, calibration)}
    return list(csv.DictReader(io.StringIO(export_tables(results)["09_roi_results.csv"])))


def test_one_row_per_roi_with_labels_biomarker_color_and_sd():
    draft, rois = draft_with_reservoirs([("creatinine", [[60, 0, 0], [60, 5, 0]]), ("ph", [[61, 2, 3]])])
    draft["reservoirs"][0].update(condition="10 mM", replicate="1")
    draft["reservoirs"][1].update(analyte="custom", custom_name="Lactate", condition="10 mM", replicate="2")
    for roi in rois:
        roi.update(label=f"ROI {roi['id']}", median=roi["calibrated_median"], standard_deviation=[1, 1, 1])
    rows = roi_rows(draft, rois)
    assert [row["roi_id"] for row in rows] == ["1", "2", "3"]
    first, second, lactate = rows
    assert (first["reservoir_id"], first["condition"], first["replicate"], first["biomarker"]) == ("1", "10 mM", "1",
                                                                                                    "creatinine")
    assert first["sd_basis"] == "rois" and float(first["reservoir_sd"]) > 0
    assert float(second["value"]) == pytest.approx(calculate("creatinine", [60, 5, 0])["value"])
    assert (lactate["biomarker"], lactate["value"]) == ("Lactate", "")
    assert float(lactate["calibrated_a_star"]) == 2 and float(lactate["pixel_sd_l_star"]) == 1


def test_unassigned_rois_are_listed_without_a_reservoir():
    draft, rois = draft_with_reservoirs([("creatinine", [[60, 0, 0]])])
    rois.append({"id": 9, "calibrated_median": [50, 1, 1], "calibrated_mean": [50, 1, 1], "pixel_count": 10})
    draft["rois"].append({**draft["rois"][0], "id": 9, "label": "ROI 9"})
    rows = roi_rows(draft, rois)
    assert rows[-1]["roi_id"] == "9" and rows[-1]["reservoir_id"] == "" and rows[-1]["biomarker"] == ""


def test_flags_appear_in_the_roi_table():
    draft, rois = draft_with_reservoirs([("creatinine", [[99, 0, 0]])])
    calibration = {"reference_lab": [[30, -20, -20], [90, 40, 60]], "rmse": 1.0,
                   "coefficients": [[1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 0, 0]]}
    assert roi_rows(draft, rois, calibration)[0]["outside_calibration"] == "L"


def test_exported_zip_contains_the_roi_table_with_identity_columns(client):
    import zipfile

    from ckd.utils import IDENTITY_FIELDS
    from test_storage import flower_analysis

    api, service = client
    doc, _ = flower_analysis(service)
    response = api.get(f"/api/analyses/{doc['id']}/export?debug_rasters=0")
    response.raise_for_status()
    with zipfile.ZipFile(io.BytesIO(response.content)) as bundle:
        rows = list(csv.DictReader(io.StringIO(bundle.read("09_roi_results.csv").decode())))
    assert len(rows) == len(doc["draft"]["rois"])
    assert list(rows[0])[:3] == IDENTITY_FIELDS
    assert rows[0]["analysis_id"] == doc["analysis_id"]
