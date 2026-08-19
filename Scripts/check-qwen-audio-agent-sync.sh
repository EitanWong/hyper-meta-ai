#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
catalog="$root_dir/HyperMetaAI/Services/Qwen/QwenRealtimeModelCatalog.swift"

read_constant() {
  local name="$1"
  sed -n "s/^[[:space:]]*static let ${name} = \"\([^\"]*\)\".*/\1/p" "$catalog" | head -n 1
}

repository_url="$(read_constant repositoryURL)"
expected_tag="$(read_constant releaseTag)"
expected_commit="$(read_constant commit)"

if [[ -z "$repository_url" || -z "$expected_tag" || -z "$expected_commit" ]]; then
  echo "Qwen upstream metadata is incomplete in $catalog" >&2
  exit 2
fi

latest_tag="$({
  git ls-remote --tags --sort=-v:refname "$repository_url" 'refs/tags/v[0-9]*'
} | awk '$2 !~ /\^\{\}$/ { sub("refs/tags/", "", $2); print $2; exit }')"

if [[ -z "$latest_tag" ]]; then
  echo "No stable qwen-audio-agent release tag was found" >&2
  exit 2
fi

tag_rows="$(git ls-remote --tags "$repository_url" \
  "refs/tags/$latest_tag" "refs/tags/$latest_tag^{}")"
latest_commit="$(printf '%s\n' "$tag_rows" | awk '$2 ~ /\^\{\}$/ { print $1; exit }')"
if [[ -z "$latest_commit" ]]; then
  latest_commit="$(printf '%s\n' "$tag_rows" | awk 'NR == 1 { print $1 }')"
fi

if [[ "$expected_tag" != "$latest_tag" || "$expected_commit" != "$latest_commit" ]]; then
  printf 'qwen-audio-agent sync drift: App=%s (%s), upstream=%s (%s)\n' \
    "$expected_tag" "$expected_commit" "$latest_tag" "$latest_commit" >&2
  exit 1
fi

printf 'qwen-audio-agent sync OK: %s (%s)\n' "$latest_tag" "$latest_commit"
