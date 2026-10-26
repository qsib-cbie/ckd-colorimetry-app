"""Generate iOS reference fixtures by hand for review; pytest does not run this."""

import argparse
from pathlib import Path

from utils import generate_mac_references, generate_references

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
payload = generate_references(args.output / "ios_results")
generate_mac_references(args.output)
print(f"Wrote {len(payload['cases'])} results cases and the Mac pipeline references to {args.output}")
