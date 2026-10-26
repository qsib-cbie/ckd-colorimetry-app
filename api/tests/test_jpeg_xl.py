"""JPEG XL compressed DNGs get a clear message instead of LibRaw's "unsupported file"."""

import shutil
import struct

import pytest
import tifffile

from ckd.utils import JPEG_XL_MESSAGE, dng_uses_jpeg_xl, render_raw
from utils import FIXTURES


@pytest.fixture
def jpeg_xl_dng(tmp_path):
    copy = tmp_path / "jpeg-xl.DNG"
    shutil.copyfile(FIXTURES / "iPhoneRAW.DNG", copy)
    with tifffile.TiffFile(copy) as dng:
        order = dng.byteorder
        offset = dng.pages[0].pages[0].tags["Compression"].offset
    with copy.open("r+b") as handle:
        handle.seek(offset + 8)
        handle.write(struct.pack(order + "H", 52546))
    return copy


def test_detects_only_full_resolution_jpeg_xl(jpeg_xl_dng):
    assert dng_uses_jpeg_xl(jpeg_xl_dng)
    assert not dng_uses_jpeg_xl(FIXTURES / "iPhoneRAW.DNG")
    assert not dng_uses_jpeg_xl(FIXTURES / "SampleImg1.CR2")
    assert not dng_uses_jpeg_xl(FIXTURES / "_NOT_ACTUAL_TEST.dng")


def test_render_explains_jpeg_xl(jpeg_xl_dng):
    with pytest.raises(ValueError, match="JPEG XL") as error:
        render_raw(jpeg_xl_dng)
    assert str(error.value) == JPEG_XL_MESSAGE


def test_import_refuses_jpeg_xl(client, jpeg_xl_dng):
    api, _ = client
    response = api.post("/api/analyses", files={"file": ("jpeg-xl.DNG", jpeg_xl_dng.read_bytes())})
    assert response.status_code == 422
    assert JPEG_XL_MESSAGE in response.text
