#!/usr/bin/env bash

# Contract checks for the prebuilt emulator image tooling. Builds small
# fixture zips with the sdk-repo layout (no Android build needed) and runs
# the verify/stage/manifest/validate/install pipeline against them, including
# the failure paths a corrupted or non-OpenPhone image must hit.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

need_cmd python3
need_cmd unzip

# validate-release-artifacts.sh requires artifact dirs inside the workspace,
# so fixtures live under the ignored .worktree/ tree.
mkdir -p "$root/.worktree"
fixture_root="$(mktemp -d "$root/.worktree/emulator-image-check.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

make_fixture_zip() {
  local zip_path="$1"
  local abi="$2"
  local product="$3"
  python3 - "$zip_path" "$abi" "$product" <<'PY'
import sys
import zipfile

zip_path, abi, product = sys.argv[1], sys.argv[2], sys.argv[3]
build_prop_lines = [
    "ro.build.version.release=16",
    "ro.openphone.version=0.0.0-check",
]
if product:
    build_prop_lines.insert(0, f"ro.product.system.name={product}")
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr(f"{abi}/system.img", b"openphone-fixture-system-image")
    zf.writestr(f"{abi}/build.prop", "\n".join(build_prop_lines) + "\n")
    zf.writestr(f"{abi}/source.properties", "Pkg.Revision=1\n")
PY
}

expect_failure() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    die "expected failure but command passed: $description"
  fi
}

verify="$root/scripts/verify-prebuilt-emulator-image.sh"

# --- verify: pass paths --------------------------------------------------

good_x86="$fixture_root/sdk-repo-linux-system-images-x86_64.zip"
make_fixture_zip "$good_x86" "x86_64" "openphone_sdk_phone_x86_64"
good_x86_sha="$(file_sha256 "$good_x86")"

good_arm64="$fixture_root/sdk-repo-linux-system-images-arm64.zip"
make_fixture_zip "$good_arm64" "arm64-v8a" "openphone_sdk_phone_arm64"
good_arm64_sha="$(file_sha256 "$good_arm64")"

"$verify" --zip "$good_x86" --arch x86_64 --sha256 "$good_x86_sha" >/dev/null
"$verify" --zip "$good_arm64" --arch arm64 --sha256 "$good_arm64_sha" >/dev/null

# Arch inference from the file name, digest from a SHA256SUMS manifest.
sums_file="$fixture_root/SHA256SUMS"
{
  printf '%s  %s\n' "$good_x86_sha" "$(basename "$good_x86")"
  printf '%s  %s\n' "$good_arm64_sha" "$(basename "$good_arm64")"
} > "$sums_file"
"$verify" --zip "$good_x86" --sha256 "$sums_file" >/dev/null
"$verify" --zip "$good_arm64" --sha256 "$sums_file" >/dev/null

# Sidecar auto-discovery.
printf '%s  %s\n' "$good_x86_sha" "$(basename "$good_x86")" > "$good_x86.sha256"
"$verify" --zip "$good_x86" >/dev/null
rm -f "$good_x86.sha256"

# --- verify: failure paths -----------------------------------------------

expect_failure "wrong digest" \
  "$verify" --zip "$good_x86" --arch x86_64 \
  --sha256 "0000000000000000000000000000000000000000000000000000000000000000"

expect_failure "arch mismatch" \
  "$verify" --zip "$good_x86" --arch arm64 --sha256 "$good_x86_sha"

bad_abi="$fixture_root/bad-abi.zip"
make_fixture_zip "$bad_abi" "x86" "openphone_sdk_phone_x86_64"
expect_failure "unexpected ABI directory" "$verify" --zip "$bad_abi"

missing_system="$fixture_root/missing-system.zip"
python3 - "$missing_system" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("x86_64/build.prop", "ro.product.system.name=openphone_sdk_phone_x86_64\n")
PY
expect_failure "missing system.img" "$verify" --zip "$missing_system"

stock_image="$fixture_root/stock-lineage.zip"
python3 - "$stock_image" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("x86_64/system.img", b"stock")
    zf.writestr("x86_64/build.prop", "ro.product.system.name=lineage_sdk_phone_x86_64\n")
PY
expect_failure "stock image without OpenPhone markers" \
  "$verify" --zip "$stock_image" --arch x86_64
"$verify" --zip "$stock_image" --arch x86_64 --skip-product-check >/dev/null

# --- stage + manifest + validate pipeline --------------------------------

fake_android_dir="$fixture_root/android"
mkdir -p "$fake_android_dir/out/target/product/emu64x" \
  "$fake_android_dir/out/target/product/emu64a"
make_fixture_zip \
  "$fake_android_dir/out/target/product/emu64x/sdk-repo-linux-system-images.zip" \
  "x86_64" "openphone_sdk_phone_x86_64"
make_fixture_zip \
  "$fake_android_dir/out/target/product/emu64a/sdk-repo-linux-system-images.zip" \
  "arm64-v8a" "openphone_sdk_phone_arm64"

staging_dir="$fixture_root/release-stage"
"$root/scripts/stage-emulator-images.sh" \
  --android-dir "$fake_android_dir" \
  --version v0.0.0-check \
  --output-dir "$staging_dir" \
  --archs "arm64 x86_64" >/dev/null

for staged in \
    "$staging_dir/sdk-repo-linux-system-images-arm64.zip" \
    "$staging_dir/sdk-repo-linux-system-images-x86_64.zip"; do
  [[ -f "$staged" ]] || die "stage-emulator-images did not stage: $staged"
  [[ -f "$staged.sha256" ]] || die "stage-emulator-images did not write sidecar: $staged.sha256"
done

"$root/scripts/generate-release-manifest.sh" \
  v0.0.0-check "$staging_dir" "$staging_dir" >/dev/null
grep -q "verify-prebuilt-emulator-image.sh" "$staging_dir/ARTIFACTS.md" \
  || die "ARTIFACTS.md is missing the emulator image validation note"
"$root/scripts/validate-release-artifacts.sh" "$staging_dir" >/dev/null

# Tampering with a staged image must fail release validation.
printf 'tampered' >> "$staging_dir/sdk-repo-linux-system-images-x86_64.zip"
expect_failure "tampered staged image passes validation" \
  "$root/scripts/validate-release-artifacts.sh" "$staging_dir"

# --- consumer install path ------------------------------------------------

fake_sdk="$fixture_root/sdk"
"$root/scripts/lab/install-emulator-image.sh" \
  --zip "$good_x86" \
  --sha256 "$good_x86_sha" \
  --arch x86_64 \
  --sdk-root "$fake_sdk" >/dev/null
installed_dir="$fake_sdk/system-images/android-36.1/lineage/x86_64"
[[ -f "$installed_dir/system.img" ]] \
  || die "install-emulator-image did not install system.img: $installed_dir"
[[ -f "$installed_dir/.openphone-image-sha256" ]] \
  || die "install-emulator-image did not record the image SHA-256"

printf 'Emulator image tooling checks passed.\n'
