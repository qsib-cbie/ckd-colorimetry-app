from ckd.models import Draft
from ckd.utils import concentration_results
from utils import draft_with_reservoirs


def urea_draft():
    return draft_with_reservoirs([("ph", [[60, 0, 19.19]]), ("urea", [[60, 0, 0]]), ("urea", [[60, 0, 0]])])


def test_shared_per_reservoir_choices_become_the_analysis_setting():
    draft, _ = urea_draft()
    for r in draft["reservoirs"]:
        if r["analyte"] == "urea":
            r["urea_ph_model"], r["urea_calibration"] = "pH_7.0", "ab"
    dumped = Draft.model_validate(draft).model_dump()
    assert (dumped["urea_ph_model"], dumped["urea_calibration"]) == ("pH_7.0", "ab")
    assert all("urea_ph_model" not in r and "urea_calibration" not in r for r in dumped["reservoirs"])


def test_differing_per_reservoir_choices_are_dropped():
    draft, _ = urea_draft()
    draft["urea_calibration"] = "lab"
    urea = [r for r in draft["reservoirs"] if r["analyte"] == "urea"]
    urea[0]["urea_calibration"], urea[1]["urea_calibration"] = "ab", "lab"
    urea[0]["urea_ph_model"] = "auto"
    dumped = Draft.model_validate(draft).model_dump()
    assert (dumped["urea_ph_model"], dumped["urea_calibration"]) == (None, "lab")
    assert all("urea_calibration" not in r for r in dumped["reservoirs"])


def test_results_use_one_analysis_setting_for_every_urea_reservoir():
    draft, rois = urea_draft()
    draft["urea_calibration"] = "ab"
    results = concentration_results(draft, rois)
    urea = [r for r in results["reservoirs"] if r["analyte"] == "urea"]
    assert results["urea_calibration"] == "ab"
    assert "urea_reservoir_settings" not in results
    assert len({r["equation_version"] for r in urea}) == 1
