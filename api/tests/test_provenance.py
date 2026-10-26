import copy
import json
import math

import pytest

from ckd import __version__
from ckd.projects import Conflict
from ckd.projects.utils import atomic_json
from test_reliability import render_stub
from test_storage import flower_analysis, runs


def edit_saved(service, doc, change):
    path = service.directory(doc) / service.store.filename
    value = json.loads(path.read_text())
    change(value)
    atomic_json(path, value)
    return service.fetch(doc["id"])


def test_fresh_results_are_current_and_record_the_app(client):
    api, service = client
    doc, _ = flower_analysis(service)
    comparison = api.get(f"/api/analyses/{doc['id']}/comparison").json()
    assert comparison["outdated"] is False
    assert comparison["calculated_with"] == __version__
    assert json.loads((service.directory(doc) / service.store.filename).read_text())["saved_with"] == __version__


def test_legacy_results_show_differences_without_value_changes(client):
    _, service = client
    doc, _ = flower_analysis(service)
    doc = edit_saved(service, doc, lambda value: value["results"]["versions"].pop("app"))
    comparison = service.comparison(doc)
    assert comparison["outdated"] and comparison["calculated_with"] == "1.2 or earlier"
    assert not comparison["affects_values"] and not comparison["needs_remeasure"]
    assert not any(row["changed"] for row in comparison["values"])
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"][0]["review"] = "excluded"
    assert service.save(doc["id"], doc["revision"], draft)["results"]["summaries"]["ph"]["value"] is None


def test_equation_change_is_previewed_blocks_reviews_and_recomputes(client):
    _, service = client
    doc, _ = flower_analysis(service)
    expected = copy.deepcopy(doc["results"]["reservoirs"])

    def older(value):
        value["results"]["versions"]["configuration"] = "older_equations"
        value["results"]["reservoirs"][1]["value"] += 10
        for reservoir in value["draft"]["reservoirs"][:3]:
            reservoir["review"] = "included"

    doc = edit_saved(service, doc, older)
    comparison = service.comparison(doc)
    assert comparison["affects_values"] and not comparison["needs_remeasure"]
    changed = [row for row in comparison["values"] if row["changed"]]
    assert [row["label"] for row in changed][:1] == ["Reservoir 2 urea"]
    assert changed[0]["current"] == pytest.approx(expected[1]["value"])
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"][0]["review"] = "excluded"
    with pytest.raises(Conflict, match="Differences"):
        service.save(doc["id"], doc["revision"], draft)
    doc = service.enqueue(doc["id"], doc["revision"], "recompute")
    assert doc["job"]["status"] == "completed", doc["job"]
    assert service.comparison(doc)["outdated"] is False
    assert doc["results"]["reservoirs"][1]["value"] == pytest.approx(expected[1]["value"])
    assert [r["review"] for r in doc["draft"]["reservoirs"][:3]] == ["included", "needs_review", "included"]
    snapshot = runs(service, doc)[-1]
    assert json.loads((snapshot / "previous_results.json").read_text())["versions"]["configuration"] == "older_equations"


def test_pipeline_change_remeasures_from_the_original(client, monkeypatch):
    _, service = client
    doc, image = flower_analysis(service)
    before = copy.deepcopy(doc)
    monkeypatch.setattr("ckd.service.render_raw", render_stub(image))
    monkeypatch.setattr("ckd.service.white_balance", lambda *args, **kwargs: (image, {"white_balance": [1, 1, 1, 0]}))
    doc = edit_saved(service, doc, lambda value: value["results"]["versions"].update(libraw="0.0.0"))
    assert service.comparison(doc)["needs_remeasure"]
    doc = service.enqueue(doc["id"], doc["revision"], "recompute")
    assert doc["job"]["status"] == "completed", doc["job"]
    assert doc["render"]["array"] != before["render"]["array"]
    assert doc["results"]["versions"]["libraw"] != "0.0.0"
    assert [r["value"] for r in doc["results"]["reservoirs"]] == [r["value"] for r in before["results"]["reservoirs"]]
    assert not (service.directory(doc) / before["render"]["array"]).exists()


def test_a_newer_analysis_asks_for_an_app_update(client):
    _, service = client
    doc, _ = flower_analysis(service)

    def newer(value):
        value["saved_with"] = "99.0.0"
        value["draft"]["field_from_a_newer_app"] = True

    path = service.directory(doc) / service.store.filename
    value = json.loads(path.read_text())
    newer(value)
    atomic_json(path, value)
    problems = service.store.library()["problems"]
    assert "saved by CKD Colorimetry 99.0.0" in problems[0]["error"]
    assert "Update this app" in problems[0]["error"]


def test_info_reports_the_equations_the_engine_uses(client):
    from ckd.utils import calculate, classifier

    api, _ = client
    info = api.get("/api/info").json()
    ph = info["ph"]
    value = calculate("ph", [50, 0, 10])["value"]
    assert ph["quadratic"] * value**2 + ph["linear"] * value + ph["intercept"] == pytest.approx(10)
    model = next(m for m in info["urea"] if m["model"] == "pH_6.5")
    c0, c1, c2, c3 = model["coefficients"]
    assert calculate("urea", [60, 5, 20], 6.5)["value"] == pytest.approx(c0 + c1 * 60 + c2 * 5 + c3 * 20)
    k = info["classifier"]
    z = k["intercept"] - k["urea"] * 20 - k["creatinine"] * 10 - k["age"] * 50
    assert classifier(20, 10, 50, "female")["probability"] == pytest.approx(1 / (1 + math.exp(z)))
    assert info["versions"]["app"] == __version__


def as_ios(value, **changes):
    saved = value["results"]["versions"]
    for key in ("python", "rawpy", "numpy", "scikit_image"):
        saved.pop(key)
    saved.update(platform="ios", **changes)


def test_ios_results_with_matching_versions_are_current(client):
    _, service = client
    doc, _ = flower_analysis(service)
    doc = edit_saved(service, doc, as_ios)
    comparison = service.comparison(doc)
    assert comparison["calculated_on"] == "ios"
    assert not comparison["outdated"] and not comparison["affects_values"] and not comparison["needs_remeasure"]
    assert not any(row["changed"] for row in comparison["values"])
    unused = {row["key"] for row in comparison["versions"] if not row["applies"]}
    assert unused == {"python", "rawpy", "numpy", "scikit_image"}
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"][2]["review"] = "excluded"
    saved = service.save(doc["id"], doc["revision"], draft)
    assert saved["results"]["summaries"]["creatinine"]["value"] is None


@pytest.mark.parametrize("key, value, remeasure", [
    ("engine", "0.0.9", True),
    ("flower_reference", "older_flower", True),
    ("libraw", "0.0.0", True),
    ("configuration", "older_equations", False),
])
def test_ios_results_from_other_versions_still_need_recompute(client, key, value, remeasure):
    _, service = client
    doc, _ = flower_analysis(service)
    doc = edit_saved(service, doc, lambda saved: as_ios(saved, **{key: value}))
    comparison = service.comparison(doc)
    assert comparison["outdated"] and comparison["affects_values"]
    assert comparison["needs_remeasure"] is remeasure
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"][0]["review"] = "excluded"
    with pytest.raises(Conflict, match="Differences"):
        service.save(doc["id"], doc["revision"], draft)


def test_ios_results_from_another_app_version_show_without_locking(client):
    _, service = client
    doc, _ = flower_analysis(service)
    doc = edit_saved(service, doc, lambda saved: as_ios(saved, app="2.0.9"))
    comparison = service.comparison(doc)
    assert comparison["outdated"] and comparison["calculated_with"] == "2.0.9"
    assert not comparison["affects_values"] and not comparison["needs_remeasure"]


def test_rounding_differences_keep_reviews_on_recompute(client):
    from ckd.utils import reset_changed_reviews

    _, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    for reservoir in draft["reservoirs"][:3]:
        reservoir["review"] = "included"
    after = copy.deepcopy(doc["results"])
    after["reservoirs"][0]["value"] *= 1 + 1e-13
    after["reservoirs"][1]["value"] += 1.0
    assert reset_changed_reviews(draft, doc["results"], after) == [2]
