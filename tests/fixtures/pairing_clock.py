"""Run the real pairing HTTP service against a fixture clock file."""

import argparse
from pathlib import Path
import os

from clearpath.partners import Pairing, PairingServer


parser = argparse.ArgumentParser()
parser.add_argument("state", type=Path)
parser.add_argument("clock", type=Path)
parser.add_argument("port", type=int, default=0, nargs="?")
args = parser.parse_args()
os.umask(0o077)
with PairingServer(args.port, Pairing(args.state, clock=lambda: float(args.clock.read_text()))) as server:
    print(server.server_port, flush=True)
    server.serve_forever()
