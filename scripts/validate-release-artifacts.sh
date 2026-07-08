#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/validate-release-artifacts.sh <artifact-dir> [manifest-dir]

Validates a staged release artifact directory before publication:

- requires SHA256SUMS and ARTIFACTS.md;
- verifies every SHA-256 entry;
- runs unzip integrity checks for .zip artifacts;
- verifies staged prebuilt emulator system-image zips with
  scripts/verify-prebuilt-emulator-image.sh;
- rejects obvious private key / signing key file types;
- scans small text artifacts for common secret markers.
EOF
}

artifact_dir="${1:-}"
manifest_dir="${2:-}"

if [[ -z "$artifact_dir" ]]; then
  usage >&2
  exit 2
fi

artifact_dir="$(cd "$artifact_dir" && pwd)"
if [[ -z "$manifest_dir" ]]; then
  manifest_candidates=("$artifact_dir"/release-v*/ "$artifact_dir"/)
  manifest_dir=""
  for candidate in "${manifest_candidates[@]}"; do
    if [[ -f "$candidate/SHA256SUMS" && -f "$candidate/ARTIFACTS.md" ]]; then
      manifest_dir="$(cd "$candidate" && pwd)"
      break
    fi
  done
  [[ -n "$manifest_dir" ]] || die "could not find SHA256SUMS and ARTIFACTS.md under $artifact_dir"
else
  manifest_dir="$(cd "$manifest_dir" && pwd)"
fi

checksums="$manifest_dir/SHA256SUMS"
manifest="$manifest_dir/ARTIFACTS.md"

[[ -f "$checksums" ]] || die "missing checksum file: $checksums"
[[ -f "$manifest" ]] || die "missing artifact manifest: $manifest"

case "$artifact_dir" in
  "$root"/*) ;;
  *) die "artifact directory must be inside the OpenPhone workspace: $artifact_dir" ;;
esac

while IFS= read -r artifact; do
  name="$(basename "$artifact")"
  case "$name" in
    *.pem|*.pk8|*.key|*.jks|*.keystore|*.p12|*.mobileprovision|claudecode.pem|id_rsa|id_ed25519)
      die "refusing to publish key-like artifact: $name"
      ;;
  esac
done < <(find "$artifact_dir" -maxdepth 1 -type f | sort)

while read -r expected name extra; do
  [[ -n "${expected:-}" ]] || continue
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA-256 entry in $checksums: $expected"
  [[ -z "${extra:-}" ]] || die "unexpected extra checksum columns for $name"
  [[ "$name" != */* ]] || die "checksum entry must be a basename, got: $name"
  artifact="$artifact_dir/$name"
  [[ -f "$artifact" ]] || die "checksum entry has no matching artifact: $name"
  actual="$(file_sha256 "$artifact")"
  [[ "$actual" == "$expected" ]] || die "checksum mismatch for $name: expected $expected got $actual"
done < "$checksums"

while IFS= read -r artifact; do
  case "$artifact" in
    *.zip)
      unzip -tq "$artifact" >/dev/null
      ;;
  esac
done < <(find "$artifact_dir" -maxdepth 1 -type f | sort)

while IFS= read -r artifact; do
  name="$(basename "$artifact")"
  case "$name" in
    sdk-repo-*-system-images-arm64.zip|sdk-repo-*-system-images-x86_64.zip)
      image_arch="${name%.zip}"
      image_arch="${image_arch##*-}"
      "$root/scripts/verify-prebuilt-emulator-image.sh" \
        --zip "$artifact" \
        --arch "$image_arch" \
        --sha256 "$checksums" >/dev/null
      ;;
  esac
done < <(find "$artifact_dir" -maxdepth 1 -type f | sort)

secret_scan_file="$(mktemp)"
find "$artifact_dir" -maxdepth 1 -type f \
  \( -name '*.txt' -o -name '*.md' -o -name '*.json' -o -name '*.log' -o -name '*.xml' -o -name '*.yml' -o -name '*.yaml' \) \
  -size -2M \
  | sort > "$secret_scan_file"

if [[ -s "$secret_scan_file" ]]; then
  if xargs grep -nE \
      '(sk-proj-|sk-[A-Za-z0-9_-]{20,}|BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|PRIVATE KEY-----|AKIA[0-9A-Z]{16}|aws_secret_access_key|ghp_[A-Za-z0-9_]{30,})' \
      < "$secret_scan_file" >/tmp/openphone-release-secret-scan.txt 2>/dev/null; then
    cat /tmp/openphone-release-secret-scan.txt >&2
    rm -f "$secret_scan_file"
    die "possible secret found in release text artifact"
  fi
fi
rm -f "$secret_scan_file"

printf 'Release artifact validation passed.\n'
printf 'Artifact directory: %s\n' "$artifact_dir"
printf 'Manifest directory: %s\n' "$manifest_dir"
