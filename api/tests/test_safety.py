import copy

import pytest

from ckd.projects.store import HISTORY_LIMIT
from test_storage import flower_analysis


def test_saving_an_earlier_draft_restores_its_calculations(client):
    _, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    draft["reservoirs"][0]["review"] = "included"
    doc = service.save(doc["id"], doc["revision"], draft)
    original = copy.deepcopy(doc)
    moved = copy.deepcopy(doc["draft"])
    moved["corners"][0]["x"] += 4
    edited = service.save(doc["id"], doc["revision"], moved)
    assert edited["calibration"] is None and edited["results"] is None
    assert edited["draft"]["reservoirs"][0]["review"] == "needs_review"
    undone = service.save(doc["id"], edited["revision"], original["draft"])
    assert undone["draft"] == original["draft"]
    for key in ("render", "white_balance", "calibration", "results"):
        assert undone[key] == original[key]


def test_history_keeps_the_latest_versions_only(client):
    _, service = client
    doc, _ = flower_analysis(service)
    for index in range(HISTORY_LIMIT + 5):
        draft = copy.deepcopy(doc["draft"])
        draft["age"] = 20 + index
        doc = service.save(doc["id"], doc["revision"], draft)
    history = sorted((service.directory(doc) / ".history").glob("rev-*.json"))
    assert len(history) == HISTORY_LIMIT
    assert history[-1].name == f"rev-{doc['revision'] - 1:06d}.json"


def test_an_unreadable_analysis_can_be_restored(client):
    api, service = client
    doc, _ = flower_analysis(service)
    path = service.directory(doc) / service.store.filename
    path.write_text("{ truncated")
    library = api.get("/api/library").json()
    assert library["analyses"] == [] and library["problems"][0]["path"] == doc["project_path"]
    assert api.post("/api/folders/restore", json={"path": doc["project_path"]}).status_code == 200
    restored = api.get("/api/library").json()
    assert restored["problems"] == []
    assert restored["analyses"][0]["analysis_id"] == doc["analysis_id"]
    assert [p.read_text() for p in service.directory(doc).glob(".analysis.unreadable-*.json")] == ["{ truncated"]


def test_validation_errors_name_the_shape(client):
    _, service = client
    doc, _ = flower_analysis(service)
    draft = copy.deepcopy(doc["draft"])
    points = draft["rois"][1]["points"]
    draft["rois"][1]["points"] = points + [points[-1]]
    with pytest.raises(ValueError, match="^ROI 2: Polygon vertices must be unique"):
        service.save(doc["id"], doc["revision"], draft)
