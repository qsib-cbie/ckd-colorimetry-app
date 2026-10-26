"""Write a 2x nearest-neighbour copy of a linear (ProRAW) DNG for large-image tests.

Keeps the colour tags and LinearizationTable, drops EXIF and GPS, uses lossless JPEG tiles."""

import argparse
import heapq
import struct
from pathlib import Path

import numpy as np
import rawpy
import tifffile

TILE = 504
COLOR_TAGS = {
    50721: 10, 50722: 10, 50727: 5, 50728: 5, 50730: 10, 50732: 5, 50778: 3, 50779: 3,
}


def code_lengths(frequencies):
    weights = {symbol: count for symbol, count in enumerate(frequencies) if count}
    weights[len(frequencies)] = 1
    heap = [(count, [symbol]) for symbol, count in weights.items()]
    heapq.heapify(heap)
    lengths = dict.fromkeys(weights, 0)
    while len(heap) > 1:
        a, first = heapq.heappop(heap)
        b, second = heapq.heappop(heap)
        for symbol in first + second:
            lengths[symbol] += 1
        heapq.heappush(heap, (a + b, first + second))
    bits = [0] * 33
    for symbol, length in lengths.items():
        bits[max(length, 1)] += 1
    for i in range(32, 16, -1):
        while bits[i]:
            j = i - 2
            while not bits[j]:
                j -= 1
            bits[i] -= 2
            bits[i - 1] += 1
            bits[j + 1] += 2
            bits[j] -= 1
    i = 16
    while not bits[i]:
        i -= 1
    bits[i] -= 1
    order = sorted((s for s in lengths if s != len(frequencies)), key=lambda s: (lengths[s], s))
    return bits[1:17], order


def canonical(bits, order):
    codes, lengths, code, index = {}, {}, 0, 0
    for length in range(1, 17):
        for _ in range(bits[length - 1]):
            codes[order[index]], lengths[order[index]] = code, length
            code += 1
            index += 1
        code <<= 1
    return codes, lengths


def encode_tile(tile, precision):
    tile = tile.astype(np.int32)
    prediction = np.empty_like(tile)
    prediction[:, 1:] = tile[:, :-1]
    prediction[1:, 0] = tile[:-1, 0]
    prediction[0, 0] = 1 << (precision - 1)
    diff = (tile - prediction).reshape(-1)
    magnitude = np.abs(diff)
    category = np.zeros_like(magnitude)
    nonzero = magnitude > 0
    category[nonzero] = np.floor(np.log2(magnitude[nonzero])).astype(np.int32) + 1
    extra = np.where(diff >= 0, diff, diff + (1 << category) - 1)
    segments, tables = [], []
    channel = np.tile(np.arange(tile.shape[2]), tile.shape[0] * tile.shape[1])
    codes = np.zeros(diff.shape, dtype=np.int64)
    lengths = np.zeros(diff.shape, dtype=np.int64)
    for c in range(tile.shape[2]):
        mask = channel == c
        bits, order = code_lengths(np.bincount(category[mask], minlength=17))
        table_codes, table_lengths = canonical(bits, order)
        lookup_code = np.zeros(17, dtype=np.int64)
        lookup_length = np.zeros(17, dtype=np.int64)
        for symbol in order:
            lookup_code[symbol], lookup_length[symbol] = table_codes[symbol], table_lengths[symbol]
        codes[mask] = (lookup_code[category[mask]] << category[mask]) | extra[mask]
        lengths[mask] = lookup_length[category[mask]] + category[mask]
        tables.append(bytes([c]) + bytes(bits) + bytes(order))
    offsets = np.concatenate(([0], np.cumsum(lengths)[:-1]))
    stream = np.ones(int(lengths.sum() + 7) // 8 * 8, dtype=np.uint8)
    for k in range(int(lengths.max())):
        mask = lengths > k
        stream[offsets[mask] + k] = (codes[mask] >> (lengths[mask] - 1 - k)) & 1
    packed = np.packbits(stream)
    packed = np.insert(packed, np.flatnonzero(packed == 0xFF) + 1, 0)
    height, width, count = tile.shape
    for table in tables:
        segments.append(b"\xff\xc4" + struct.pack(">H", len(table) + 2) + table)
    sof = struct.pack(">BHHB", precision, height, width, count) + b"".join(bytes([c, 0x11, 0]) for c in range(count))
    sos = bytes([count]) + b"".join(bytes([c, c << 4]) for c in range(count)) + bytes([1, 0, 0])
    return (b"\xff\xd8" + b"".join(segments) + b"\xff\xc3" + struct.pack(">H", len(sof) + 2) + sof
            + b"\xff\xda" + struct.pack(">H", len(sos) + 2) + sos + packed.tobytes() + b"\xff\xd9")


def entry(tag, kind, values):
    formats = {1: "B", 2: "s", 3: "H", 4: "I", 5: "I", 7: "B", 10: "i", 11: "f"}
    if kind == 2:
        payload = values.encode() + b"\0"
        count = len(payload)
    else:
        payload = struct.pack("<" + formats[kind] * len(values), *values)
        count = len(values) // 2 if kind in (5, 10) else len(values)
    return tag, kind, count, payload


def write_dng(path, tiles, width, height, raw_page, ifd0):
    tag = lambda name, page=raw_page: page.tags[name].value
    entries = [
        entry(254, 4, [0]), entry(256, 4, [width]), entry(257, 4, [height]), entry(258, 3, [10, 10, 10]),
        entry(259, 3, [7]), entry(262, 3, [34892]), entry(271, 2, ifd0.tags["Make"].value),
        entry(272, 2, ifd0.tags["Model"].value), entry(274, 3, [int(ifd0.tags["Orientation"].value)]),
        entry(277, 3, [3]), entry(284, 3, [1]), entry(305, 2, "CKD 2x upscale for tests"),
        entry(322, 4, [TILE]), entry(323, 4, [TILE]), None, entry(325, 4, [len(t) for t in tiles]),
        entry(50706, 1, [1, 6, 0, 0]), entry(50707, 1, [1, 3, 0, 0]),
        entry(50708, 2, ifd0.tags["UniqueCameraModel"].value),
        entry(50712, 3, list(tag("LinearizationTable"))), entry(50714, 3, list(tag("BlackLevel"))),
        entry(50717, 3, list(tag("WhiteLevel"))),
    ]
    entries += [entry(code, kind, list(ifd0.tags[code].value)) if isinstance(ifd0.tags[code].value, tuple)
                else entry(code, kind, [ifd0.tags[code].value]) for code, kind in COLOR_TAGS.items()]
    data_start = 8
    tile_offsets, position = [], data_start
    for t in tiles:
        tile_offsets.append(position)
        position += len(t) + (len(t) & 1)
    entries[14] = entry(324, 4, tile_offsets)
    entries.sort(key=lambda e: e[0])
    ifd_offset = position
    extra_offset = ifd_offset + 2 + 12 * len(entries) + 4
    ifd, extra = b"", b""
    for code, kind, count, payload in entries:
        if len(payload) <= 4:
            ifd += struct.pack("<HHI", code, kind, count) + payload.ljust(4, b"\0")
        else:
            ifd += struct.pack("<HHII", code, kind, count, extra_offset + len(extra))
            extra += payload + b"\0" * (len(payload) & 1)
    with open(path, "wb") as output:
        output.write(b"II*\0" + struct.pack("<I", ifd_offset))
        for t in tiles:
            output.write(t + b"\0" * (len(t) & 1))
        output.write(struct.pack("<H", len(entries)) + ifd + b"\0\0\0\0" + extra)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with tifffile.TiffFile(args.source) as dng:
        ifd0 = dng.pages[0]
        raw_page = ifd0.pages[0] if ifd0.pages else ifd0
        table = np.array(raw_page.tags["LinearizationTable"].value)
        with rawpy.imread(str(args.source)) as raw:
            linear = raw.raw_image[..., :3].copy()
        stored = np.searchsorted(table, linear)
        if not np.array_equal(table[stored], linear):
            raise SystemExit("The linear values are not all in the LinearizationTable.")
        large = stored.repeat(2, axis=0).repeat(2, axis=1).astype(np.uint16)
        height, width = large.shape[:2]
        if height % TILE or width % TILE:
            raise SystemExit(f"{width}x{height} is not a multiple of {TILE}.")
        tiles = [encode_tile(large[y:y + TILE, x:x + TILE], 10)
                 for y in range(0, height, TILE) for x in range(0, width, TILE)]
        write_dng(args.output, tiles, width, height, raw_page, ifd0)
    with rawpy.imread(str(args.output)) as check:
        decoded = check.raw_image[..., :3]
        if not np.array_equal(decoded, table[large]):
            raise SystemExit("LibRaw does not decode the copy to the upscaled original.")
    print(f"{args.output}: {width}x{height}, {args.output.stat().st_size / 1e6:.1f} MB, decodes exactly")


if __name__ == "__main__":
    main()
