#!/usr/bin/env bash
set -euo pipefail

config="$(cat)"
output=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
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
status="${!status_name:-${FAKE_CURL_STATUS:-204}}"
exit_code="${!exit_name:-${FAKE_CURL_EXIT:-0}}"
body='{"ok":true}'
[[ -z "${FAKE_CURL_BODY+x}" ]] || body="$FAKE_CURL_BODY"
[[ -z "${!body_name+x}" ]] || body="${!body_name}"
printf '%s\n' "$service" >> "${FAKE_CURL_LOG:?}"
printf '%s' "$body" > "$output"
printf '%s' "$status"
exit "$exit_code"
