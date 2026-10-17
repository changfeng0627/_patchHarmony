#!/bin/bash
# The DDK supplies the toolchain only; its patched modpost is never used.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TARGET_SHA=b0a9599c6c01ec540e2252ca3a0e87b5b8c47c97
TARGET_RELEASE=6.12.58-android16-6-gb0a9599c6c01-ab14987696-4k
BUILD_ID=14987696
SOURCE=$ROOT/.target/source
BUILD=$ROOT/.target/build
REFERENCE=$ROOT/.target/reference
REPORT=$ROOT/out/y70/report
BASE=https://ci.android.com/builds/submitted/$BUILD_ID/kernel_aarch64/latest/raw
mkdir -p "$REFERENCE" "$BUILD" "$REPORT"

download() {
    local name=$1 algorithm=$2 expected=$3 checksum
    case "$algorithm" in sha256) checksum=sha256sum ;; md5) checksum=md5sum ;; *) return 1 ;; esac
    if [ -f "$REFERENCE/$name" ] && printf '%s  %s\n' "$expected" "$REFERENCE/$name" | "$checksum" -c - >/dev/null 2>&1; then
        echo "Using verified cache: $name"
        return
    fi
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 600 "$BASE/$name" -o "$REFERENCE/$name.download"
    printf '%s  %s\n' "$expected" "$REFERENCE/$name.download" | "$checksum" -c -
    mv "$REFERENCE/$name.download" "$REFERENCE/$name"
}

python3 - > "$ROOT/.target/downloads.tsv" <<'PY'
import json
data=json.load(open('scripts/y70-reference.json'))
assert data['build_id']==14987696
assert data['kernel_commit']=='b0a9599c6c01ec540e2252ca3a0e87b5b8c47c97'
for entry in data['artifacts']:
    print(entry['name']+'\t'+entry['algorithm']+'\t'+entry['digest'])
PY
while IFS=$'\t' read -r name algorithm digest; do
    download "$name" "$algorithm" "$digest"
done < "$ROOT/.target/downloads.tsv"

if [ ! -d "$SOURCE/.git" ]; then
    git init "$SOURCE"
    git -C "$SOURCE" remote add origin https://android.googlesource.com/kernel/common
fi
if ! git -C "$SOURCE" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null; then
    git -C "$SOURCE" fetch --depth=1 origin "$TARGET_SHA"
fi
git -C "$SOURCE" checkout --detach "$TARGET_SHA"
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$TARGET_SHA"
git -C "$SOURCE" diff --exit-code
grep -q '^[[:space:]]*check_exports(mod);' "$SOURCE/scripts/mod/modpost.c"
grep -q '^[[:space:]]*s->module = exp->module;' "$SOURCE/scripts/mod/modpost.c"

export ARCH=arm64 LLVM=1 LLVM_IAS=1
export LIBCLANG_PATH=${LIBCLANG_PATH:-/opt/ddk/clang/clang-r536225/lib}
packages=()
if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists libelf libdw; then
    packages+=(pkg-config libelf-dev libdw-dev)
fi
if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    packages+=(gcc-aarch64-linux-gnu)
fi
if [ ! -f /usr/aarch64-linux-gnu/include/stdio.h ]; then
    packages+=(libc6-dev-arm64-cross)
fi
if [ "${#packages[@]}" -gt 0 ]; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
fi
if ! command -v bindgen >/dev/null 2>&1; then
    # Exact clang-tools revision from manifest_14987696.xml.
    if [ ! -x "$ROOT/.target/bindgen" ]; then
        curl --fail --location --retry 3 --connect-timeout 20 --max-time 120 \
            'https://android.googlesource.com/platform/prebuilts/clang-tools/+/edb3c73c0398462492e7371fae68ce2db7afb6c7/linux-x86/bin/bindgen?format=TEXT' \
            -o "$ROOT/.target/bindgen.base64"
        base64 --decode "$ROOT/.target/bindgen.base64" > "$ROOT/.target/bindgen"
        chmod +x "$ROOT/.target/bindgen"
    fi
    # Kbuild assigns BINDGEN=bindgen, overriding an environment-only variable.
    export PATH="$ROOT/.target:$PATH"
fi
clang --version | head -1
rustc --version
"${BINDGEN:-bindgen}" --version
pahole --version

cp "$REFERENCE/kernel_aarch64_dot_config" "$BUILD/.config"
cp "$REFERENCE/abi_symbollist.raw" "$BUILD/abi_symbollist.raw"
python3 - "$SOURCE" "$BUILD" "$REPORT" <<'PY'
import ast,sys
from pathlib import Path
source,build,report=map(Path,sys.argv[1:])
tree=ast.parse((source/'modules.bzl').read_text())
lists={n.targets[0].id:ast.literal_eval(n.value) for n in tree.body
       if isinstance(n,ast.Assign) and isinstance(n.value,ast.List)}
keys=['_COMMON_GKI_MODULES_LIST','_ARM64_GKI_MODULES_LIST',
      '_KUNIT_FRAMEWORK_MODULES','_KUNIT_COMMON_MODULES_LIST','_KUNIT_CLK_MODULES_LIST']
modules=[p for key in keys for p in lists[key]]
protected=sorted(p for p in modules if p not in lists['_COMMON_UNPROTECTED_MODULES_LIST'])
# Match BUILD.bazel:gki_aarch64_protected_module_names exactly.
content='\n'.join(p.removesuffix('.ko') for p in protected)+'\n'
assert protected and 'droid_lkm' not in content
(build/'protected_module_names_list').write_text(content)
(report/'protected_module_names_list').write_text(content)
print('Generated exact target protected module list:',len(protected))
PY
make -C "$SOURCE" O="$BUILD" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    KERNELRELEASE="$TARGET_RELEASE" rustavailable
make -C "$SOURCE" O="$BUILD" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    KERNELRELEASE="$TARGET_RELEASE" -j"$(nproc)" olddefconfig modules_prepare
cp "$BUILD/.config" "$REPORT/target.config"
cp "$BUILD/include/generated/utsrelease.h" "$REPORT/utsrelease.h"
python3 scripts/verify-y70.py --check-config "$BUILD/.config" --reference "$REFERENCE" --output "$REPORT/config-verification.json"
grep -Fx '#define UTS_RELEASE "'"$TARGET_RELEASE"'"' "$BUILD/include/generated/utsrelease.h"
cp "$REFERENCE/kernel_aarch64_Module.symvers" "$BUILD/Module.symvers"
cp "$REFERENCE/System.map" "$BUILD/System.map"
cp "$REFERENCE/vmlinux" "$BUILD/vmlinux"
export KDIR=$BUILD
make VER=y70 DROID_LKM_TOY= KERNELRELEASE="$TARGET_RELEASE" -j"$(nproc)"
aarch64-linux-gnu-gcc -static -O2 -Wall -Wextra -Werror \
    -o "$ROOT/out/y70/droidspaces-check" "$ROOT/scripts/droidspaces-check.c" -lrt
cp "$BUILD/Module.symvers" "$REPORT/target.Module.symvers"
cp "$ROOT/out/y70/Module.symvers" "$REPORT/module.Module.symvers"
find out/y70 -maxdepth 1 -name '*.mod.c' -exec cp '{}' "$REPORT/" \;
git -C "$SOURCE" diff --exit-code
printf 'target_commit=%s\ntarget_release=%s\nbuild_id=%s\n' "$TARGET_SHA" "$TARGET_RELEASE" "$BUILD_ID" > "$REPORT/target-identity.txt"
