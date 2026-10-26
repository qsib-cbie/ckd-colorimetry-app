import csv
import io

import pytest

from ckd.models import Draft
from ckd.utils import calculate, concentration_results, export_tables
from utils import draft_with_reservoirs


def standard_24_draft():
    draft, rois = draft_with_reservoirs([("ph", [[60, 0, 19.19]]), ("urea", [[60, 0, 0], [61, 0, 0]]),
                                         ("creatinine", [[50, 2.85, 5]])])
    draft["mode"] = "standard_24_grid"
    return Draft.model_validate(draft).model_dump(), rois


def test_standard_24_reservoirs_use_the_flower_equations():
    draft, rois = standard_24_draft()
    results = concentration_results(draft, rois)
    ph, urea, creatinine = results["reservoirs"]
    assert ph["value"] == pytest.approx(calculate("ph", [60, 0, 19.19])["value"])
    assert urea["value"] == pytest.approx(calculate("urea", [60.5, 0, 0], ph["value"])["value"])
    assert creatinine["value"] == pytest.approx(calculate("creatinine", [50, 2.85, 5])["value"])
    assert results["summaries"]["urea"]["value"] == pytest.approx(urea["value"])
    assert results["prediction"]["status"] == "complete"


def test_standard_24_exports_reservoirs_and_summaries():
    draft, rois = standard_24_draft()
    tables = export_tables({"rois": rois, **concentration_results(draft, rois)})
    rows = list(csv.DictReader(io.StringIO(tables["05_reservoirs.csv"])))
    assert [row["analyte"] for row in rows] == ["ph", "urea", "creatinine"]
    assert len(list(csv.DictReader(io.StringIO(tables["06_analytes.csv"])))) == 3


def test_standard_24_without_reservoirs_stays_lab_only():
    draft, rois = standard_24_draft()
    draft["reservoirs"] = []
    results = concentration_results(draft, rois)
    assert results["reservoirs"] == [] and results["summaries"] == {}
    assert results["prediction"]["reason"] == "Final urea, creatinine, age and sex are required."
