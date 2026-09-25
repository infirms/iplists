"""Command-line entry point for rule-set compilation."""

import argparse
from pathlib import Path
import subprocess

from .build import compile_services


def main() -> None:
    parser = argparse.ArgumentParser(description="Build sing-box rule-sets from services/*.json")
    parser.add_argument("--services", type=Path, default=Path("services"))
    parser.add_argument("--output", type=Path, default=Path("output/sing-box"))
    parser.add_argument("--sing-box", default="sing-box")
    args = parser.parse_args()
    try:
        compile_services(args.services, args.output, args.sing_box)
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
