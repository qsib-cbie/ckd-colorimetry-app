"""PNG previews and export archives keep every pixel and byte."""

import math

import numpy as np
from PIL import Image

from ckd.utils import save_png


def test_fast_png_preserves_every_pixel_against_previous_encoder(tmp_path):
    image = np.random.default_rng(73).integers(
        0, 256, size=(257, 193, 3), dtype=np.uint8
    )
    previous = tmp_path / "previous.png"
    current = tmp_path / "current.png"
    Image.fromarray(image).save(previous, compress_level=6)
    timings = {}
    save_png(image, current, timings)
    with Image.open(previous) as baseline, Image.open(current) as candidate:
        assert candidate.size == baseline.size == (193, 257)
        assert candidate.mode == baseline.mode == "RGB"
        np.testing.assert_array_equal(np.asarray(candidate), np.asarray(baseline))
        np.testing.assert_array_equal(np.asarray(candidate), image)
    assert {
        "preview.prepare",
        "preview.png_encode",
        "preview.file_write",
    } <= timings.keys()
    assert all(math.isfinite(value) and value >= 0 for value in timings.values())
