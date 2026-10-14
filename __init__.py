"""Provider availability probe exposed through the public Hermes plugin CLI API."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys


def _setup_parser(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--home", type=Path, help="Probe this Hermes home instead of the current profile"
    )
    parser.add_argument("--model", help="Override the provider health-check model")
    parser.add_argument(
        "--timeout", type=float, metavar="SECONDS", help="curl timeout for each request"
    )
    parser.add_argument(
        "--list-models", action="store_true", help="Also query the informational models endpoint"
    )


def _run_probe(args: argparse.Namespace) -> None:
    from hermes_constants import get_hermes_home

    home = args.home if args.home is not None else get_hermes_home()
    child_env = os.environ.copy()
    child_env["HERMES_HOME"] = str(home)
    child_env["HERMES_DIR"] = str(home)
    child_env["HERMES_PYTHON"] = sys.executable
    if args.model is not None:
        child_env["TEST_MODEL"] = args.model
    if args.timeout is not None:
        child_env["CURL_TIMEOUT"] = str(args.timeout)
    if args.list_models:
        child_env["LIST_MODELS"] = "1"
    result = subprocess.run(
        ["bash", str(Path(__file__).with_name("test-provider.sh"))],
        env=child_env,
        check=False,
    )
    raise SystemExit(result.returncode)


def register(ctx) -> None:
    ctx.register_cli_command(
        name="provider-probe",
        help="Check the current provider with a small HTTP request",
        description="Validate a complete provider response and preserve the probe's exit status.",
        setup_fn=_setup_parser,
        handler_fn=_run_probe,
    )
