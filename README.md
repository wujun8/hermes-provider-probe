# Hermes provider probe

This standalone plugin adds:

```sh
hermes provider-probe [--home HOME] [--model MODEL] [--timeout SECONDS] [--list-models]
```

It uses the public `ctx.register_cli_command` interface supported by Hermes
v0.21.6. Keep this directory outside the Hermes core checkout; on this machine
its source is `/Users/herelink/.hermes/extensions/hermes-provider-probe/`.
Installing it places the plugin in the selected Hermes home's
`plugins/provider-probe/` directory, which survives core upgrades.

The command reads the current profile at invocation time through
`hermes_constants.get_hermes_home()`. `--home` chooses a different profile to
probe. `--model` overrides the health-check model (normally `gpt-5.6-luna`),
`--timeout` sets curl's timeout for each request (normally 30 seconds), and
`--list-models` enables an informational `/models` request. Model listing
failures do not determine the health result.

## Requirements and temporary-home installation

The probe requires Bash, curl, jq, and Python 3 with `PyYAML>=6,<7`.
The manifest declares the bounded Python dependency for Hermes PM. The CLI
always supplies `sys.executable` as the probe's `HERMES_PYTHON`, so config
loading and response validation use the same interpreter.

To try discovery without changing an existing profile, copy the plugin into a
new temporary Hermes home and enable it there:

```sh
probe_source=/Users/herelink/.hermes/extensions/hermes-provider-probe
probe_test_home=$(mktemp -d)
mkdir -p "$probe_test_home/plugins/provider-probe"
cp "$probe_source/plugin.yaml" "$probe_source/__init__.py" \
   "$probe_source/test-provider.sh" "$probe_test_home/plugins/provider-probe/"
HERMES_HOME="$probe_test_home" hermes plugins enable provider-probe
HERMES_HOME="$probe_test_home" hermes provider-probe --help
```

Enablement uses the normal Hermes dependency admission process. To run a real
probe, give that temporary home's `config.yaml` a model/provider route and
credential reference, and provide the key in that home's `.env` or the caller's
environment. For example:

```yaml
model:
  provider: custom
  base_url: https://your-provider.example/v1
  default: your-conversation-model
  api_mode: codex_responses
  api_key: ${PROBE_API_KEY}
plugins:
  enabled: [provider-probe]
```

The shell script also runs independently, with no core checkout on its Python
path:

```sh
HERMES_HOME=/path/to/profile HERMES_PYTHON=/path/to/python \
  bash /path/to/hermes-provider-probe/test-provider.sh
```

If `HERMES_PYTHON` is unset, direct execution uses `command -v python3`.
Existing script controls remain available: `HERMES_DIR` selects the profile
before `HERMES_HOME`, `TEST_MODEL` overrides the model, `CURL_TIMEOUT` sets the
request timeout, and `LIST_MODELS=1` enables model listing. CLI options override
their corresponding script controls; the CLI always resolves the profile from
`--home` or the current Hermes profile.

## Health and credential behavior

Exit status 0 means the complete response passed validation; failures exit 1.
The probe accepts a Responses stream ending in a successful
`response.completed`, optionally followed by one `[DONE]`. An early/repeated
`[DONE]`, an error event, `response.failed`, `response.incomplete`, a missing
completion, or a non-completed terminal status fails. Chat streams require a
choices-bearing chunk and a final `[DONE]`. Valid non-streaming JSON responses
remain supported. Only an HTTP 400 permits retrying the alternate endpoint;
401/403/429/5xx and incomplete streams fail without fallback.

`.env` values are parsed without executing shell code. Request credentials go
into a temporary mode-0600 header file, never literal curl arguments or probe
output, and the temporary directory is removed when the probe exits.
A successful small health request does not guarantee that a larger conversation
request will succeed.

The existing production recovery probe at
`/Users/herelink/app/test-provider.sh` and
`agent.api_outage_recovery.probe_command` are not changed automatically by
installing or testing this plugin.

## Verification

Run from an official Hermes checkout with a separate test interpreter that
includes the declared PyYAML dependency:

```sh
HERMES_PYTHON=/path/to/test-python bash scripts/run_tests.sh \
  /absolute/path/to/hermes-provider-probe/tests/test_provider_health.py -j 1
bash -n /absolute/path/to/hermes-provider-probe/test-provider.sh
```

The tests use temporary homes and real local HTTP servers. They cover the nine
Responses SSE regression cases, both endpoint directions' 400-only fallback,
credential handling, real plugin discovery, the actual CLI parser, subprocess
probe execution, option forwarding, exit codes, and profile resolution after
registration. They do not contact production providers.
