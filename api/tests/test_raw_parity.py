import hashlib

import numpy as np
import pytest

from ckd.utils import calibrate, lab_stats, render_raw, white_balance
from utils import FIXTURES, reference


@pytest.mark.raw
@pytest.mark.parametrize("name", ["iPhoneRAW.DNG", "SampleImg1.CR2"])
def test_original_raw_and_two_pass_wb_match_independent_legacy_raster(name):
    ref = reference(name)
    initial, meta = render_raw(FIXTURES / name)
    image, wb = white_balance(
        FIXTURES / name,
        initial,
        meta["camera_whitebalance"],
        ref["white_balance"]["manual_wb_polygon"],
    )
    rgba = np.dstack([image, np.full(image.shape[:2], 255, dtype=np.uint8)])
    assert (
        hashlib.sha256(rgba.tobytes()).hexdigest()
        == ref["python_rendered_raster"]["rendered_raster"]["rgba8888"]["sha256"]
    )
    assert wb["white_balance"] == pytest.approx(
        ref["white_balance"]["image_white_balance"], abs=1e-12, rel=0
    )
    for roi in ref["roi_measurements"]:
        if roi.get("lab_stats") is None or roi.get("geometry") is None:
            continue
        actual = lab_stats(image, roi["geometry"]["polygon"])
        assert actual["pixel_count"] == roi["lab_stats"]["pixel_count"]
        for key in ("median", "mean", "standard_deviation"):
            np.testing.assert_allclose(actual[key], roi["lab_stats"][key], atol=1e-10, rtol=0)
    fit = calibrate(
        image, "standard_24_grid", list(ref["color_checker"]["corners"].values()), []
    )
    assert fit["rmse"] <= 12
