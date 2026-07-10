#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 vMAJOR.MINOR.PATCH" >&2
  exit 64
fi

tag="$1"

# Releases intentionally accept only canonical, stable SemVer tags. Besides
# preventing accidental prereleases, this keeps every value later used in a
# filename, URL, output, or commit message free of shell metacharacters.
if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Release tag must match canonical vMAJOR.MINOR.PATCH syntax." >&2
  exit 64
fi

printf '%s\n' "${tag#v}"
