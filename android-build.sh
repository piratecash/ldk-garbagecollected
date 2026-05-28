#!/bin/bash
if [ ! -x "$ANDROID_TOOLCHAIN/bin/clang" ]; then
	echo "Please set ANDROID_TOOLCHAIN to the path to NDK" > /dev/stderr
	exit 1
fi

if [ "$1" = "" -o ! -f "$1/lightning/Cargo.toml" ]; then
	echo "Please set first argument to the path to rust-lightning" > /dev/stderr
	exit 1
fi

if [ "$2" = "" -o ! -d "$2/lightning-c-bindings" ]; then
	echo "Please set second argument to the path to ldk-c-bindings" > /dev/stderr
	exit 1
fi

if [ "$3" != "java" -a "$3" != "c_sharp" ]; then
	echo "Please set third argument to java or c_sharp" > /dev/stderr
	exit 1
fi

if [ "$3" = "java" ] && { [ "$4" = "" ] || [ ! -d "$4" ] || [ ! -f "$4/AndroidManifest.xml" ]; }; then
	echo "Please set fourth argument to the path to ldk-java-bins/android-artifacts" > /dev/stderr
	exit 1
fi

set -e
set -x

LDK_C_BINDINGS="$(realpath $2)"
RUST_LIGHTNING="$(realpath $1)"
LDK_ANDROID_TARGETS="${LDK_ANDROID_TARGETS:-aarch64-linux-android}"
LDK_ANDROID_TARGET_CCS="${LDK_ANDROID_TARGET_CCS:-aarch64-linux-android24-clang}"
LDK_ANDROID_TARGET_CPUS="${LDK_ANDROID_TARGET_CPUS:-generic}"

android_abi_for_target() {
	case "$1" in
		"aarch64-linux-android")
			echo "arm64-v8a"
			;;
		"armv7-linux-androideabi")
			echo "armeabi-v7a"
			;;
		"x86_64-linux-android")
			echo "x86_64"
			;;
		*)
			echo "Unsupported Android target: $1" > /dev/stderr
			exit 1
	esac
}

pushd "$2"
export CC="${HOST_CC:-clang}"
export LDK_C_BINDINGS_EXTRA_TARGETS="$LDK_ANDROID_TARGETS"
export LDK_C_BINDINGS_EXTRA_TARGET_CCS="$LDK_ANDROID_TARGET_CCS"
./genbindings.sh "$RUST_LIGHTNING" true skip-tests
popd

export PATH=$PATH:$ANDROID_TOOLCHAIN/bin
export SYSROOT=$ANDROID_TOOLCHAIN/sysroot/
ANDROID_JNI_LINKER_FLAGS="${ANDROID_JNI_LINKER_FLAGS:--Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384}"

# Remove any non-Android libraries installed locally
rm -fr src/main/resources

EXTRA_TARGETS=( $LDK_C_BINDINGS_EXTRA_TARGETS )
EXTRA_TARGET_CCS=( $LDK_C_BINDINGS_EXTRA_TARGET_CCS )
TARGET_CPUS=( $LDK_ANDROID_TARGET_CPUS )
if [ "${#EXTRA_TARGETS[@]}" -ne "${#EXTRA_TARGET_CCS[@]}" -o "${#EXTRA_TARGETS[@]}" -ne "${#TARGET_CPUS[@]}" ]; then
	echo "Android target, compiler, and CPU lists must have the same length" > /dev/stderr
	exit 1
fi

for IDX in ${!EXTRA_TARGETS[@]}; do
	export CC="${EXTRA_TARGET_CCS[$IDX]}"
	export LDK_TARGET="${EXTRA_TARGETS[$IDX]}"
	export LDK_TARGET_CPU="${TARGET_CPUS[$IDX]}"
	./genbindings.sh "$LDK_C_BINDINGS" "$3" false true "-lm -llog -I$SYSROOT/usr/include/ $ANDROID_JNI_LINKER_FLAGS"
	if [ "$3" = "java" ]; then
		llvm-strip liblightningjni_release_${LDK_TARGET}.so
	else
		llvm-strip libldkcsharp_release_${LDK_TARGET}.so
	fi
done

[ "$3" != "java" ] && exit 0

export LC_ALL=C

echo "Need local deterministic ldk-java-classes.jar"
ls ldk-java-classes.jar

rm -rf aar
mkdir aar
cp -r "$4/"* ./aar/

mkdir -p ./aar/jni
for TARGET in ${EXTRA_TARGETS[@]}; do
	ABI_DIR="$(android_abi_for_target "$TARGET")"
	mkdir -p "./aar/jni/$ABI_DIR"
	cp "liblightningjni_release_${TARGET}.so" "./aar/jni/$ABI_DIR/liblightningjni.so"
done
cp ldk-java-classes.jar ./aar/classes.jar

rm -f LDK-release.aar
cd ./aar
find . | sort > ../sources-zip-files.txt
touch -d "2021-01-01 00:00 UTC" $(cat ../sources-zip-files.txt)
cat ../sources-zip-files.txt | zip -X@ ../LDK-release.aar
cd ..
rm -r aar

if [ -x ./scripts/check-android-aar-16k.sh ]; then
	./scripts/check-android-aar-16k.sh LDK-release.aar
fi
