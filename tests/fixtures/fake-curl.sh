#!/usr/bin/env bash
set -euo pipefail

config="$(cat)"
output=""
header_output=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) header_output="$2"; shift 2 ;;
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
retry_after_name="FAKE_CURL_${upper}_RETRY_AFTER"
status="${!status_name:-${FAKE_CURL_STATUS:-204}}"
exit_code="${!exit_name:-${FAKE_CURL_EXIT:-0}}"
retry_after="${!retry_after_name:-${FAKE_CURL_RETRY_AFTER:-}}"
body='{"ok":true}'
[[ -z "${FAKE_CURL_BODY+x}" ]] || body="$FAKE_CURL_BODY"
[[ -z "${!body_name+x}" ]] || body="${!body_name}"
printf '%s\n' "$service" >> "${FAKE_CURL_LOG:?}"
if [[ -n "$header_output" ]]; then
  printf 'HTTP/1.1 %s Test\r\n' "$status" > "$header_output"
  [[ -z "$retry_after" ]] || printf 'Retry-After: %s\r\n' "$retry_after" >> "$header_output"
  printf '\r\n' >> "$header_output"
fi
printf '%s' "$body" > "$output"
printf '%s' "$status"
exit "$exit_code"
