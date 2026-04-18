#!/usr/bin/env bash

set -euo pipefail

TARGET_REPO=""
METADATA_PATH=""

usage() {
  cat <<'EOF'
Usage: publish-release.sh --repo owner/name --metadata /path/to/metadata.json
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      TARGET_REPO="${2:-}"
      shift 2
      ;;
    --metadata)
      METADATA_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET_REPO" || -z "$METADATA_PATH" ]]; then
  usage >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "gh and jq are required" >&2
  exit 1
fi

if [[ ! -f "$METADATA_PATH" ]]; then
  echo "Metadata file not found: $METADATA_PATH" >&2
  exit 1
fi

release_tag="$(jq -r '.release_tag' "$METADATA_PATH")"
release_name="$(jq -r '.release_name' "$METADATA_PATH")"
channel="$(jq -r '.channel' "$METADATA_PATH")"
upstream_ref="$(jq -r '.upstream_ref' "$METADATA_PATH")"
upstream_sha="$(jq -r '.upstream_sha' "$METADATA_PATH")"
source_url="$(jq -r '.source_url' "$METADATA_PATH")"
built_at="$(jq -r '.built_at' "$METADATA_PATH")"
artifact_name="$(jq -r '.artifact_name' "$METADATA_PATH")"
artifact_path="$(jq -r '.artifact_path' "$METADATA_PATH")"

if [[ ! -f "$artifact_path" ]]; then
  echo "Artifact file not found: $artifact_path" >&2
  exit 1
fi

notes_file="$(mktemp)"
trap 'rm -f "$notes_file"' EXIT

{
  echo "Automated Mullvad RPM build for \`$channel\`."
  echo
  echo "upstream_channel=$channel"
  echo "upstream_ref=$upstream_ref"
  echo "upstream_sha=$upstream_sha"
  echo "built_at=$built_at"
  echo "source_url=$source_url"
  echo "artifact_name=$artifact_name"
} >"$notes_file"

echo "Publishing $artifact_name to release $release_tag in $TARGET_REPO"

if gh release view "$release_tag" --repo "$TARGET_REPO" >/dev/null 2>&1; then
  while IFS= read -r old_asset; do
    [[ -n "$old_asset" ]] || continue
    gh release delete-asset "$release_tag" "$old_asset" --repo "$TARGET_REPO" --yes
  done < <(
    gh release view "$release_tag" \
      --repo "$TARGET_REPO" \
      --json assets \
      --jq '(.assets // [])[] | .name'
  )

  gh release edit "$release_tag" \
    --repo "$TARGET_REPO" \
    --title "$release_name" \
    --notes-file "$notes_file"
else
  gh release create "$release_tag" \
    "$artifact_path" \
    --repo "$TARGET_REPO" \
    --target "${GITHUB_SHA:-HEAD}" \
    --title "$release_name" \
    --notes-file "$notes_file"
  exit 0
fi

gh release upload "$release_tag" "$artifact_path" --repo "$TARGET_REPO" --clobber
