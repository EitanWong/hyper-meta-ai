#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_path="$root_dir/HyperMetaAI.xcodeproj"
scheme="HyperMetaAI"
result_bundle_path="${RESULT_BUNDLE_PATH:-$root_dir/build/test-results/HyperMetaAI.xcresult}"
destination="${IOS_DESTINATION:-}"

if [[ -z "$destination" ]]; then
  destinations="$(xcodebuild -project "$project_path" -scheme "$scheme" -showdestinations)"
  simulator_id="$({
    printf '%s\n' "$destinations" \
      | sed -nE 's/.*platform:iOS Simulator.*id:([^,}]+).*/\1/p' \
      | awk '$0 !~ /^dvtdevice-/ { print; exit }'
  })"

  if [[ -z "$simulator_id" ]]; then
    printf '%s\n' "No available iOS Simulator destination was found." >&2
    exit 1
  fi
  destination="platform=iOS Simulator,id=$simulator_id"
fi

mkdir -p "$(dirname "$result_bundle_path")"
rm -rf "$result_bundle_path"

command=(
  xcodebuild
  test
  -project "$project_path"
  -scheme "$scheme"
  -destination "$destination"
  -resultBundlePath "$result_bundle_path"
)
if [[ -n "${ONLY_TESTING:-}" ]]; then
  command+=("-only-testing:$ONLY_TESTING")
fi

printf 'Running %s tests on %s\n' "$scheme" "$destination"
"${command[@]}"

printf 'Test result bundle: %s\n' "$result_bundle_path"
