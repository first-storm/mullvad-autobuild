#!/usr/bin/env bash

set -euo pipefail

UPSTREAM_REPO="mullvad/mullvadvpn-app"
CHANNEL="all"
FORCE="false"
TARGET_REPO=""
MANUAL_REF=""
MANUAL_REF_TYPE="auto"

usage() {
  cat <<'EOF'
Usage: resolve-targets.sh --repo owner/name [--channel all|stable|beta|main] [--force true|false] [--manual-ref REF] [--manual-ref-type auto|tag|commit]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL="${2:-}"
      shift 2
      ;;
    --force)
      FORCE="${2:-}"
      shift 2
      ;;
    --repo)
      TARGET_REPO="${2:-}"
      shift 2
      ;;
    --manual-ref)
      MANUAL_REF="${2:-}"
      shift 2
      ;;
    --manual-ref-type)
      MANUAL_REF_TYPE="${2:-}"
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

if [[ -z "$TARGET_REPO" ]]; then
  echo "--repo is required" >&2
  exit 1
fi

case "$MANUAL_REF_TYPE" in
  auto|tag|commit)
    ;;
  *)
    echo "Unsupported manual ref type: $MANUAL_REF_TYPE" >&2
    exit 1
    ;;
esac

if [[ -n "$MANUAL_REF" && "$CHANNEL" == "all" ]]; then
  echo "manual-ref requires a single channel, not channel=all" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "curl and jq are required" >&2
  exit 1
fi

api_get() {
  local url="$1"
  local response
  local status
  local -a curl_args

  curl_args=(
    --silent
    --show-error
    --location
    --write-out $'\n%{http_code}'
    --header "Accept: application/vnd.github+json"
    --header "X-GitHub-Api-Version: 2022-11-28"
    --header "User-Agent: mullvad-autobuild"
  )

  if [[ -n "${GH_TOKEN:-}" ]]; then
    curl_args+=(--header "Authorization: Bearer ${GH_TOKEN}")
  fi

  response="$(
    curl "${curl_args[@]}" "$url"
  )"

  status="$(tail -n1 <<<"$response")"
  body="$(sed '$d' <<<"$response")"

  if [[ "$status" == "404" ]]; then
    return 4
  fi

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "GitHub API request failed for $url with status $status" >&2
    echo "$body" >&2
    exit 1
  fi

  printf '%s\n' "$body"
}

release_body_for_tag() {
  local repo="$1"
  local tag="$2"
  local body

  if body="$(api_get "https://api.github.com/repos/${repo}/releases/tags/${tag}")"; then
    jq -r '.body // ""' <<<"$body"
  else
    printf '\n'
  fi
}

meta_value() {
  local body="$1"
  local key="$2"
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' <<<"$body"
}

select_release_with_rpm() {
  local prerelease_expected="$1"
  local releases_json
  local release_json

  releases_json="$(api_get "https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=30")"
  release_json="$(
    jq -c \
      --argjson prerelease_expected "$prerelease_expected" \
      '
      [
        .[]
        | select(.draft == false and .prerelease == $prerelease_expected)
        | select(any(.assets[]?; .name | endswith("_x86_64.rpm")))
      ][0]
      ' <<<"$releases_json"
  )"

  if [[ "$release_json" == "null" ]]; then
    if [[ "$prerelease_expected" == "true" ]]; then
      echo "Unable to find a beta release with an x86_64 RPM asset in ${UPSTREAM_REPO}" >&2
    else
      echo "Unable to find a stable release with an x86_64 RPM asset in ${UPSTREAM_REPO}" >&2
    fi
    exit 1
  fi

  printf '%s\n' "$release_json"
}

resolve_manual_target() {
  local current_channel="$1"
  local upstream_ref=""
  local upstream_sha=""
  local source_url=""
  local ref_type=""
  local commit_json=""

  case "$MANUAL_REF_TYPE" in
    tag)
      ref_type="tag"
      upstream_ref="$MANUAL_REF"
      source_url="https://github.com/${UPSTREAM_REPO}/releases/tag/${MANUAL_REF}"
      ;;
    commit)
      ref_type="commit"
      commit_json="$(api_get "https://api.github.com/repos/${UPSTREAM_REPO}/commits/${MANUAL_REF}")"
      upstream_ref="$current_channel"
      upstream_sha="$(jq -r '.sha' <<<"$commit_json")"
      source_url="$(jq -r '.html_url' <<<"$commit_json")"
      ;;
    auto)
      if [[ "$current_channel" == "main" ]]; then
        ref_type="commit"
        commit_json="$(api_get "https://api.github.com/repos/${UPSTREAM_REPO}/commits/${MANUAL_REF}")"
        upstream_ref="$MANUAL_REF"
        upstream_sha="$(jq -r '.sha' <<<"$commit_json")"
        source_url="$(jq -r '.html_url' <<<"$commit_json")"
      else
        ref_type="tag"
        upstream_ref="$MANUAL_REF"
        source_url="https://github.com/${UPSTREAM_REPO}/releases/tag/${MANUAL_REF}"
      fi
      ;;
  esac

  jq -cn \
    --arg ref_type "$ref_type" \
    --arg upstream_ref "$upstream_ref" \
    --arg upstream_sha "$upstream_sha" \
    --arg source_url "$source_url" \
    '{
      ref_type: $ref_type,
      upstream_ref: $upstream_ref,
      upstream_sha: $upstream_sha,
      source_url: $source_url
    }'
}

selected_channels() {
  case "$CHANNEL" in
    all)
      printf '%s\n' stable beta main
      ;;
    stable|beta|main)
      printf '%s\n' "$CHANNEL"
      ;;
    *)
      echo "Unsupported channel: $CHANNEL" >&2
      exit 1
      ;;
  esac
}

json_items=()

while IFS= read -r current_channel; do
  [[ -n "$current_channel" ]] || continue

  release_tag="autobuild-${current_channel}-x86_64"
  release_name="Mullvad ${current_channel} x86_64"

  upstream_ref=""
  upstream_sha=""
  source_url=""
  ref_type=""

  if [[ -n "$MANUAL_REF" ]]; then
    manual_json="$(resolve_manual_target "$current_channel")"
    upstream_ref="$(jq -r '.upstream_ref' <<<"$manual_json")"
    upstream_sha="$(jq -r '.upstream_sha' <<<"$manual_json")"
    source_url="$(jq -r '.source_url' <<<"$manual_json")"
    ref_type="$(jq -r '.ref_type' <<<"$manual_json")"
  else

    case "$current_channel" in
      stable)
        release_json="$(select_release_with_rpm false)"
        upstream_ref="$(jq -r '.tag_name' <<<"$release_json")"
        source_url="$(jq -r '.html_url' <<<"$release_json")"
        ref_type="tag"
        ;;
      beta)
        release_json="$(select_release_with_rpm true)"
        upstream_ref="$(jq -r '.tag_name' <<<"$release_json")"
        source_url="$(jq -r '.html_url' <<<"$release_json")"
        ref_type="tag"
        ;;
      main)
        repo_json="$(api_get "https://api.github.com/repos/${UPSTREAM_REPO}")"
        default_branch="$(jq -r '.default_branch' <<<"$repo_json")"
        commit_json="$(api_get "https://api.github.com/repos/${UPSTREAM_REPO}/commits/${default_branch}")"
        upstream_ref="$default_branch"
        upstream_sha="$(jq -r '.sha' <<<"$commit_json")"
        source_url="$(jq -r '.html_url' <<<"$commit_json")"
        ref_type="commit"
        ;;
    esac
  fi

  existing_body="$(release_body_for_tag "$TARGET_REPO" "$release_tag")"
  existing_ref="$(meta_value "$existing_body" "upstream_ref")"
  existing_sha="$(meta_value "$existing_body" "upstream_sha")"

  skip_build="false"
  if [[ "$FORCE" != "true" ]]; then
    if [[ "$current_channel" == "main" && -n "$upstream_sha" && "$existing_sha" == "$upstream_sha" ]]; then
      skip_build="true"
    fi

    if [[ "$current_channel" != "main" && -n "$upstream_ref" && "$existing_ref" == "$upstream_ref" ]]; then
      skip_build="true"
    fi
  fi

  if [[ "$skip_build" == "true" ]]; then
    echo "Skipping ${current_channel}: upstream ref already published." >&2
    continue
  fi

  item="$(jq -cn \
    --arg channel "$current_channel" \
    --arg ref_type "$ref_type" \
    --arg upstream_ref "$upstream_ref" \
    --arg upstream_sha "$upstream_sha" \
    --arg source_url "$source_url" \
    --arg release_tag "$release_tag" \
    --arg release_name "$release_name" \
    '{
      channel: $channel,
      ref_type: $ref_type,
      upstream_ref: $upstream_ref,
      upstream_sha: $upstream_sha,
      source_url: $source_url,
      release_tag: $release_tag,
      release_name: $release_name
    }'
  )"
  json_items+=("$item")
done < <(selected_channels)

if [[ ${#json_items[@]} -eq 0 ]]; then
  printf '[]\n'
  exit 0
fi

printf '%s\n' "${json_items[@]}" | jq -s -c '.'
