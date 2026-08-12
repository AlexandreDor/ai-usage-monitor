#!/usr/bin/env bash
set -euo pipefail

config="$(cat)"
output=""
headers=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
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
status_sequence_name="FAKE_CURL_${upper}_STATUS_SEQUENCE"
exit_sequence_name="FAKE_CURL_${upper}_EXIT_SEQUENCE"
body_sequence_name="FAKE_CURL_${upper}_BODY_SEQUENCE"
status="${!status_name:-${FAKE_CURL_STATUS:-204}}"
exit_code="${!exit_name:-${FAKE_CURL_EXIT:-0}}"
body='{"ok":true}'
[[ -z "${FAKE_CURL_BODY+x}" ]] || body="$FAKE_CURL_BODY"
[[ -z "${!body_name+x}" ]] || body="${!body_name}"
attempt=1
if [[ -n "${FAKE_CURL_COUNT_DIR:-}" ]]; then
  mkdir -p "$FAKE_CURL_COUNT_DIR"
  count_file="${FAKE_CURL_COUNT_DIR}/${service}"
  [[ -f "$count_file" ]] && attempt=$(( $(<"$count_file") + 1 ))
  printf '%s\n' "$attempt" > "$count_file"
fi
sequence_value() {
  local raw="$1" index="$2" value
  IFS=',' read -r -a values <<< "$raw"
  (( index > ${#values[@]} )) && index=${#values[@]}
  value="${values[$((index - 1))]:-}"
  printf '%s' "$value"
}
[[ -z "${!status_sequence_name:-}" ]] || status="$(sequence_value "${!status_sequence_name}" "$attempt")"
[[ -z "${!exit_sequence_name:-}" ]] || exit_code="$(sequence_value "${!exit_sequence_name}" "$attempt")"
[[ -z "${!body_sequence_name:-}" ]] || body="$(sequence_value "${!body_sequence_name}" "$attempt")"
printf '%s\n' "$service" >> "${FAKE_CURL_LOG:?}"
printf '%s' "$body" > "$output"
[[ -z "$headers" ]] || printf '%s\n' "${!headers_name:-${FAKE_CURL_HEADERS:-}}" > "$headers"
printf '%s' "$status"
exit "$exit_code"
