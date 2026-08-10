#!/usr/bin/env bash
set -euo pipefail

config="$(cat)"
arguments=("$@")
output=""
headers=""
data_binary=""
request_data=()
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --data-binary) data_binary="$2"; shift 2 ;;
    --data|--data-urlencode) request_data+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done

service=generic
[[ "$config" == *discord* ]] && service=discord
[[ "$config" == *telegram* ]] && service=telegram
upper="${service^^}"
status_name="FAKE_CURL_${upper}_STATUS"
exit_name="FAKE_CURL_${upper}_EXIT"
body_name="FAKE_CURL_${upper}_BODY"
headers_name="FAKE_CURL_${upper}_HEADERS"
error_name="FAKE_CURL_${upper}_ERROR"
snapshot_name="FAKE_CURL_${upper}_STATE_SNAPSHOT"
status_sequence_name="FAKE_CURL_${upper}_STATUS_SEQUENCE"
exit_sequence_name="FAKE_CURL_${upper}_EXIT_SEQUENCE"
count_file="${FAKE_CURL_COUNT_DIR:-${TMPDIR:-/tmp}}/${service}.count"
count=0
[[ ! -f "$count_file" ]] || read -r count < "$count_file"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

sequence_value() {
  local sequence="$1" fallback="$2" position="$count" value
  IFS=',' read -r -a values <<< "$sequence"
  (( position <= ${#values[@]} )) || position="${#values[@]}"
  value="${values[$((position - 1))]:-}"
  printf '%s' "${value:-$fallback}"
}

status="${!status_name:-${FAKE_CURL_STATUS:-204}}"
exit_code="${!exit_name:-${FAKE_CURL_EXIT:-0}}"
if [[ -n "${!status_sequence_name:-${FAKE_CURL_STATUS_SEQUENCE:-}}" ]]; then
  status="$(sequence_value "${!status_sequence_name:-${FAKE_CURL_STATUS_SEQUENCE:-}}" "$status")"
fi
if [[ -n "${!exit_sequence_name:-${FAKE_CURL_EXIT_SEQUENCE:-}}" ]]; then
  exit_code="$(sequence_value "${!exit_sequence_name:-${FAKE_CURL_EXIT_SEQUENCE:-}}" "$exit_code")"
fi
body='{"ok":true}'
[[ -z "${FAKE_CURL_BODY+x}" ]] || body="$FAKE_CURL_BODY"
[[ -z "${!body_name+x}" ]] || body="${!body_name}"
header_content="${!headers_name:-${FAKE_CURL_HEADERS:-}}"
error_content="${!error_name:-${FAKE_CURL_ERROR:-}}"
state_snapshot="${!snapshot_name:-}"
printf '%s\n' "$service" >> "${FAKE_CURL_LOG:?}"
if [[ -n "${FAKE_CURL_ARGUMENT_LOG:-}" ]]; then
  printf '%s\n' "${arguments[@]}" > "$FAKE_CURL_ARGUMENT_LOG"
fi
if [[ -n "${FAKE_CURL_DATA_LOG:-}" ]]; then
  printf '%s\n' "${request_data[@]}" >> "$FAKE_CURL_DATA_LOG"
fi
if [[ -n "${FAKE_CURL_PAYLOAD_FILE:-}" && "$data_binary" == @* ]]; then
  cp -- "${data_binary#@}" "$FAKE_CURL_PAYLOAD_FILE"
fi
if [[ -n "$state_snapshot" && -n "${FAKE_CURL_STATE_FILE:-}" && -f "$FAKE_CURL_STATE_FILE" ]]; then
  while IFS= read -r state_line; do
    printf '%s\n' "$state_line"
  done < "$FAKE_CURL_STATE_FILE" > "$state_snapshot"
fi
printf '%s' "$body" > "$output"
[[ -z "$headers" ]] || printf '%b' "$header_content" > "$headers"
[[ -z "$error_content" ]] || printf '%s\n' "$error_content" >&2
printf '%s' "$status"
exit "$exit_code"
