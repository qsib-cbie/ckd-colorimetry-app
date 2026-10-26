import copy
import math

import pytest

from ckd.utils import classifier, concentration_results, export_tables, predict, single_classifier
from test_storage import flower_analysis
from utils import draft_with_reservoirs


def workbook(intercept, coefficient, value, age_coefficient, age, male_coefficient, male):
    return 1 / (1 + math.exp(-(intercept + coefficient * value + age_coefficient * age + male_coefficient * male)))


def test_creatinine_model_follows_the_workbook():
    result = single_classifier("creatinine", 12.0, 55, "male")
    expected = workbook(-5.1855, 0.2463, 12.0, 0.0494, 55, 0.319, 1)
    assert result["probability"] == pytest.approx(expected, abs=1e-12)
    assert result["threshold"] == 0.579
    assert result["classification"] == ("Predicted G3+" if expected >= 0.579 else "Predicted G1-2")
    assert result["urea_mM"] is None and result["creatinine_uM"] == 12.0
    rounded = 1 / (1 + math.exp(5.19 - 0.25 * 12 - 0.05 * 55 - 0.32))
    assert result["probability"] == pytest.approx(rounded, abs=0.03)


def test_urea_model_follows_the_workbook():
    result = single_classifier("urea", 20.0, 40, "female")
    assert result["probability"] == pytest.approx(workbook(-6.0376, 0.3449, 20.0, 0.0359, 40, -0.5728, 0), abs=1e-12)
    assert result["threshold"] == 0.422
    assert result["equation_version"] == "g3_logistic_urea_age_sex_2026_10_12"


def test_extreme_inputs_stay_finite():
    assert single_classifier("urea", 1e6, 50, "male")["probability"] == 1
    assert single_classifier("creatinine", -1e6, 50, "male")["probability"] == 0


def test_automatic_choice_uses_the_most_complete_model():
    assert predict(10, 5, 50, "female")["model"] == "full"
    assert predict(10, 5, 50, "female")["probability"] == classifier(10, 5, 50, "female")["probability"]
    assert predict(None, 5, 50, "female")["model"] == "creatinine"
    assert predict(10, None, 50, "female")["model"] == "urea"
    missing = predict(None, None, 50, "female")
    assert missing["status"] == "not_calculated" and missing["available_models"] == []
    assert "urea or creatinine" in missing["reason"]


def test_a_manual_choice_overrides_and_reports_missing_inputs():
    chosen = predict(10, 5, 50, "female", "urea")
    assert chosen["model"] == "urea" and chosen["model_source"] == "manual" and chosen["auc"] == 0.947
    blocked = predict(10, None, 50, "female", "creatinine")
    assert blocked["status"] == "not_calculated" and blocked["available_models"] == ["urea"]


def test_age_and_sex_are_required_by_every_model():
    for urea, creatinine in ((10, 5), (None, 5), (10, None)):
        assert predict(urea, creatinine, None, "female")["status"] == "not_calculated"
        assert predict(urea, creatinine, 50, None)["status"] == "not_calculated"


def test_results_and_exports_name_a_fallback_model():
    draft, rois = draft_with_reservoirs([("creatinine", [[50, 2.85, 5]])])
    results = {"rois": rois, **concentration_results(draft, rois)}
    assert results["prediction"]["model_label"] == "Creatinine + age + sex"
    assert "prediction_model" in export_tables(results)["08_notes.csv"]


def test_excluding_every_ph_falls_back_to_the_creatinine_model(client):
    api, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    draft.update(age=60, sex="male")
    draft["reservoirs"][0]["review"] = "excluded"
    saved = api.put(f"/api/analyses/{doc['id']}", json={"revision": doc["revision"], "draft": draft}).json()
    prediction = saved["results"]["prediction"]
    assert prediction["model"] == "creatinine" and prediction["status"] == "complete"
    draft = copy.deepcopy(saved["draft"])
    draft["classifier_model"] = "full"
    forced = api.put(f"/api/analyses/{doc['id']}", json={"revision": saved["revision"], "draft": draft}).json()
    assert forced["results"]["prediction"]["status"] == "not_calculated"
