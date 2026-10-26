"""Generate Swift reference fixtures by hand for review; pytest does not run this."""

import argparse
from pathlib import Path

from utils import generate_references

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--qdaq", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
generate_references(args.qdaq, args.output)
