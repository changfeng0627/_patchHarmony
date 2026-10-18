#!/system/bin/sh
# Y70 / XT2611-1: manual loader for the verified main module only.
# Shared storage is normally noexec: run this file with sh, not ./script.
PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH

EXPECTED_KERNEL='6.12.58-android16-6-gb0a9599c6c01-ab14987696-4k'
EXPECTED_MODEL='XT2611-1'
EXPECTED_SHA256='7ccdc3283c8532f5f28b7422f87db6030de53a79f4682b7d3560ea9528157f74'
CHECK_ONLY=0
ROOT_RETRY=0
STAGE=

fail() { printf '[错误] %s\n' "$*" >&2; exit 1; }
# Resolve before su, which may change the working directory. Quote the path
# again for su's command shell, including spaces, apostrophes and dollar signs.
SELF=$(readlink -f -- "$0") || fail '无法确定脚本所在位置。'
[ -n "$SELF" ] && [ -f "$SELF" ] || fail '请通过脚本文件运行，不能从标准输入运行。'
SCRIPT_DIR=${SELF%/*}
MODULE=$SCRIPT_DIR/droid_lkm.ko
shell_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}
cleanup() {
    if [ -n "$STAGE" ]; then
        rm -f "$STAGE/droid_lkm.ko"
        rmdir "$STAGE"
    fi
}
verify_hash() {
    digest=$(sha256sum "$1") || fail "无法校验文件：$1"
    actual=${digest%% *}
    [ "$actual" = "$EXPECTED_SHA256" ] || fail "模块 SHA256 不匹配，已停止。请恢复本次已验收的模块。"
}
verify_parameters() {
    [ "$(cat /sys/module/droid_lkm/parameters/gate)" = Y ] &&
    [ "$(cat /sys/module/droid_lkm/parameters/write_path)" = 0 ] &&
    [ "$(cat /sys/module/droid_lkm/parameters/degrade)" = N ] &&
    [ "$(cat /sys/module/droid_lkm/parameters/inline_hook)" = Y ] ||
        fail '已加载模块参数与验收配置不同；未更改参数、卸载或重复加载。'
}

for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --root-retry) ROOT_RETRY=1 ;;
        *) printf '用法：sh %s [--check]\n' "$SELF" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" != 0 ]; then
    [ "$ROOT_RETRY" = 0 ] || fail '未获得 Root 权限，请在 FolkPatch 中授权当前终端。'
    command -v su >/dev/null 2>&1 || fail '未找到 su，请在已授权的 ZeroTermux/Root 终端运行。'
    printf '[提示] 正在申请 Root 权限；如有授权提示，请允许当前终端。\n'
    check_arg=
    [ "$CHECK_ONLY" = 0 ] || check_arg=' --check'
    quoted_self=$(shell_quote "$SELF") || fail '无法处理脚本路径。'
    exec su -c "/system/bin/sh $quoted_self --root-retry$check_arg"
    fail '无法启动 Root shell。'
fi

[ "$(getprop ro.product.model)" = "$EXPECTED_MODEL" ] || fail '设备型号不匹配。'
actual_kernel=$(uname -r) || fail '无法读取内核版本。'
[ "$actual_kernel" = "$EXPECTED_KERNEL" ] || fail "内核版本不匹配：$actual_kernel。系统更新后请重新核对模块。"
[ "$(uname -m)" = aarch64 ] || fail '需要 aarch64 内核。'
[ -f "$MODULE" ] && [ -r "$MODULE" ] || fail "找不到模块：$MODULE"
verify_hash "$MODULE"
printf '[通过] 设备、完整内核版本及模块 SHA256 均匹配。\n'

if [ "$CHECK_ONLY" = 0 ] && [ -d /sys/module/droid_lkm ]; then
    grep -q '^droid_lkm .* Live ' /proc/modules || fail '模块状态不是 Live；未重复加载。'
    verify_parameters
    printf '[完成] 主模块已经加载，参数正确，无需重复加载。\n'
    printf '[提示] 本脚本为手动加载；手机重启后需重新运行。\n'
    exit 0
fi

# Load a private, reverified copy so the kernel reads a stable root-owned file.
umask 077
STAGE=$(mktemp -d /data/local/tmp/droid-lkm-y70.XXXXXX) || fail '无法创建私有临时目录。'
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
cp "$MODULE" "$STAGE/droid_lkm.ko" || fail '无法准备模块文件。'
chmod 600 "$STAGE/droid_lkm.ko" || fail '无法设置临时模块权限。'
verify_hash "$STAGE/droid_lkm.ko"

if [ "$CHECK_ONLY" = 1 ]; then
    printf '[完成] 检查和私有副本校验通过；--check 不加载模块。\n'
    exit 0
fi

# A concurrent invocation may have loaded it while the copy was prepared.
if [ -d /sys/module/droid_lkm ]; then
    grep -q '^droid_lkm .* Live ' /proc/modules || fail '模块状态不是 Live；未重复加载。'
    verify_parameters
    printf '[完成] 主模块已由另一进程加载，无需重复加载。\n'
    exit 0
fi

printf '[加载] 正在加载主模块，参数 gate=1。\n'
/system/bin/insmod "$STAGE/droid_lkm.ko" gate=1
result=$?
if [ "$result" != 0 ]; then
    printf '[错误] insmod 失败，退出码 %s；未强制加载或更改安全策略。\n' "$result" >&2
    exit "$result"
fi
grep -q '^droid_lkm .* Live ' /proc/modules || fail 'insmod 返回成功，但未找到 Live 模块。'
verify_parameters
printf '[完成] 主模块已加载：gate=Y，write_path=0，degrade=N，inline_hook=Y。\n'
printf '[提示] 现在可以启动 Droidspaces。手机重启后需重新运行本脚本。\n'
