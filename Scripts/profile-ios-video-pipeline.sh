#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${IOS_DEVICE_ID:-}" ]]; then
  printf '%s\n' "Set IOS_DEVICE_ID to the physical iPhone UDID reported by xcrun xctrace list devices." >&2
  exit 1
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${PROFILE_OUTPUT_DIR:-$root_dir/build/profiles}"
profile_label="${PROFILE_LABEL:-baseline}"
duration="${PROFILE_DURATION:-30s}"
warmup_seconds="${PROFILE_WARMUP_SECONDS:-8}"
bundle_identifier="${IOS_BUNDLE_ID:-com.lunflux.hyper-meta-ai}"
process_name="${IOS_PROCESS_NAME:-HyperMetaAI}"
launch_args=()

if [[ "${PHONE_PREVIEW_SHARPENING:-0}" == "1" ]]; then
  launch_args=(-PhonePreviewSharpeningEnabled YES)
fi

mkdir -p "$output_dir"

xcrun devicectl device process launch \
  --device "$IOS_DEVICE_ID" \
  --terminate-existing \
  -- "$bundle_identifier" "${launch_args[@]}"

printf 'Allow %ss for the DAT stream to reach its steady state before capture.\n' "$warmup_seconds"
sleep "$warmup_seconds"

capture() {
  local template="$1"
  local suffix="$2"
  local trace_path="$output_dir/${profile_label}-${suffix}.trace"

  rm -rf "$trace_path"
  xcrun xctrace record \
    --template "$template" \
    --device "$IOS_DEVICE_ID" \
    --time-limit "$duration" \
    --output "$trace_path" \
    --attach "$process_name"
  xcrun xctrace export --input "$trace_path" --toc >/dev/null
  printf 'Verified trace: %s\n' "$trace_path"
}

capture "Time Profiler" "time-profiler"
# Xcode 27 exposes Activity Monitor instead of the former Energy Log template.
capture "Activity Monitor" "energy-activity-monitor"
capture "System Trace" "system-trace"
