import copy
import csv
import io

import numpy as np
import pytest
from pydantic import ValidationError

from ckd.models import Draft
from ckd.utils import concentration_results, coordinate_package, export_tables, import_coordinates
from test_storage import flower_analysis
from utils import draft_with_reservoirs


def with_custom(draft, reservoir_index, name, condition="", replicate=""):
    draft["reservoirs"][reservoir_index].update(analyte="custom", custom_name=name, condition=condition,
                                                replicate=replicate)
    return Draft.model_validate(draft).model_dump()


def test_custom_reservoirs_report_color_without_an_equation():
    draft, rois = draft_with_reservoirs([("creatinine", [[50, 2.85, 5]]), ("ph", [[60, 1, 2], [62, 3, 4]])])
    draft = with_custom(draft, 1, "Lactate", "10 mM", "B")
    results = concentration_results(draft, rois)
    lactate = next(r for r in results["reservoirs"] if r["analyte"] == "custom")
    assert lactate["custom_name"] == "Lactate" and lactate["condition"] == "10 mM" and lactate["replicate"] == "B"
    assert lactate["value"] is None and lactate["calculation_status"] == "no_equation"
    assert lactate["review_status"] == "not_applicable"
    assert lactate["average_lab"] == [61, 2, 3]
    assert lactate["uncertainty"]["lab_sd"] == pytest.approx(np.std([[60, 1, 2], [62, 3, 4]], axis=0, ddof=1))
    assert results["summaries"]["ph"]["value"] is None
    assert results["prediction"]["model"] == "creatinine"


def test_custom_names_and_labels_are_validated_and_exported():
    draft, rois = draft_with_reservoirs([("ph", [[60, 1, 2]])])
    with pytest.raises(ValidationError):
        with_custom(draft, 0, "x" * 81)
    draft = with_custom(draft, 0, "Glucose")
    rows = list(csv.DictReader(io.StringIO(
        export_tables({"rois": rois, **concentration_results(draft, rois)})["05_reservoirs.csv"])))
    assert rows[0]["reservoir_label"] == "Reservoir 1: Glucose" and rows[0]["analyte"] == "custom"


def test_coordinate_packages_carry_names_and_labels(client):
    _, service = client
    doc, _ = flower_analysis(service)
    doc["draft"]["reservoirs"][3].update(analyte="custom", custom_name="Chloride", condition="C1", replicate="2")
    imported = import_coordinates(coordinate_package(doc), doc)
    assert {k: imported["reservoirs"][3][k] for k in ("analyte", "custom_name", "condition", "replicate")} == {
        "analyte": "custom", "custom_name": "Chloride", "condition": "C1", "replicate": "2"}


def test_renaming_a_label_keeps_results_and_updates_them(client):
    api, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"][0]["condition"] = "Day 1"
    saved = api.put(f"/api/analyses/{doc['id']}", json={"revision": doc["revision"], "draft": draft}).json()
    assert saved["results"] is not None
    assert saved["results"]["reservoirs"][0]["condition"] == "Day 1"
