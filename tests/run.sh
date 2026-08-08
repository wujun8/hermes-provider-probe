#!/usr/bin/env bash
# Hermetic regression suite for test-provider.sh.
#
# No network access: curl is replaced by tests/fake-curl, which scripts
# responses from environment variables and records every invocation
# (payload, headers, header-file mode, argv) into a per-case capture dir.
# Nothing here depends on user paths, real credentials, or the host's
# HERMES_DIR; every case builds its own temporary config and .env.
# shellcheck disable=SC2329 # case_* / expect_* helpers are dispatched dynamically ("case_${name}", run_probe env)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE_SCRIPT="$ROOT_DIR/test-provider.sh"
FAKE_CURL="$ROOT_DIR/tests/fake-curl"

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
  echo "test-provider.sh not found next to tests/" >&2
  exit 1
fi
if [[ ! -f "$FAKE_CURL" ]]; then
  echo "tests/fake-curl not found" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hermes-probe-tests.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()

new_case() {
  CASE_DIR=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$CASE_DIR/hermes" "$CASE_DIR/bin" "$CASE_DIR/capture"
  cp "$FAKE_CURL" "$CASE_DIR/bin/curl"
  chmod 755 "$CASE_DIR/bin/curl"
}

write_config() {
  cat >"$CASE_DIR/hermes/config.yaml"
}

write_env() {
  printf '%s\n' 'FIXTURE_API_KEY=synthetic-red-key' >"$CASE_DIR/hermes/.env"
}

# Terminate the current case subshell immediately. A plain `return 1` is
# unreliable here: assertions run as `cmd || fail`, and when such a failure
# is the last command of a function, bash >= 4.4/5.x suppresses errexit at
# the call site, silently swallowing the failed assertion. `exit 1` makes
# the failure deterministic on every bash version (macOS 3.2 and CI 5.x).
fail() {
  echo "assertion failed: $*" >&2
  exit 1
}

# Run the probe with a clean environment. Extra arguments are NAME=VALUE
# assignments passed to env; they override the purged variables.
run_probe() {
  if env \
    -u TEST_MODEL -u LIST_MODELS -u CURL_TIMEOUT -u FIXTURE_API_KEY \
    -u OPENAI_API_KEY -u CODEX_API_KEY -u OPENROUTER_API_KEY -u ANTHROPIC_API_KEY \
    -u DEEPSEEK_API_KEY -u GLM_API_KEY -u KIMI_API_KEY -u BAILIAN_API_KEY -u AGNES_API_KEY \
    PATH="$CASE_DIR/bin:$PATH" \
    HERMES_DIR="$CASE_DIR/hermes" \
    FAKE_CAPTURE_DIR="$CASE_DIR/capture" \
    "$@" \
    bash "$SOURCE_SCRIPT" >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"; then
    STATUS=0
  else
    STATUS=$?
  fi
}

expect_status() {
  [[ "$STATUS" == "$1" ]] || fail "exit status: expected $1, got $STATUS"
}

expect_stdout() {
  grep -Fq -- "$1" "$CASE_DIR/stdout" || fail "stdout missing: $1"
}

expect_stderr() {
  grep -Fq -- "$1" "$CASE_DIR/stderr" || fail "stderr missing: $1"
}

expect_no_stdout() {
  if grep -Fq -- "$1" "$CASE_DIR/stdout"; then
    fail "stdout must not contain: $1"
  fi
}

expect_quiet_stderr() {
  [[ ! -s "$CASE_DIR/stderr" ]] || fail "stderr must be empty on success"
}

expect_capture_count() {
  local count
  count=$(find "$CASE_DIR/capture" -name '*.url' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$count" == "$1" ]] || fail "curl invocations: expected $1, got $count"
}

expect_url() {
  local url
  url=$(cat "$CASE_DIR/capture/$1.url")
  [[ "$url" == *"$2" ]] || fail "capture $1 URL: expected suffix '$2', got '$url'"
}

expect_payload_true() {
  local n="$1"
  shift
  if ! jq -e "$1" "$CASE_DIR/capture/$n.payload" >/dev/null 2>&1; then
    fail "capture $n payload failed jq filter: $1"
  fi
}

expect_payload_field() {
  local actual
  actual=$(jq -r "$2" "$CASE_DIR/capture/$1.payload" 2>/dev/null || echo "__unset__")
  [[ "$actual" == "$3" ]] || fail "capture $1 payload $2: expected '$3', got '$actual'"
}

# Diagnostics must never echo the asserted pattern (it contains the
# synthetic key). Messages stay generic; the case name identifies the check.
expect_headers_contain() {
  grep -Fq -- "$1" "$CASE_DIR/capture/$2.headers" \
    || fail "capture $2 headers: expected content not found"
}

expect_headers_not_contain() {
  if grep -Fq -- "$1" "$CASE_DIR/capture/$2.headers"; then
    fail "capture $2 headers: unexpected content present"
  fi
}

expect_header_mode() {
  local mode
  mode=$(cat "$CASE_DIR/capture/$2.header_mode" 2>/dev/null || echo "missing")
  [[ "$mode" == "$1" ]] || fail "header file mode: expected $1, got $mode"
}

expect_no_key_in() {
  if grep -Fq -- 'synthetic-red-key' "$1"; then
    fail "synthetic key leaked into: $1"
  fi
}

case_basic_responses() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe
  expect_status 0
  expect_stdout '[PASS] Provider is available.'
  expect_stdout 'Test model: gpt-5.6-luna (provider health default)'
  expect_stdout 'API mode: codex_responses'
  expect_stdout 'Models endpoint: skipped'
  # Fix: the prompt must state per-endpoint token policy, never a blanket
  # "max output tokens: 1" (which is wrong for /responses).
  expect_stdout 'max output tokens: provider default'
  expect_no_stdout 'max output tokens: 1'
  expect_no_stdout 'incompatible'
  expect_quiet_stderr
  expect_capture_count 1
  expect_url 1 '/responses'
  # Fix: /responses payload MUST NOT contain max_output_tokens at all.
  expect_payload_true 1 'has("max_output_tokens") | not'
  expect_payload_field 1 '.model' 'gpt-5.6-luna'
  expect_payload_field 1 '.input' 'Reply OK.'
  expect_payload_field 1 '.stream' 'true'
  expect_payload_field 1 '.store' 'false'
  expect_payload_field 1 '.reasoning.effort' 'none'
  # Key hygiene: key lives in the 0600 header file, nowhere else.
  expect_headers_contain 'Authorization: Bearer synthetic-red-key' 1
  expect_header_mode 600 1
  expect_no_key_in "$CASE_DIR/capture/1.argv"
  expect_no_key_in "$CASE_DIR/stdout"
  expect_no_key_in "$CASE_DIR/stderr"
}

case_chat_explicit() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
  api_mode: chat_completions
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe TEST_MODEL=probe-explicit-model
  expect_status 0
  expect_stdout '[PASS] Provider is available.'
  expect_stdout 'Test model: probe-explicit-model (TEST_MODEL override)'
  expect_stdout 'API mode: chat_completions'
  expect_stdout 'max_tokens: 1'
  expect_no_stdout 'max output tokens: provider default'
  expect_no_stdout 'max output tokens: 1'
  expect_quiet_stderr
  expect_capture_count 1
  expect_url 1 '/chat/completions'
  # Chat keeps max_tokens: 1 and never gains max_output_tokens.
  expect_payload_field 1 '.max_tokens' '1'
  expect_payload_true 1 'has("max_output_tokens") | not'
  expect_payload_field 1 '.model' 'probe-explicit-model'
}

case_fallback_400_responses_primary() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe FAKE_RESPONSES_CODE=400
  expect_status 0
  expect_stdout '[PASS] Provider is available.'
  # Fix: neutral HTTP 400 wording, no "incompatible" claim.
  expect_stdout 'returned HTTP 400'
  expect_no_stdout 'incompatible'
  expect_quiet_stderr
  expect_capture_count 2
  expect_url 1 '/responses'
  expect_url 2 '/chat/completions'
  expect_payload_true 1 'has("max_output_tokens") | not'
  expect_payload_field 2 '.max_tokens' '1'
}

case_fallback_400_chat_primary() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
  api_mode: chat_completions
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe FAKE_CHAT_CODE=400
  expect_status 0
  expect_stdout '[PASS] Provider is available.'
  expect_stdout 'returned HTTP 400'
  expect_no_stdout 'incompatible'
  expect_quiet_stderr
  expect_capture_count 2
  expect_url 1 '/chat/completions'
  expect_url 2 '/responses'
  expect_payload_field 1 '.max_tokens' '1'
  expect_payload_true 2 'has("max_output_tokens") | not'
}

case_no_fallback() {
  local code="$1"
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe "FAKE_RESPONSES_CODE=$code"
  expect_status 1
  expect_stdout "[FAIL] Provider returned error (HTTP $code)"
  # Endpoint fallback is 400-only: no second call.
  expect_capture_count 1
  expect_url 1 '/responses'
}

case_html_no_fallback() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe FAKE_RESPONSES_CODE=403 FAKE_RESPONSES_CT=text/html \
    FAKE_RESPONSES_BODY='<!DOCTYPE html><html><body>blocked</body></html>'
  expect_status 1
  expect_stdout '[FAIL]'
  expect_stdout 'non-JSON'
  expect_capture_count 1
}

case_sse_truncated() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe FAKE_RESPONSES_TRUNCATED=1
  expect_status 1
  expect_stdout 'ended without response.completed'
  expect_capture_count 1
}

case_sse_error_event() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe FAKE_RESPONSES_ERROR_STREAM=1
  expect_status 1
  expect_stdout '[FAIL] Responses SSE error event'
  expect_capture_count 1
}

case_chat_truncated() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
  api_mode: chat_completions
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe FAKE_CHAT_TRUNCATED=1
  expect_status 1
  expect_stdout 'ended without [DONE]'
  expect_capture_count 1
}

case_chat_error_event() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
  api_mode: chat_completions
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe FAKE_CHAT_ERROR_STREAM=1
  expect_status 1
  expect_stdout '[FAIL] Chat SSE error envelope'
  expect_capture_count 1
}

case_curl_failure() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe FAKE_CURL_FAIL=1
  expect_status 1
  expect_stdout '[FAIL] curl error: Connection refused (fake)'
  expect_capture_count 1
}

case_route_fallback() {
  local variant="$1"
  new_case
  case "$variant" in
    providers_dict)
      write_config <<'YAML'
model:
  provider: custom:fixture
providers:
  fixture:
    base_url: http://127.0.0.1:18081/v1
    key_env: FIXTURE_API_KEY
YAML
      ;;
    providers_list)
      write_config <<'YAML'
model:
  provider: custom:fixture
providers:
  - name: fixture
    url: http://127.0.0.1:18081/v1
    key_env: FIXTURE_API_KEY
YAML
      ;;
    custom_providers_dict)
      write_config <<'YAML'
model:
  provider: custom:fixture
custom_providers:
  fixture:
    api: http://127.0.0.1:18081/v1
    key_env: FIXTURE_API_KEY
YAML
      ;;
    custom_providers_list)
      write_config <<'YAML'
model:
  provider: custom:fixture
custom_providers:
  - name: fixture
    base_url: http://127.0.0.1:18081/v1
    key_env: FIXTURE_API_KEY
YAML
      ;;
    *)
      fail "unknown route variant: $variant"
      ;;
  esac
  write_env
  run_probe
  expect_status 0
  expect_stdout '[PASS] Provider is available.'
  expect_stdout 'http://127.0.0.1:18081/v1'
  expect_capture_count 1
}

case_base_url_precedence() {
  new_case
  # model.base_url is explicit and differs from the provider entry's route:
  # the model's URL must win. The key comes from model.api_key (${ENV}
  # expansion), so credential lookup does not depend on the entry's route.
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:19091/v1
  api_mode: codex_responses
  api_key: ${FIXTURE_API_KEY}
custom_providers:
  - name: fixture
    base_url: http://127.0.0.1:18081/v1
YAML
  write_env
  run_probe
  expect_status 0
  expect_stdout 'http://127.0.0.1:19091/v1'
  expect_capture_count 1
  expect_url 1 'http://127.0.0.1:19091/v1/responses'
  expect_payload_true 1 'has("max_output_tokens") | not'
  expect_headers_contain 'Authorization: Bearer synthetic-red-key' 1
}

case_missing_address() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:ghost
custom_providers:
  - name: ghost
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe
  expect_status 1
  expect_stderr 'No base URL configured'
  # Fail-closed: curl must never be invoked without an address.
  expect_capture_count 0
}

case_noisy_env() {
  new_case
  write_config <<'YAML'
model:
  provider: custom:fixture
  base_url: http://127.0.0.1:18081/v1
custom_providers:
  - name: fixture
    key_env: FIXTURE_API_KEY
YAML
  write_env
  run_probe FOO=bar NOISE_LEVEL=loud OPENAI_API_KEY=noise-key-123 CODEX_API_KEY=noise-key-456
  expect_status 0
  expect_stdout '[PASS] Provider is available.'
  # Configured key_env wins over fallback key environment variables.
  expect_headers_contain 'Authorization: Bearer synthetic-red-key' 1
  expect_headers_not_contain 'noise-key-123' 1
  expect_headers_not_contain 'noise-key-456' 1
  expect_no_key_in "$CASE_DIR/stdout"
  expect_no_key_in "$CASE_DIR/stderr"
}

run_case() {
  local name="$1"
  shift
  local output
  if output=$( ( set -e; "case_${name}" "$@" ) 2>&1 ); then
    PASS=$((PASS + 1))
    printf '[PASS] %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name")
    printf '[FAIL] %s\n' "$name"
    printf '%s\n' "$output" | sed 's/^/       /'
  fi
}

echo "=== hermes-provider-probe hermetic suite ==="
echo "script under test: $SOURCE_SCRIPT"
echo

run_case basic_responses
run_case chat_explicit
run_case fallback_400_responses_primary
run_case fallback_400_chat_primary
for code in 401 403 429 500 503; do
  run_case no_fallback "$code"
done
run_case html_no_fallback
run_case sse_truncated
run_case sse_error_event
run_case chat_truncated
run_case chat_error_event
run_case curl_failure
run_case route_fallback providers_dict
run_case route_fallback providers_list
run_case route_fallback custom_providers_dict
run_case route_fallback custom_providers_list
run_case base_url_precedence
run_case missing_address
run_case noisy_env

echo
echo "=== results: ${PASS} passed, ${FAIL} failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  printf 'failed cases:\n'
  for name in "${FAILURES[@]}"; do
    printf '  - %s\n' "$name"
  done
  exit 1
fi
exit 0
