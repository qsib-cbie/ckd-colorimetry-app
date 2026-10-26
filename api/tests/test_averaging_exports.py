import csv
import io

import numpy as np
import pytest

from ckd.utils import concentration_results, export_tables
from utils import draft_with_reservoirs

LABS = [[60, 0, 0], [60, 5, 0], [60, 10, 0], [60, 3, 0]]


def three_creatinine_reservoirs():
    draft, rois = draft_with_reservoirs([("creatinine", [lab]) for lab in LABS])
    for reservoir, condition in zip(draft["reservoirs"], ["A", "B", "C", "D"]):
        reservoir.update(condition=condition, replicate="1")
    draft["reservoirs"][3]["review"] = "excluded"
    results = {"rois": rois, **concentration_results(draft, rois)}
    return results


def table(results, name):
    return list(csv.DictReader(io.StringIO(export_tables(results)[name])))


def test_summary_lists_each_included_reservoir_value():
    results = three_creatinine_reservoirs()
    summary = results["summaries"]["creatinine"]
    included = [r["value"] for r in results["reservoirs"][:3]]
    assert [v["reservoir_id"] for v in summary["values"]] == [1, 2, 3]
    assert [v["condition"] for v in summary["values"]] == ["A", "B", "C"]
    assert summary["value"] == pytest.approx(np.mean(included))
    assert (summary["min"], summary["max"]) == pytest.approx((min(included), max(included)))


def test_analyte_table_shows_the_average_and_its_parts():
    results = three_creatinine_reservoirs()
    row = next(r for r in table(results, "11_analyte_results.csv") if r["analyte"] == "creatinine")
    assert row["included_reservoir_ids"] == "1;2;3" and row["n_included"] == "3"
    assert row["aggregation"] == "mean" and row["excluded_reservoir_ids"] == "4"
    assert len(row["included_values"].split(";")) == 3 and row["included_conditions"] == "A;B;C"
    assert float(row["final_value"]) == pytest.approx(results["summaries"]["creatinine"]["value"])


def test_reservoir_table_marks_what_went_into_the_average():
    rows = table(three_creatinine_reservoirs(), "10_reservoir_results.csv")
    assert [r["included_in_average"] for r in rows] == ["true", "true", "true", "false"]
    assert {r["analyte_n_reservoirs"] for r in rows} == {"3"}
    assert rows[0]["condition"] == "A" and float(rows[0]["average_a_star"]) == 0


def test_roi_table_links_each_roi_to_its_reservoir_and_the_final_value():
    results = three_creatinine_reservoirs()
    rows = table(results, "09_roi_results.csv")
    assert [r["reservoir_included"] for r in rows] == ["true", "true", "true", "false"]
    assert float(rows[0]["analyte_final_value"]) == pytest.approx(results["summaries"]["creatinine"]["value"])
    assert rows[0]["calculation_status"] == "valid"


def test_prediction_details_name_the_model_and_its_inputs():
    row = table(three_creatinine_reservoirs(), "12_prediction_details.csv")[0]
    assert row["model"] == "creatinine" and row["model_source"] == "automatic"
    assert row["threshold"] == "0.579" and row["auc"] == "0.923" and row["available_models"] == "creatinine"
