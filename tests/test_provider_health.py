"""Black-box HTTP coverage for the standalone probe and Hermes plugin CLI."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

import pytest


_PLUGIN_ROOT = Path(__file__).resolve().parents[1]
_SCRIPT = _PLUGIN_ROOT / "test-provider.sh"
_FAKE_API_KEY = "hermes-probe-test-fake-credential"


def _sse_event(event_type: str, response_status: str) -> bytes:
    data = {
        "type": event_type,
        "response": {
            "id": "resp-probe-test",
            "status": response_status,
            "model": "probe-test",
            "output": [],
        },
    }
    return f"event: {event_type}\ndata: {json.dumps(data)}\n\n".encode()


def _error_event() -> bytes:
    data = {"type": "error", "error": {"message": "fixture error"}}
    return f"event: error\ndata: {json.dumps(data)}\n\n".encode()


def _done_event() -> bytes:
    return b"data: [DONE]\n\n"


_COMPLETED = _sse_event("response.completed", "completed")
_SSE_CASES = [
    pytest.param(_COMPLETED, True, id="completed-without-done"),
    pytest.param(_COMPLETED + _done_event(), True, id="completed-trailing-done"),
    pytest.param(_done_event(), False, id="done-only"),
    pytest.param(
        _done_event() + _COMPLETED,
        False,
        id="done-before-completed",
    ),
    pytest.param(
        _COMPLETED + _done_event() + _done_event(),
        False,
        id="repeated-trailing-done",
    ),
    pytest.param(
        _error_event() + _COMPLETED,
        False,
        id="error-before-completed",
    ),
    pytest.param(
        _sse_event("response.failed", "failed"),
        False,
        id="response-failed",
    ),
    pytest.param(
        _sse_event("response.incomplete", "incomplete"),
        False,
        id="response-incomplete",
    ),
    pytest.param(
        _sse_event("response.completed", "queued"),
        False,
        id="completed-with-wrong-status",
    ),
]


class _ProbeServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.requests: list[tuple[str, dict | None]] = []
        self.status_by_path: dict[str, int] = {}
        self.response_delay = 0
        self.header_modes: list[int] = []
        self.authorizations: list[str | None] = []


class _SSEHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        request_bytes = self.rfile.read(content_length)
        try:
            request_body = json.loads(request_bytes)
        except (json.JSONDecodeError, UnicodeDecodeError):
            request_body = None
        self.server.requests.append((self.path, request_body))
        self.server.authorizations.append(self.headers.get("Authorization"))
        if hasattr(self.server, "temp_dir"):
            self.server.header_modes.extend(
                path.stat().st_mode & 0o777
                for path in self.server.temp_dir.glob(
                    "hermes-test.*/hermes-test-headers.*"
                )
            )

        if self.path not in {"/v1/responses", "/v1/chat/completions"}:
            self.send_error(404)
            return

        time.sleep(self.server.response_delay)
        status = self.server.status_by_path.get(self.path, 200)
        if status != 200:
            payload = b'{"error":{"message":"fixture rejection"}}'
            content_type = "application/json"
        elif self.path == "/v1/responses":
            payload = self.server.sse_payload
            content_type = "text/event-stream"
        else:
            payload = json.dumps(
                {"choices": [{"message": {"role": "assistant", "content": "OK"}}]}
            ).encode()
            content_type = "application/json"
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            # A timeout test deliberately closes the client before this write.
            pass

    def do_GET(self):
        self.server.requests.append((self.path, None))
        if self.path != "/v1/models":
            self.send_error(404)
            return
        status = self.server.status_by_path.get(self.path, 200)
        payload = (
            b'{"data":[{"id":"fixture-model"}]}'
            if status == 200
            else b'{"error":{"message":"models unavailable"}}'
        )
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format, *_args):
        pass


def _start_sse_server(payload: bytes):
    server = _ProbeServer(("127.0.0.1", 0), _SSEHandler)
    server.sse_payload = payload
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def _minimal_path() -> str:
    curl_path = shutil.which("curl")
    jq_path = shutil.which("jq")
    assert curl_path, "curl is required by test-provider.sh"
    assert jq_path, "jq is required by test-provider.sh"

    entries = [
        Path(sys.executable).parent,
        Path(curl_path).parent,
        Path(jq_path).parent,
        *(Path(entry) for entry in os.environ.get("PATH", "").split(os.pathsep) if entry),
    ]
    return os.pathsep.join(dict.fromkeys(str(entry) for entry in entries))


def _write_test_config(
    hermes_home: Path, base_url: str, api_mode: str = "codex_responses"
) -> None:
    hermes_home.mkdir(parents=True, exist_ok=True)
    (hermes_home / "config.yaml").write_text(
        "\n".join(
            [
                "model:",
                "  provider: custom",
                f'  base_url: "{base_url}"',
                "  default: probe-test",
                f"  api_mode: {api_mode}",
                f'  api_key: "{_FAKE_API_KEY}"',
                "plugins:",
                "  enabled: [provider-probe]",
                "",
            ]
        ),
        encoding="utf-8",
    )


@pytest.mark.parametrize(("sse_payload", "should_pass"), _SSE_CASES)
def test_provider_health_probe_handles_responses_sse_black_box(
    sse_payload, should_pass, tmp_path
):
    """Exercise the shell probe against a local Responses SSE endpoint."""
    assert _SCRIPT.is_file(), f"probe script is missing: {_SCRIPT}"
    case_dir = tmp_path
    hermes_home = case_dir / "hermes-home"
    fake_home = case_dir / "user-home"
    fake_home.mkdir()

    server, server_thread = _start_sse_server(sse_payload)
    try:
        base_url = f"http://127.0.0.1:{server.server_port}/v1"
        _write_test_config(hermes_home, base_url)
        child_env = {
            "HOME": str(fake_home),
            "HERMES_PYTHON": sys.executable,
            "PATH": _minimal_path(),
            "TMPDIR": str(case_dir),
            "HERMES_DIR": str(hermes_home),
            "HERMES_HOME": str(hermes_home),
            "TEST_MODEL": "probe-test",
            "LIST_MODELS": "0",
            "CURL_TIMEOUT": "3",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        }
        result = subprocess.run(
            ["bash", str(_SCRIPT)],
            cwd=_PLUGIN_ROOT,
            env=child_env,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=3)

    assert not server_thread.is_alive(), "local SSE server thread did not stop"
    output = f"{result.stdout}\n{result.stderr}"
    assert _FAKE_API_KEY not in output, "probe printed its credential"
    if should_pass:
        assert result.returncode == 0, f"probe exit code was {result.returncode}\n{output}"
    else:
        assert result.returncode != 0, f"probe unexpectedly exited successfully\n{output}"
    marker = "[PASS]" if should_pass else "[FAIL]"
    assert marker in output.upper(), f"probe output did not contain {marker}\n{output}"

    assert server.requests, "probe did not make a request to the local server"
    assert all(path == "/v1/responses" for path, _body in server.requests), (
        f"probe made unexpected requests: {server.requests!r}"
    )
    assert all(
        isinstance(body, dict) and body.get("model") == "probe-test"
        for _path, body in server.requests
    ), f"probe sent an unexpected model request: {server.requests!r}"


@pytest.fixture
def probe(tmp_path):
    server, server_thread = _start_sse_server(_COMPLETED)
    server.temp_dir = tmp_path
    home = tmp_path / "probe-home"
    base_url = f"http://127.0.0.1:{server.server_port}/v1"
    _write_test_config(home, base_url)
    try:
        yield SimpleNamespace(home=home, server=server, case_dir=tmp_path, base_url=base_url)
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=3)
        assert not server_thread.is_alive(), "local HTTP server thread did not stop"


def _child_env(home: Path, case_dir: Path) -> dict[str, str]:
    user_home = case_dir / "user-home"
    user_home.mkdir(exist_ok=True)
    return {
        "HOME": str(user_home),
        "HERMES_HOME": str(home),
        "HERMES_DIR": str(home),
        "HERMES_PYTHON": sys.executable,
        "PATH": _minimal_path(),
        "TMPDIR": str(case_dir),
        "TEST_MODEL": "probe-test",
        "LIST_MODELS": "0",
        "CURL_TIMEOUT": "3",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PYTHONDONTWRITEBYTECODE": "1",
    }


def _install_plugin(home: Path) -> None:
    target = home / "plugins" / "provider-probe"
    target.mkdir(parents=True)
    for filename in ("plugin.yaml", "__init__.py", "test-provider.sh"):
        shutil.copy2(_PLUGIN_ROOT / filename, target / filename)


def _run_script(probe, extra_env=None):
    env = _child_env(probe.home, probe.case_dir)
    env.update(extra_env or {})
    return subprocess.run(
        ["bash", str(_SCRIPT)],
        cwd=probe.case_dir,
        env=env,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


def _run_cli(home: Path, case_dir: Path, *args: str):
    import hermes_constants

    env = _child_env(home, case_dir)
    # Hermes itself starts with sys.executable; the plugin must choose that
    # interpreter for every script stage instead of trusting this stale value.
    env["HERMES_PYTHON"] = str(case_dir / "missing-python")
    env["HERMES_DIR"] = str(case_dir / "wrong-home")
    return subprocess.run(
        [sys.executable, "-m", "hermes_cli.main", "provider-probe", *args],
        cwd=Path(hermes_constants.__file__).resolve().parent,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )


def _assert_result(result, should_pass: bool) -> str:
    output = f"{result.stdout}\n{result.stderr}"
    assert result.returncode == (0 if should_pass else 1), output
    assert ("[PASS]" if should_pass else "[FAIL]") in output, output
    assert _FAKE_API_KEY not in output, "probe printed its credential"
    return output


def test_official_cli_discovers_plugin_and_parses_help(probe):
    _install_plugin(probe.home)
    result = _run_cli(probe.home, probe.case_dir, "--help")
    output = f"{result.stdout}\n{result.stderr}"
    assert result.returncode == 0, output
    assert "provider-probe" in output
    for option in ("--home", "--model", "--timeout", "--list-models"):
        assert option in output
    assert probe.server.requests == [], "registration/help made an HTTP request"


@pytest.mark.parametrize(
    ("sse_payload", "should_pass"),
    [pytest.param(_COMPLETED, True, id="success"), pytest.param(_error_event(), False, id="failure")],
)
@pytest.mark.parametrize("models_status", [200, 503])
def test_official_cli_passes_options_and_preserves_probe_exit(
    probe, sse_payload, should_pass, models_status
):
    active_home = probe.case_dir / "active-home"
    _write_test_config(active_home, "http://127.0.0.1:1/v1")
    _install_plugin(active_home)
    probe.server.sse_payload = sse_payload
    probe.server.status_by_path["/v1/models"] = models_status
    result = _run_cli(
        active_home,
        probe.case_dir,
        "--home", str(probe.home),
        "--model", "cli-probe-model",
        "--timeout", "3",
        "--list-models",
    )
    output = _assert_result(result, should_pass)
    assert "[LIST_MODELS=1]" in output
    assert [path for path, _body in probe.server.requests] == [
        "/v1/models", "/v1/responses"
    ]
    assert probe.server.requests[1][1]["model"] == "cli-probe-model"


def test_official_cli_defaults_to_current_profile(probe):
    _install_plugin(probe.home)
    result = _run_cli(probe.home, probe.case_dir)
    _assert_result(result, True)
    assert [path for path, _body in probe.server.requests] == ["/v1/responses"]


def test_official_cli_timeout_reaches_curl(probe):
    _install_plugin(probe.home)
    probe.server.response_delay = 1
    result = _run_cli(probe.home, probe.case_dir, "--timeout", "0.1")
    output = _assert_result(result, False)
    assert "curl error" in output
    assert [path for path, _body in probe.server.requests] == ["/v1/responses"]


def test_discovered_handler_resolves_profile_at_invocation(probe):
    """Switch the real Hermes profile scope after the plugin is registered."""
    import hermes_constants

    active_home = probe.case_dir / "active-home"
    _write_test_config(active_home, "http://127.0.0.1:1/v1")
    _install_plugin(active_home)
    code = """
import argparse
import sys
from hermes_cli.plugins import PluginManager
from hermes_constants import set_hermes_home_override
manager = PluginManager()
manager.discover_and_load()
command = manager._cli_commands["provider-probe"]
parser = argparse.ArgumentParser()
command["setup_fn"](parser)
args = parser.parse_args([])
set_hermes_home_override(sys.argv[1])
command["handler_fn"](args)
"""
    result = subprocess.run(
        [sys.executable, "-c", code, str(probe.home)],
        cwd=Path(hermes_constants.__file__).resolve().parent,
        env=_child_env(active_home, probe.case_dir),
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    _assert_result(result, True)
    assert [path for path, _body in probe.server.requests] == ["/v1/responses"]


@pytest.mark.parametrize("http_status", [400, 401, 403, 429, 500])
@pytest.mark.parametrize(
    ("api_mode", "primary", "alternate"),
    [
        ("codex_responses", "/v1/responses", "/v1/chat/completions"),
        ("chat_completions", "/v1/chat/completions", "/v1/responses"),
    ],
)
def test_endpoint_fallback_only_for_http_400(
    probe, http_status, api_mode, primary, alternate
):
    _write_test_config(probe.home, probe.base_url, api_mode)
    probe.server.status_by_path[primary] = http_status
    result = _run_script(probe)
    _assert_result(result, http_status == 400)
    expected_paths = [primary, alternate] if http_status == 400 else [primary]
    assert [path for path, _body in probe.server.requests] == expected_paths


def test_env_file_is_not_executed_and_headers_are_private(probe):
    marker = probe.case_dir / "must-not-be-created"
    (probe.home / ".env").write_text(
        f'PROBE_UNSAFE="$(touch {marker})"\n', encoding="utf-8"
    )
    result = _run_script(probe)
    _assert_result(result, True)
    assert not marker.exists(), ".env content was evaluated by a shell"
    assert probe.server.authorizations == [f"Bearer {_FAKE_API_KEY}"]
    assert probe.server.header_modes == [0o600]
    assert list(probe.case_dir.glob("hermes-test.*")) == [], "probe left temporary files"


def test_explicit_python_is_used_for_all_script_stages(probe):
    fake_bin = probe.case_dir / "fake-bin"
    fake_bin.mkdir()
    wrong_python = fake_bin / "python3"
    wrong_python.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
    wrong_python.chmod(0o755)
    result = _run_script(
        probe, {"PATH": str(fake_bin) + os.pathsep + _minimal_path()}
    )
    _assert_result(result, True)
