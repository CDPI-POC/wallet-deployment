#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/sources"

fetch_repo() {
  local name="$1"
  local repo="$2"
  local tag="$3"
  local dest="$ROOT/sources/${name}-${tag#v}"

  if [[ -d "$dest/.git" ]]; then
    echo "Already present: $dest"
    return
  fi

  if [[ -e "$dest" ]]; then
    echo "ERROR: Existing directory is not a Git checkout: $dest" >&2
    return 1
  fi

  echo "Fetching $repo at $tag"

  git clone \
    --depth 1 \
    --branch "$tag" \
    "https://github.com/$repo.git" \
    "$dest"

  local actual
  actual=$(git -C "$dest" describe --tags --exact-match HEAD)

  [[ "$actual" == "$tag" ]] || {
    echo "ERROR: Unexpected Git tag for $repo: $actual" >&2
    return 1
  }
}

fetch_repo inji-certify inji/inji-certify v0.14.0
fetch_repo inji-verify inji/inji-verify v0.18.0
fetch_repo mimoto inji/mimoto v0.21.0
fetch_repo inji-web inji/inji-web v0.16.0

echo "Pinned Inji source repositories fetched successfully."
