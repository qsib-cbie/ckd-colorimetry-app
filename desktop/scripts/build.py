import argparse
from utils import build

parser = argparse.ArgumentParser(description="Build the self-contained Mac application")
parser.add_argument("--engine-only", action="store_true")
parser.add_argument("--skip-engine", action="store_true")
args = parser.parse_args()
build(args.engine_only, args.skip_engine)
