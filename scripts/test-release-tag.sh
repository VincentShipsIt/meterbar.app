#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
validator="$script_dir/validate-release-tag.sh"

valid_tags=(v0.0.0 v1.2.3 v12.34.56)
expected_versions=(0.0.0 1.2.3 12.34.56)

for index in "${!valid_tags[@]}"; do
  actual=$("$validator" "${valid_tags[$index]}")
  if [ "$actual" != "${expected_versions[$index]}" ]; then
    echo "Unexpected normalized version for a valid release tag." >&2
    exit 1
  fi
done

# The command substitution is intentionally literal attack input.
# shellcheck disable=SC2016
invalid_tags=(
  v1
  v1.2
  v1.2.3-rc.1
  v01.2.3
  'v1$(id).2.3'
  'v1;id.2.3'
  1.2.3
  'v1.2.3 '
)

for tag in "${invalid_tags[@]}"; do
  if "$validator" "$tag" >/dev/null 2>&1; then
    echo "Invalid release tag was accepted." >&2
    exit 1
  fi
done

echo "Release tag validation cases passed."
