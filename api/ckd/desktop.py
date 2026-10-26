import hmac
import json
import re
import secrets
import zipfile
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from starlette.background import BackgroundTask
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict

from .local import LocalAnalysisService
from .models import ImportRequest, JobRequest, SaveRequest
from .projects import Conflict
from .projects.importer import ExportImporter
from .projects.utils import atomic_json, inside, read_json
from .utils import coordinate_package, equation_info


def export_filename(doc):
    title = re.sub(r"[^A-Za-z0-9._ -]+", "-", doc["draft"]["title"]).strip(" .-") or "ckd-analysis"
    return f"{title}_{datetime.now():%Y-%m-%d_%H%M%S}.zip"


class WorkspaceRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    path: str


class RenameRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str


class FolderRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str
    parent: str | None = None
    path: str | None = None


class DesktopRuntime:
    def __init__(self, state_dir=None, service=None):
        self.state_dir = Path(state_dir or Path.home() / "Library/Application Support/CKD Colorimetry")
        self.service = service

    def require(self):
        if not self.service:
            raise HTTPException(409, "Open a workspace folder first.")
        return self.service

    def open(self, path):
        path = Path(path).expanduser().resolve()
        if self.service and self.service.root == path:
            self.remember(path)
            return self.info()
        if self.service:
            if any(self.service.job_active(doc) for doc in self.service.store.list()):
                raise ValueError("Wait for processing to finish before changing workspaces.")
        candidate = LocalAnalysisService(path)
        try:
            self.remember(path)
        except BaseException:
            candidate.close()
            raise
        if self.service:
            self.service.close()
        self.service = candidate
        return self.info()

    def info(self):
        recent_path = self.state_dir / "recent.json"
        try:
            recent = read_json(recent_path) if recent_path.exists() else []
        except (ValueError, OSError):
            recent = []
        return {"root": str(self.service.root) if self.service else None, "recent": recent,
                "missing": [item for item in recent if not Path(item).is_dir()], "home": str(Path.home())}

    def remember(self, path):
        self.state_dir.mkdir(parents=True, exist_ok=True)
        previous = self.info()["recent"]
        atomic_json(self.state_dir / "recent.json", [str(path)] + [item for item in previous if item != str(path)][:9])

    def forget(self, path):
        remaining = [item for item in self.info()["recent"] if item != path]
        self.state_dir.mkdir(parents=True, exist_ok=True)
        atomic_json(self.state_dir / "recent.json", remaining)
        return self.info()

    def close(self):
        if self.service:
            self.service.close()


def create_desktop_app(service=None, token=None, state_dir=None, static_dir=None, origin=None):
    runtime = DesktopRuntime(state_dir, service)
    secret = token or secrets.token_urlsafe(32)
    launched = False

    @asynccontextmanager
    async def lifespan(app):
        yield
        runtime.close()

    app = FastAPI(title="CKD Colorimetry", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.state.runtime = runtime
    app.state.token = secret

    @app.middleware("http")
    async def boundary(request, call_next):
        if request.url.hostname not in ("127.0.0.1", "localhost", "testserver"):
            return JSONResponse({"detail": "Use the local CKD application."}, status_code=403)
        if request.url.path.startswith("/api/"):
            supplied = request.headers.get("x-ckd-token") or request.cookies.get("ckd_desktop", "")
            if not hmac.compare_digest(supplied, secret):
                return JSONResponse({"detail": "Open this workspace from the CKD application."}, status_code=403)
            incoming = request.headers.get("origin")
            expected = origin or str(request.base_url).rstrip("/")
            if incoming and incoming != expected:
                return JSONResponse({"detail": "Requests must originate from the CKD application."}, status_code=403)
        response = await call_next(request)
        response.headers.update({"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY", "Referrer-Policy": "no-referrer"})
        return response

    @app.exception_handler(ValueError)
    async def invalid(request, exc):
        return JSONResponse({"detail": str(exc)}, status_code=409 if isinstance(exc, Conflict) else 422)

    @app.exception_handler(KeyError)
    async def missing(request, exc):
        return JSONResponse({"detail": str(exc)}, status_code=404)

    @app.exception_handler(OSError)
    async def disk_error(request, exc):
        return JSONResponse({"detail": f"Cannot access project files: {exc.strerror or str(exc)}"}, status_code=409)

    @app.get("/launch/{key}")
    def launch(key):
        nonlocal launched
        if launched or not hmac.compare_digest(key, secret):
            raise HTTPException(403, "Launch this window from CKD Colorimetry.")
        launched = True
        response = RedirectResponse("/", status_code=303)
        response.set_cookie("ckd_desktop", secret, httponly=True, samesite="strict")
        return response

    @app.get("/api/ready")
    def ready():
        return {"status": "ready", "mode": "desktop"}

    @app.get("/api/info")
    def info():
        return equation_info()

    @app.get("/api/workspace")
    def workspace():
        return runtime.info()

    @app.post("/api/workspace")
    def open_workspace(body: WorkspaceRequest):
        return runtime.open(body.path)

    @app.post("/api/workspace/forget")
    def forget_workspace(body: WorkspaceRequest):
        return runtime.forget(body.path)

    @app.get("/api/library")
    def library():
        return runtime.require().store.library()

    @app.post("/api/folders")
    def folder(body: FolderRequest):
        return runtime.require().store.create_folder(body.name, body.parent)

    @app.post("/api/folders/move")
    def move(body: FolderRequest):
        if not body.path:
            raise ValueError("Select a folder to move.")
        return runtime.require().store.move(body.path, body.name, body.parent)

    @app.post("/api/folders/restore")
    def restore(body: WorkspaceRequest):
        return runtime.require().store.restore(body.path)

    @app.post("/api/folders/trash")
    def trash(body: WorkspaceRequest):
        runtime.require().store.trash(body.path)
        return {"ok": True}

    @app.post("/api/import")
    def import_export(body: WorkspaceRequest):
        path = Path(body.path).expanduser().resolve()
        try:
            doc = ExportImporter(runtime.require().store).import_zip(path)
        except (zipfile.BadZipFile, KeyError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ValueError("This file is not a CKD export ZIP.") from exc
        return {"path": doc["project_path"]}

    @app.get("/api/analyses")
    def analyses():
        return [{"id": doc["id"], "title": doc["draft"]["title"], "filename": doc["source"]["filename"], "project_path": doc["project_path"], "updated_at": doc["updated_at"]} for doc in runtime.require().store.list()]

    @app.post("/api/analyses", status_code=201)
    def create(file: UploadFile, folder_id: str | None = None):
        return runtime.require().create(file.filename or "", file.file, parent=folder_id)

    @app.get("/api/analyses/{analysis_id}")
    def analysis(analysis_id: str):
        return runtime.require().fetch(analysis_id)

    @app.put("/api/analyses/{analysis_id}")
    def save(analysis_id: str, body: SaveRequest):
        return runtime.require().save(analysis_id, body.revision, body.draft.model_dump())

    @app.post("/api/analyses/{analysis_id}/jobs", status_code=202)
    def job(analysis_id: str, body: JobRequest):
        return runtime.require().enqueue(analysis_id, body.revision, body.action)

    @app.post("/api/analyses/{analysis_id}/duplicate", status_code=201)
    def duplicate(analysis_id: str):
        return runtime.require().duplicate(analysis_id)

    @app.post("/api/analyses/{analysis_id}/rename")
    def rename(analysis_id: str, body: RenameRequest):
        return runtime.require().rename(analysis_id, body.title)

    @app.post("/api/analyses/{analysis_id}/new-id")
    def new_id(analysis_id: str):
        return runtime.require().store.reassign_id(analysis_id)

    @app.get("/api/analyses/{analysis_id}/comparison")
    def comparison(analysis_id: str):
        service = runtime.require()
        return service.comparison(service.fetch(analysis_id))

    @app.post("/api/analyses/{analysis_id}/coordinates")
    def import_coordinates(analysis_id: str, body: ImportRequest):
        return runtime.require().import_package(analysis_id, body.revision, body.package)

    @app.get("/api/analyses/{analysis_id}/coordinates")
    def coordinates(analysis_id: str):
        return JSONResponse(coordinate_package(runtime.require().fetch(analysis_id)), headers={"Content-Disposition": 'attachment; filename="coordinates.json"'})

    @app.get("/api/analyses/{analysis_id}/preview")
    def preview(analysis_id: str):
        service = runtime.require()
        doc = service.fetch(analysis_id)
        balanced = bool(doc["white_balance"])
        service.cached_image(doc, balanced)
        raster = doc["white_balance"] if balanced else doc["render"]
        return FileResponse(inside(service.directory(doc), raster["preview"]), media_type="image/png")

    @app.get("/api/analyses/{analysis_id}/original")
    def original(analysis_id: str):
        service = runtime.require()
        doc = service.fetch(analysis_id)
        return FileResponse(inside(service.directory(doc), doc["source"]["file"]), filename=doc["source"]["filename"])

    @app.get("/api/analyses/{analysis_id}/export")
    def export(analysis_id: str, debug_rasters: bool = True):
        doc, path = runtime.require().export_archive(analysis_id, debug_rasters)
        return FileResponse(path, filename=export_filename(doc), media_type="application/zip",
                            background=BackgroundTask(path.unlink, missing_ok=True))

    if static_dir:
        app.mount("/", StaticFiles(directory=static_dir, html=True), name="frontend")
    return app
