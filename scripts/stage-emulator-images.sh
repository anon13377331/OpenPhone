#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/stage-emulator-images.sh --version <tag> --output-dir <dir> [options]

Stages built OpenPhone SDK emulator system-image zips for release publication.
For each requested arch it copies
  <android-dir>/out/target/product/<emu64a|emu64x>/sdk-repo-linux-system-images.zip
into the release staging directory as
  sdk-repo-linux-system-images-<arch>.zip
writes a `.sha256` sidecar next to it, and verifies the staged zip with
scripts/verify-prebuilt-emulator-image.sh.

Run this before generate-release-manifest.sh so the staged images land in
SHA256SUMS and ARTIFACTS.md.

Options:
  --version <tag>           Release version, for example v0.0.2.
  --output-dir <dir>        Release staging directory.
  --android-dir <dir>       Android checkout path.
                            Default: OPENPHONE_ANDROID_DIR.
  --archs "<a> <b>"         Space-separated archs to stage from arm64/x86_64.
                            Default: "arm64 x86_64".
  -h, --help                Show this help.

Environment:
  OPENPHONE_ALLOW_OVERSIZED_EMULATOR_IMAGE=1
                            Stage zips larger than the 2 GiB GitHub release
                            asset limit instead of failing.
EOF
}

emulator_product_dir_for_arch() {
  case "$1" in
    arm64) printf 'emu64a' ;;
    x86_64) printf 'emu64x' ;;
    *) die "unsupported emulator arch: $1" ;;
  esac
}

version=""
output_dir=""
android_dir="$OPENPHONE_ANDROID_DIR"
archs="arm64 x86_64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      version="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    --android-dir)
      [[ $# -ge 2 ]] || die "--android-dir requires a value"
      android_dir="$2"
      shift 2
      ;;
    --archs)
      [[ $# -ge 2 ]] || die "--archs requires a value"
      archs="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$version" ]] || die "--version is required"
[[ -n "$output_dir" ]] || die "--output-dir is required"
[[ -n "$archs" ]] || die "--archs must name at least one arch"
[[ -d "$android_dir" ]] || die "Android tree not found: $android_dir"

for arch in $archs; do
  case "$arch" in
    arm64|x86_64) ;;
    *) die "unsupported emulator arch: $arch" ;;
  esac
done

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

# GitHub rejects release assets larger than 2 GiB.
github_asset_limit_bytes=$((2 * 1024 * 1024 * 1024))

staged=()
for arch in $archs; do
  product_dir="$(emulator_product_dir_for_arch "$arch")"
  source_zip="$android_dir/out/target/product/$product_dir/sdk-repo-linux-system-images.zip"
  [[ -f "$source_zip" ]] || die "emulator image zip not found for $arch: $source_zip; build it with scripts/build-emulator.sh --arch $arch"

  staged_name="sdk-repo-linux-system-images-${arch}.zip"
  staged_zip="$output_dir/$staged_name"

  size_bytes="$(wc -c < "$source_zip" | tr -d ' ')"
  if [[ "$size_bytes" -ge "$github_asset_limit_bytes" ]]; then
    if [[ "${OPENPHONE_ALLOW_OVERSIZED_EMULATOR_IMAGE:-0}" == "1" ]]; then
      info "WARNING: $staged_name is ${size_bytes} bytes, over the 2 GiB GitHub release asset limit"
    else
      die "$staged_name is ${size_bytes} bytes, over the 2 GiB GitHub release asset limit; set OPENPHONE_ALLOW_OVERSIZED_EMULATOR_IMAGE=1 to stage it anyway"
    fi
  fi

  info "Staging emulator image for $arch: $staged_name"
  cp "$source_zip" "$staged_zip"

  digest="$(file_sha256 "$staged_zip")"
  printf '%s  %s\n' "$digest" "$staged_name" > "$staged_zip.sha256"

  "$root/scripts/verify-prebuilt-emulator-image.sh" \
    --zip "$staged_zip" \
    --arch "$arch" \
    --sha256 "$digest"

  staged+=("$staged_zip")
done

info "Staged ${#staged[@]} emulator image(s) for $version into $output_dir"
for path in "${staged[@]}"; do
  printf '%s\n' "$path"
done
