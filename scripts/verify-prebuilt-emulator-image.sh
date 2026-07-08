#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/verify-prebuilt-emulator-image.sh --zip <path> [options]

Verifies a prebuilt OpenPhone SDK emulator system-image zip before it is
published as a release asset or installed into a local Android SDK:

- verifies the zip SHA-256 against a digest, a sidecar file, or a SHA256SUMS
  manifest with an entry for the zip;
- runs a zip integrity check;
- requires exactly one expected ABI directory (arm64-v8a/ or x86_64/);
- requires the packaged system image and build.prop;
- requires OpenPhone product markers in the packaged build.prop, so a stock
  LineageOS image cannot be published as an OpenPhone artifact.

Options:
  --zip <path>              Emulator system-image zip to verify.
  --arch arm64|x86_64       Expected image architecture. Default: inferred
                            from a sdk-repo-linux-system-images-<arch>.zip
                            file name, otherwise taken from the zip contents.
  --sha256 <digest|path>    Expected SHA-256: a 64-hex digest, a sidecar
                            file, or a SHA256SUMS manifest containing an
                            entry whose name matches the zip basename.
                            Default: a <zip>.sha256 sidecar when present;
                            otherwise the checksum step is skipped.
  --skip-product-check      Skip the OpenPhone build.prop marker checks.
  -h, --help                Show this help.
EOF
}

abi_for_arch() {
  case "$1" in
    arm64) printf 'arm64-v8a' ;;
    x86_64) printf 'x86_64' ;;
    *) die "unsupported emulator arch: $1" ;;
  esac
}

image_zip=""
arch=""
sha256_source=""
skip_product_check=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip)
      [[ $# -ge 2 ]] || die "--zip requires a value"
      image_zip="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires a value"
      arch="$2"
      shift 2
      ;;
    --sha256)
      [[ $# -ge 2 ]] || die "--sha256 requires a value"
      sha256_source="$2"
      shift 2
      ;;
    --skip-product-check)
      skip_product_check=true
      shift
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

[[ -n "$image_zip" ]] || die "--zip is required"
[[ -f "$image_zip" ]] || die "emulator image zip not found: $image_zip"

zip_name="$(basename "$image_zip")"

if [[ -z "$arch" ]]; then
  case "$zip_name" in
    sdk-repo-*-system-images-arm64.zip) arch="arm64" ;;
    sdk-repo-*-system-images-x86_64.zip) arch="x86_64" ;;
  esac
fi
if [[ -n "$arch" ]]; then
  case "$arch" in
    arm64|x86_64) ;;
    *) die "unsupported emulator arch: $arch" ;;
  esac
fi

if command -v unzip >/dev/null 2>&1; then
  extractor="unzip"
elif command -v bsdtar >/dev/null 2>&1; then
  extractor="bsdtar"
else
  die "missing extractor: install unzip or bsdtar"
fi

# --- checksum -----------------------------------------------------------

expected_sha256=""
if [[ -z "$sha256_source" && -f "$image_zip.sha256" ]]; then
  sha256_source="$image_zip.sha256"
fi

if [[ -n "$sha256_source" ]]; then
  if [[ "$sha256_source" =~ ^[[:xdigit:]]{64}$ ]]; then
    expected_sha256="$sha256_source"
  else
    [[ -f "$sha256_source" ]] || die "checksum file not found: $sha256_source"
    # SHA256SUMS-style lookup by basename first, then fall back to treating
    # the file as a single-digest sidecar.
    expected_sha256="$(
      awk -v name="$zip_name" \
        '$2 == name && $1 ~ /^[0-9a-fA-F]{64}$/ { print $1; exit }' \
        "$sha256_source"
    )"
    if [[ -z "$expected_sha256" ]]; then
      expected_sha256="$(grep -Eo '[[:xdigit:]]{64}' "$sha256_source" | head -n 1 || true)"
    fi
    [[ -n "$expected_sha256" ]] \
      || die "no SHA-256 digest for $zip_name in $sha256_source"
  fi

  actual_sha256="$(file_sha256 "$image_zip")"
  expected_lower="$(printf '%s' "$expected_sha256" | tr '[:upper:]' '[:lower:]')"
  [[ "$actual_sha256" == "$expected_lower" ]] \
    || die "checksum mismatch for $zip_name: expected $expected_lower got $actual_sha256"
  info "Verified emulator image SHA-256: $zip_name"
else
  info "No SHA-256 supplied for $zip_name; skipping checksum verification"
fi

# --- structure ----------------------------------------------------------

entries_file="$(mktemp "${TMPDIR:-/tmp}/openphone-image-entries.XXXXXX")"
trap 'rm -f "$entries_file"' EXIT

case "$extractor" in
  unzip)
    unzip -tq "$image_zip" >/dev/null || die "zip integrity check failed: $image_zip"
    unzip -Z1 "$image_zip" > "$entries_file"
    ;;
  bsdtar)
    bsdtar -tf "$image_zip" > "$entries_file" \
      || die "zip integrity check failed: $image_zip"
    ;;
esac

[[ -s "$entries_file" ]] || die "emulator image zip is empty: $image_zip"

found_abis=()
for candidate in arm64-v8a x86_64; do
  if grep -Eq "^(\./)?${candidate}/" "$entries_file"; then
    found_abis+=("$candidate")
  fi
done

[[ "${#found_abis[@]}" -ge 1 ]] \
  || die "no ABI directory (arm64-v8a/ or x86_64/) found in $zip_name"
[[ "${#found_abis[@]}" -eq 1 ]] \
  || die "multiple ABI directories found in $zip_name: ${found_abis[*]}"
abi="${found_abis[0]}"

if [[ -n "$arch" ]]; then
  expected_abi="$(abi_for_arch "$arch")"
  [[ "$abi" == "$expected_abi" ]] \
    || die "ABI mismatch for $zip_name: expected $expected_abi (--arch $arch) got $abi"
else
  case "$abi" in
    arm64-v8a) arch="arm64" ;;
    x86_64) arch="x86_64" ;;
  esac
fi

for member in "$abi/system.img" "$abi/build.prop"; do
  grep -Eq "^(\./)?$member\$" "$entries_file" \
    || die "emulator image zip is missing $member: $zip_name"
done

# --- OpenPhone product markers ------------------------------------------

if [[ "$skip_product_check" != true ]]; then
  build_prop="$(
    case "$extractor" in
      unzip) unzip -p "$image_zip" "$abi/build.prop" ;;
      bsdtar) bsdtar -xOf "$image_zip" "$abi/build.prop" ;;
    esac
  )"
  [[ -n "$build_prop" ]] || die "failed to read $abi/build.prop from $zip_name"

  printf '%s' "$build_prop" | grep -q "openphone" \
    || die "build.prop has no OpenPhone marker; this does not look like an OpenPhone image: $zip_name"
  printf '%s' "$build_prop" | grep -q "openphone_sdk_phone_${arch}" \
    || die "build.prop does not name product openphone_sdk_phone_${arch}: $zip_name"
fi

info "Verified OpenPhone emulator image: $zip_name (arch=$arch abi=$abi)"
