#!/usr/bin/env bash
set -euo pipefail

AAR_PATH="${1:-LDK-release.aar}"
MIN_ALIGN=$((16 * 1024))

if [ ! -f "$AAR_PATH" ]; then
	echo "AAR not found: $AAR_PATH" >&2
	exit 1
fi

find_readelf() {
	if [ "${LLVM_READELF:-}" != "" ] && [ -x "$LLVM_READELF" ]; then
		echo "$LLVM_READELF"
		return
	fi

	if command -v llvm-readelf >/dev/null 2>&1; then
		command -v llvm-readelf
		return
	fi

	if [ "${ANDROID_TOOLCHAIN:-}" != "" ] && [ -x "$ANDROID_TOOLCHAIN/bin/llvm-readelf" ]; then
		echo "$ANDROID_TOOLCHAIN/bin/llvm-readelf"
		return
	fi

	for sdk_root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk"; do
		if [ "$sdk_root" = "" ] || [ ! -d "$sdk_root/ndk" ]; then
			continue
		fi

		local readelf
		readelf="$(find "$sdk_root/ndk" -path '*/bin/llvm-readelf' -type f | sort | tail -n 1)"
		if [ "$readelf" != "" ]; then
			echo "$readelf"
			return
		fi
	done

	echo "llvm-readelf not found; set LLVM_READELF or ANDROID_TOOLCHAIN" >&2
	exit 1
}

READELF="$(find_readelf)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

unzip -q "$AAR_PATH" 'jni/*/*.so' -d "$TMP_DIR"

shopt -s nullglob
libs=("$TMP_DIR"/jni/*/*.so)
if [ "${#libs[@]}" -eq 0 ]; then
	echo "No native libraries found in $AAR_PATH" >&2
	exit 1
fi

for lib in "${libs[@]}"; do
	mapfile -t aligns < <("$READELF" -l "$lib" | awk '$1 == "LOAD" { print $NF }')
	if [ "${#aligns[@]}" -eq 0 ]; then
		echo "No LOAD segments found in $lib" >&2
		exit 1
	fi

	for align in "${aligns[@]}"; do
		if (( align < MIN_ALIGN )); then
			echo "UNALIGNED $lib LOAD align $align, expected at least 0x4000" >&2
			exit 1
		fi
	done

	echo "ALIGNED ${lib#$TMP_DIR/}"
done
