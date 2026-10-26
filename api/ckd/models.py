from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_serializer, model_validator

MAX_RESERVOIRS = 1000
MAX_ROIS = 5000


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class Point(StrictModel):
    x: float
    y: float


class ROI(StrictModel):
    id: int = Field(gt=0)
    label: str = Field(min_length=1, max_length=80)
    points: list[Point] = Field(min_length=3, max_length=128)


class Reservoir(StrictModel):
    id: int = Field(ge=1, le=MAX_RESERVOIRS)
    analyte: Literal["ph", "urea", "creatinine", "custom"] | None = None
    custom_name: str = Field(default="", max_length=80)
    condition: str = Field(default="", max_length=80)
    replicate: str = Field(default="", max_length=40)
    roi_ids: list[int] = Field(default_factory=list, max_length=MAX_ROIS)
    review: Literal["needs_review", "included", "excluded"] = "needs_review"
    reason: str = Field(default="", max_length=500)
    urea_ph_model: Literal["auto", "pH_6.0", "pH_6.5", "pH_7.0"] | None = None
    urea_calibration: Literal["lab", "ab"] | None = None

    @model_serializer(mode="wrap")
    def omit_legacy_urea_settings(self, handler):
        data = handler(self)
        for key in ("urea_ph_model", "urea_calibration"):
            if data.get(key) is None:
                data.pop(key, None)
        return data


class Draft(StrictModel):
    title: str = Field(default="Untitled analysis", min_length=1, max_length=120)
    mode: Literal["flower_9", "flower_9_manual", "standard_24_grid"] = "flower_9"
    white_balance: list[Point] = Field(default_factory=list, max_length=128)
    corners: list[Point] = Field(default_factory=list, max_length=4)
    manual_patches: list[list[Point]] = Field(default_factory=list, max_length=9)
    rois: list[ROI] = Field(default_factory=list, max_length=MAX_ROIS)
    reservoirs: list[Reservoir] = Field(default_factory=list, max_length=MAX_RESERVOIRS)
    age: float | None = Field(default=None, gt=0)
    sex: Literal["female", "male"] | None = None
    urea_ph_model: Literal["pH_6.0", "pH_6.5", "pH_7.0"] | None = None
    urea_calibration: Literal["lab", "ab"] = "lab"
    classifier_model: Literal["full", "creatinine", "urea"] | None = None

    @model_validator(mode="after")
    def check_assignments(self):
        for points in [
            self.white_balance,
            *self.manual_patches,
            *(r.points for r in self.rois),
        ]:
            if len(points) > 3 and points[0] == points[-1]:
                points.pop()
        if len({r.id for r in self.rois}) != len(self.rois):
            raise ValueError("ROI IDs must be unique.")
        if len({r.id for r in self.reservoirs}) != len(self.reservoirs):
            raise ValueError("Reservoir IDs must be unique.")
        assigned = [i for r in self.reservoirs for i in r.roi_ids]
        if len(set(assigned)) != len(assigned):
            raise ValueError("Each ROI can belong to only one reservoir.")
        if not set(assigned).issubset({r.id for r in self.rois}):
            raise ValueError("An assigned ROI is missing.")
        self.lift_reservoir_urea_settings()
        return self

    def lift_reservoir_urea_settings(self):
        urea = [r for r in self.reservoirs if r.analyte == "urea"]
        models = {self.urea_ph_model if r.urea_ph_model is None else None if r.urea_ph_model == "auto"
                  else r.urea_ph_model for r in urea}
        calibrations = {r.urea_calibration or self.urea_calibration for r in urea}
        if len(models) == 1:
            self.urea_ph_model = models.pop()
        if len(calibrations) == 1:
            self.urea_calibration = calibrations.pop()
        for r in self.reservoirs:
            r.urea_ph_model = r.urea_calibration = None


class SaveRequest(StrictModel):
    revision: int = Field(ge=0)
    draft: Draft


class JobRequest(StrictModel):
    revision: int = Field(ge=0)
    action: Literal["render", "white_balance", "calibrate", "analyze", "recompute"]


class ImportRequest(StrictModel):
    revision: int = Field(ge=0)
    package: dict
