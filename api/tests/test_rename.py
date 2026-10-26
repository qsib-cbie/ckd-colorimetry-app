from test_storage import flower_analysis


def test_rename_sets_title_and_folder_and_keeps_results(client):
    api, service = client
    doc, _ = flower_analysis(service)
    renamed = api.post(f"/api/analyses/{doc['id']}/rename", json={"title": "Patient 7: day 2"})
    assert renamed.status_code == 200
    moved = api.get(f"/api/analyses/{renamed.json()['id']}").json()
    assert moved["draft"]["title"] == "Patient 7: day 2"
    assert moved["project_path"] == "Patient 7- day 2"
    assert moved["results"] == doc["results"]
    assert moved["analysis_id"] == doc["analysis_id"]


def test_rename_avoids_an_existing_folder_name(client):
    api, service = client
    doc, _ = flower_analysis(service)
    (service.root / "Taken").mkdir()
    moved = api.post(f"/api/analyses/{doc['id']}/rename", json={"title": "Taken"}).json()
    assert moved["path"] == "Taken (2)"
    again = api.post(f"/api/analyses/{moved['id']}/rename", json={"title": "Taken"}).json()
    assert again["path"] == "Taken (2)"


def test_rename_refuses_an_empty_title(client):
    api, service = client
    doc, _ = flower_analysis(service)
    assert api.post(f"/api/analyses/{doc['id']}/rename", json={"title": "  "}).status_code == 422
    assert api.get(f"/api/analyses/{doc['id']}").json()["draft"]["title"] == doc["draft"]["title"]
