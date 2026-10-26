import copy

from ckd.utils import coordinate_package, import_coordinates
from test_storage import flower_analysis


def test_an_added_empty_reservoir_keeps_results(client):
    api, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"].append({"id": 7, "analyte": None, "roi_ids": [], "review": "needs_review", "reason": ""})
    saved = api.put(f"/api/analyses/{doc['id']}", json={"revision": doc["revision"], "draft": draft}).json()
    assert len(saved["draft"]["reservoirs"]) == 7
    assert saved["results"] == doc["results"]


def test_more_reservoirs_per_analyte_are_averaged(client):
    api, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    draft["rois"].append({**draft["rois"][1], "id": 4, "label": "ROI 4"})
    draft["rois"].append({**draft["rois"][1], "id": 5, "label": "ROI 5"})
    draft["reservoirs"] += [
        {"id": 7, "analyte": "urea", "roi_ids": [4], "review": "needs_review", "reason": ""},
        {"id": 8, "analyte": "urea", "roi_ids": [5], "review": "needs_review", "reason": ""},
    ]
    saved = api.put(f"/api/analyses/{doc['id']}", json={"revision": doc["revision"], "draft": draft}).json()
    assert saved["results"] is None
    analyzed = service.enqueue(saved["id"], saved["revision"], "analyze")
    urea = [r for r in analyzed["results"]["reservoirs"] if r["analyte"] == "urea"]
    assert len(urea) == 3
    assert len({round(r["value"], 9) for r in urea}) == 1


def test_coordinate_packages_carry_more_than_six_reservoirs(client):
    _, service = client
    doc, _ = flower_analysis(service)
    doc["draft"]["reservoirs"] += [
        {"id": i, "analyte": None, "roi_ids": [], "review": "needs_review", "reason": ""} for i in (7, 8)
    ]
    imported = import_coordinates(coordinate_package(doc), doc)
    assert [r["id"] for r in imported["reservoirs"]] == list(range(1, 9))


def test_many_reservoirs_and_rois_per_reservoir_analyze(client):
    api, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    urea_roi = draft["rois"][1]
    extra = [{**urea_roi, "id": i, "label": f"ROI {i}"} for i in range(4, 12)]
    draft["rois"] += extra
    draft["reservoirs"][1]["roi_ids"] += [r["id"] for r in extra]
    draft["reservoirs"] += [
        {"id": i, "analyte": None, "roi_ids": [], "review": "needs_review", "reason": ""} for i in range(7, 41)
    ]
    saved = api.put(f"/api/analyses/{doc['id']}", json={"revision": doc["revision"], "draft": draft}).json()
    assert len(saved["draft"]["reservoirs"]) == 40
    analyzed = service.enqueue(saved["id"], saved["revision"], "analyze")
    urea = next(r for r in analyzed["results"]["reservoirs"] if r["analyte"] == "urea")
    assert len(urea["roi_ids"]) == 9 and urea["uncertainty"]["n_rois"] == 9
