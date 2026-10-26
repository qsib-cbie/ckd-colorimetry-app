import shutil

from test_storage import flower_analysis


def test_duplicate_gets_its_own_id_and_keeps_results(client):
    api, service = client
    doc, _ = flower_analysis(service)
    response = api.post(f"/api/analyses/{doc['id']}/duplicate")
    assert response.status_code == 201
    copy = response.json()
    assert copy["analysis_id"] != doc["analysis_id"]
    assert copy["copied_from"]["analysis_id"] == doc["analysis_id"]
    assert copy["draft"]["title"] == doc["draft"]["title"] + " copy"
    assert copy["project_path"] != doc["project_path"]
    assert copy["results"] == doc["results"] and copy["revision"] == 0 and copy["job"] is None
    original = service.directory(doc) / doc["source"]["file"]
    assert (service.directory(copy) / copy["source"]["file"]).read_bytes() == original.read_bytes()
    assert (service.directory(copy) / copy["white_balance"]["array"]).is_file()
    assert not list((service.directory(copy) / "runs").iterdir())
    assert not any(item["duplicate_id"] for item in api.get("/api/library").json()["analyses"])


def test_finder_copies_are_flagged_and_can_get_their_own_id(client):
    api, service = client
    doc, _ = flower_analysis(service)
    shutil.copytree(service.directory(doc), service.root / "Finder copy")
    library = api.get("/api/library").json()["analyses"]
    assert [item["duplicate_id"] for item in library] == [True, True]
    copied = next(item for item in library if item["project_path"] == "Finder copy")
    renewed = api.post(f"/api/analyses/{copied['id']}/new-id").json()
    assert renewed["analysis_id"] != doc["analysis_id"]
    assert renewed["copied_from"]["analysis_id"] == doc["analysis_id"]
    assert renewed["results"] == service.fetch(doc["id"])["results"]
    assert not any(item["duplicate_id"] for item in api.get("/api/library").json()["analyses"])
