#!/usr/bin/env bash

set -euo pipefail

CHANNEL=""
REF_TYPE=""
UPSTREAM_REF=""
UPSTREAM_SHA=""
SOURCE_URL=""
RELEASE_TAG=""
RELEASE_NAME=""
OUTPUT_DIR=""
UPSTREAM_REPO_URL="https://github.com/mullvad/mullvadvpn-app.git"

usage() {
  cat <<'EOF'
Usage: build-one.sh --channel CHANNEL --ref-type tag|commit --upstream-ref REF --upstream-sha SHA --source-url URL --release-tag TAG --release-name NAME --output-dir DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL="${2:-}"
      shift 2
      ;;
    --ref-type)
      REF_TYPE="${2:-}"
      shift 2
      ;;
    --upstream-ref)
      UPSTREAM_REF="${2:-}"
      shift 2
      ;;
    --upstream-sha)
      UPSTREAM_SHA="${2:-}"
      shift 2
      ;;
    --source-url)
      SOURCE_URL="${2:-}"
      shift 2
      ;;
    --release-tag)
      RELEASE_TAG="${2:-}"
      shift 2
      ;;
    --release-name)
      RELEASE_NAME="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
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

for required in CHANNEL REF_TYPE UPSTREAM_REF SOURCE_URL RELEASE_TAG RELEASE_NAME OUTPUT_DIR; do
  if [[ -z "${!required}" ]]; then
    echo "Missing required value: $required" >&2
    exit 1
  fi
done

workdir="$(mktemp -d)"
src_dir="$workdir/mullvadvpn-app"

cleanup() {
  rm -rf "$workdir"
}

trap cleanup EXIT

echo "Cloning upstream repository into $src_dir"
git clone --filter=blob:none "$UPSTREAM_REPO_URL" "$src_dir"

cd "$src_dir"

checkout_target="$UPSTREAM_REF"
if [[ "$REF_TYPE" == "commit" && -n "$UPSTREAM_SHA" ]]; then
  checkout_target="$UPSTREAM_SHA"
fi

echo "Checking out $checkout_target"
git checkout --detach "$checkout_target"

echo "Fetching required submodules"
git submodule update --init --depth 1 dist-assets/binaries wireguard-go-rs/libwg/wireguard-go

if [[ -x "./scripts/setup-rust" ]]; then
  echo "Preparing Rust toolchain"
  ./scripts/setup-rust linux
fi

echo "Building x86_64 RPM for channel $CHANNEL"
./build.sh --optimize

artifact_path="$(
  find dist -maxdepth 1 -type f -name 'MullvadVPN-*x86_64.rpm' \
    | sort \
    | head -n1
)"

if [[ -z "$artifact_path" ]]; then
  echo "Expected x86_64 RPM artifact was not produced" >&2
  exit 1
fi

resolved_sha="$(git rev-parse HEAD)"
built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$OUTPUT_DIR"
copied_artifact="$OUTPUT_DIR/$(basename "$artifact_path")"
cp "$artifact_path" "$copied_artifact"

jq -n \
  --arg channel "$CHANNEL" \
  --arg release_tag "$RELEASE_TAG" \
  --arg release_name "$RELEASE_NAME" \
  --arg upstream_ref "$UPSTREAM_REF" \
  --arg upstream_sha "$resolved_sha" \
  --arg source_url "$SOURCE_URL" \
  --arg built_at "$built_at" \
  --arg artifact_name "$(basename "$copied_artifact")" \
  --arg artifact_path "$copied_artifact" \
  '{
    channel: $channel,
    release_tag: $release_tag,
    release_name: $release_name,
    upstream_ref: $upstream_ref,
    upstream_sha: $upstream_sha,
    source_url: $source_url,
    built_at: $built_at,
    artifact_name: $artifact_name,
    artifact_path: $artifact_path
  }' >"$OUTPUT_DIR/metadata.json"

echo "Build complete: $copied_artifact"
