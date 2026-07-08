#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/generate-release-manifest.sh <version> <artifact-dir> [output-dir]

Generates SHA256SUMS and a markdown artifact manifest for release artifacts.

Example:
  scripts/generate-release-manifest.sh 0.0.1 .worktree/artifacts/tegu
EOF
}

version="${1:-}"
artifact_dir="${2:-}"
output_dir="${3:-}"

if [[ -z "$version" || -z "$artifact_dir" ]]; then
  usage >&2
  exit 2
fi

if [[ "$version" != v* ]]; then
  tag="v$version"
else
  tag="$version"
fi

artifact_dir="$(cd "$artifact_dir" && pwd)"
if [[ -z "$output_dir" ]]; then
  output_dir="$artifact_dir/release-$tag"
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

checksums="$output_dir/SHA256SUMS"
manifest="$output_dir/ARTIFACTS.md"

tmp_list="$(mktemp)"
find "$artifact_dir" -maxdepth 1 -type f \
  ! -name 'SHA256SUMS' \
  ! -name 'ARTIFACTS.md' \
  ! -name '.DS_Store' \
  | sort > "$tmp_list"

if [[ ! -s "$tmp_list" ]]; then
  rm -f "$tmp_list"
  die "no release artifacts found in $artifact_dir"
fi

: > "$checksums"
while IFS= read -r artifact; do
  hash="$(file_sha256 "$artifact")"
  printf '%s  %s\n' "$hash" "$(basename "$artifact")" >> "$checksums"
done < "$tmp_list"

{
  printf '# OpenPhone %s Artifact Manifest\n\n' "$tag"
  printf 'Generated: `%s`\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Artifact directory: `%s`\n\n' "$artifact_dir"
  printf '## Files\n\n'
  printf '| File | Size | SHA-256 |\n'
  printf '| --- | ---: | --- |\n'
  while IFS= read -r artifact; do
    name="$(basename "$artifact")"
    size="$(wc -c < "$artifact" | tr -d ' ')"
    hash="$(file_sha256 "$artifact")"
    printf '| `%s` | %s | `%s` |\n' "$name" "$size" "$hash"
  done < "$tmp_list"
  printf '\n## Validation Notes\n\n'
  printf -- '- Verify OTA ZIPs with `unzip -tq <artifact>.zip` before publishing.\n'
  printf -- '- Record `./scripts/verify-tegu-device.sh` output for every Pixel 9a OTA that is published.\n'
  printf -- '- Record hardware smoke-test evidence with `./scripts/smoke-test-tegu-hardware.sh` when ADB shell is usable.\n'
  if grep -Eq 'sdk-repo-.*-system-images-(arm64|x86_64)\.zip$' "$tmp_list"; then
    printf -- '- Verify emulator system-image zips with `scripts/verify-prebuilt-emulator-image.sh --zip <artifact> --sha256 SHA256SUMS`.\n'
    printf -- '- The release lab boot-gates the x86_64 emulator image; arm64 images are structurally verified and boot-validated on Apple Silicon hosts.\n'
  fi
  printf -- '- Do not publish artifacts containing API keys, private SSH keys, signing keys, or device secrets.\n'
} > "$manifest"

rm -f "$tmp_list"

printf 'Release checksums written to %s\n' "$checksums"
printf 'Release manifest written to %s\n' "$manifest"
