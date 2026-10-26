import csv
import io

from ckd.utils import concentration_results, export_tables
from utils import draft_with_reservoirs

NEGATIVE_CREATININE = [60, -40, -40]


def creatinine_draft(review):
    draft, rois = draft_with_reservoirs([("creatinine", [NEGATIVE_CREATININE])])
    draft["reservoirs"][0]["review"] = review
    return draft, rois


def test_invalid_values_stay_out_unless_a_reviewer_includes_them():
    for review in ("needs_review", "excluded"):
        results = concentration_results(*creatinine_draft(review))
        reservoir = results["reservoirs"][0]
        assert reservoir["review_status"] == "mathematically_invalid"
        assert results["summaries"]["creatinine"]["value"] is None


def test_an_included_invalid_value_counts_everywhere_and_is_flagged():
    draft, rois = creatinine_draft("included")
    results = concentration_results(draft, rois)
    reservoir = results["reservoirs"][0]
    assert reservoir["calculation_status"] == "invalid_domain"
    assert reservoir["review_status"] == "included"
    assert reservoir["value"] < 0
    assert results["summaries"]["creatinine"]["value"] == reservoir["value"]
    assert results["prediction"]["creatinine_uM"] == reservoir["value"]
    assert any("included by the reviewer" in w for w in reservoir["warnings"])
    tables = export_tables({**results, "rois": rois})
    row = next(csv.DictReader(io.StringIO(tables["05_reservoirs.csv"])))
    assert row["calculation_status"] == "invalid_domain"
    assert row["review_status"] == "included"
    assert row["included_in_summary"].lower() == "true"
    assert "included by the reviewer" in tables["08_notes.csv"]
