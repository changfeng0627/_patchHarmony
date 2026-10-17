#!/bin/sh
# deploy deps through the LKM-SDK at the pinned rev
# .sdk-version pins the SDK, cloned once into .sdk/ (gitignored)
# a rev that is not a commit id falls back to the SDK default branch
set -e

cd "$(dirname "$0")/.."

SDKREV=$(cat .sdk-version)

if [ ! -d .sdk/.git ]; then
	rm -rf .sdk
	git clone git@github.com:Dere3046/KMSDK.git .sdk
fi

case $SDKREV in
[0-9a-f]*)
	git -C .sdk fetch origin 2>/dev/null || true
	git -C .sdk checkout "$SDKREV"
	;;
*)
	# anything but a commit id follows the default branch
	git -C .sdk fetch origin
	git -C .sdk checkout -q FETCH_HEAD
	;;
esac

# A rewritten upstream history can leave a pinned commit outside every branch.
# The SDK only clones branch history, so fetch full SHA pins explicitly first.
while read -r name rev; do
	case "$rev" in
	''|*[!0-9a-f]*) continue ;;
	esac
	[ "${#rev}" -eq 40 ] || continue
	url=$(awk -v n="$name" '$1==n {print $2; exit}' .sdk/libs.lst)
	[ -n "$url" ] || { echo "unknown lib in registry: $name"; exit 1; }
	[ "$url" != builtin ] || continue
	dir="deps/$name"
	if [ ! -d "$dir/.git" ]; then
		git init "$dir"
		git -C "$dir" remote add origin "$url"
	fi
	if ! git -C "$dir" cat-file -e "$rev^{commit}" 2>/dev/null; then
		git -C "$dir" fetch --depth=1 origin "$rev"
	fi
	git -C "$dir" checkout --detach "$rev"
	meta="$dir/deps.mk"
	[ -f "$meta" ] || { echo "lib $name has no deps.mk"; exit 1; }
	libid=$(sed -n 's/^DEPS_LIB_NAME := \(.*\)$/\1/p' "$meta")
	[ "$libid" = "$name" ] || { echo "id mismatch: declared $name vs $libid"; exit 1; }
done < deps.lst

exec .sdk/scripts/sdk install
