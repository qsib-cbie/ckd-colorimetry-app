import shutil
import uuid
from pathlib import Path

import pytest

from utils import client as client
from utils import pipeline_run as pipeline_run


@pytest.fixture(autouse=True)
def isolated_trash(tmp_path_factory, monkeypatch):
    trash = tmp_path_factory.mktemp("trash")

    def move(path):
        shutil.move(str(path), trash / f"{uuid.uuid4().hex}-{Path(path).name}")

    for target in ("ckd.projects.utils.trash_path", "ckd.projects.store.trash_path"):
        monkeypatch.setattr(target, move)
    return trash
