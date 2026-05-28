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

if [ "$3" = "java" -a [ ! -d "$4" -o ! -f "$4/AndroidManifest.xml" ] ]; then
	echo "Please set fourth argument to the path to ldk-java-bins/android-artifacts" > /dev/stderr
	exit 1
fi

set -e
set -x

LDK_C_BINDINGS="$(realpath $2)"
RUST_LIGHTNING="$(realpath $1)"
pushd "$2"
export LDK_C_BINDINGS_EXTRA_TARGETS="x86_64-linux-android armv7-linux-androideabi aarch64-linux-android"
export LDK_C_BINDINGS_EXTRA_TARGET_CCS="x86_64-linux-android24-clang armv7a-linux-androideabi24-clang aarch64-linux-android24-clang"
./genbindings.sh "$RUST_LIGHTNING" true
popd

export PATH=$PATH:$ANDROID_TOOLCHAIN/bin
export SYSROOT=$ANDROID_TOOLCHAIN/sysroot/
ANDROID_JNI_LINKER_FLAGS="${ANDROID_JNI_LINKER_FLAGS:--Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384}"

# Remove any non-Android libraries installed locally
rm -fr src/main/resources

EXTRA_TARGETS=( $LDK_C_BINDINGS_EXTRA_TARGETS )
EXTRA_TARGET_CCS=( $LDK_C_BINDINGS_EXTRA_TARGET_CCS )
TARGET_CPUS=( "sandybridge" "generic" "generic" )
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
mkdir -p ./aar/jni/{armeabi-v7a,arm64-v8a,x86_64}

cp liblightningjni_release_aarch64-linux-android.so ./aar/jni/arm64-v8a/liblightningjni.so
cp liblightningjni_release_armv7-linux-androideabi.so ./aar/jni/armeabi-v7a/liblightningjni.so
cp liblightningjni_release_x86_64-linux-android.so ./aar/jni/x86_64/liblightningjni.so
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
