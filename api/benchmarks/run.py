import argparse
from pathlib import Path

from utils import benchmark

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, required=True)
parser.add_argument(
    "--draft",
    type=Path,
    required=True,
    help="Saved analysis/draft JSON or frozen Swift-reference JSON",
)
parser.add_argument(
    "--variants",
    nargs="+",
    choices=["native", "baseline", "png1", "png1-zip"],
    default=["native"],
)
parser.add_argument("--repeat", type=int, default=3)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--expect-fingerprint", type=Path)
args = parser.parse_args()
if args.repeat < 1:
    parser.error("--repeat must be positive")
benchmark(
    args.source,
    args.draft,
    args.variants,
    args.repeat,
    args.output,
    args.expect_fingerprint,
)
