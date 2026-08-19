#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="$root_dir/HyperMetaAI.xcodeproj/project.pbxproj"
repository_url="https://github.com/facebook/meta-wearables-dat-ios"

current_version="$(sed -n '/repositoryURL = "https:\/\/github.com\/facebook\/meta-wearables-dat-ios"/,/};/ s/^[[:space:]]*version = \([^;]*\);/\1/p' "$project_file" | head -n 1)"
latest_version="$(git ls-remote --tags --refs "$repository_url" 'refs/tags/[0-9]*' \
  | awk -F/ '{ print $NF }' \
  | sort -V \
  | tail -n 1)"

if [[ -z "$current_version" || -z "$latest_version" ]]; then
  echo "Meta Wearables DAT SDK version metadata is incomplete" >&2
  exit 2
fi

if [[ "$current_version" != "$latest_version" ]]; then
  printf 'Meta Wearables DAT SDK drift: project=%s, upstream=%s\n' \
    "$current_version" "$latest_version" >&2
  exit 1
fi

printf 'Meta Wearables DAT SDK is current: %s\n' "$current_version"
