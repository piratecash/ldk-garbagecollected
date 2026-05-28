#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${LDK_ANDROID_BUILD_DIR:-$ROOT_DIR/.ldk-android-build}"
NDK_VERSION="r27c"
NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
NDK_SHA256="59c2f6dc96743b5daf5d1626684640b20a6bd2b1d85b13156b90333741bad5cc"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.84.1}"
PYTHON_STANDALONE_VERSION="${PYTHON_STANDALONE_VERSION:-3.11.9}"
PYTHON_STANDALONE_RELEASE="${PYTHON_STANDALONE_RELEASE:-20240726}"
PYTHON_STANDALONE_ARCHIVE="cpython-${PYTHON_STANDALONE_VERSION}+${PYTHON_STANDALONE_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
PYTHON_STANDALONE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_STANDALONE_RELEASE}/cpython-${PYTHON_STANDALONE_VERSION}%2B${PYTHON_STANDALONE_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"

cd "$ROOT_DIR"

export LDK_GARBAGECOLLECTED_GIT_OVERRIDE="${LDK_GARBAGECOLLECTED_GIT_OVERRIDE:-v0.2.0.0}"
if [ "${LDK_GARBAGECOLLECTED_GIT_OVERRIDE:0:1}" != "v" ]; then
	echo "Version tag should start with a v: $LDK_GARBAGECOLLECTED_GIT_OVERRIDE" >&2
	exit 1
fi

ensure_rust() {
	if ! command -v rustup >/dev/null 2>&1; then
		curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
		# shellcheck disable=SC1091
		. "$HOME/.cargo/env"
	fi

	rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
	rustup default "$RUST_TOOLCHAIN"
	export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN"
}

python_supports_fstrings() {
	local candidate="$1"
	"$candidate" - <<'PY' >/dev/null 2>&1
compile('f"{1}"', '<python-check>', 'exec')
PY
}

select_python() {
	local candidate

	if [ "${PYTHON:-}" != "" ] && command -v "$PYTHON" >/dev/null 2>&1 && python_supports_fstrings "$PYTHON"; then
		export PYTHON
		return 0
	fi

	for candidate in python3.12 python3.11 python3.10 python3.9 python3.8 python3.7 python3.6 python3; do
		if command -v "$candidate" >/dev/null 2>&1 && python_supports_fstrings "$candidate"; then
			export PYTHON="$candidate"
			return 0
		fi
	done

	return 1
}

ensure_python() {
	local python_dir="$BUILD_DIR/python-standalone"

	if select_python; then
		"$PYTHON" --version
		return
	fi

	if [ ! -x "$python_dir/bin/python3" ]; then
		if [ ! -f "$BUILD_DIR/$PYTHON_STANDALONE_ARCHIVE" ]; then
			curl -L "$PYTHON_STANDALONE_URL" -o "$BUILD_DIR/$PYTHON_STANDALONE_ARCHIVE"
		fi

		rm -rf "$python_dir"
		mkdir -p "$python_dir"
		tar xzf "$BUILD_DIR/$PYTHON_STANDALONE_ARCHIVE" -C "$python_dir" --strip-components=1
	fi

	export PYTHON="$python_dir/bin/python3"
	if ! python_supports_fstrings "$PYTHON"; then
		echo "Python 3.6+ is required for binding generation" >&2
		exit 1
	fi

	"$PYTHON" --version
}

install_cbindgen() {
	if command -v cbindgen >/dev/null 2>&1; then
		return
	fi

	if [ ! -d "$BUILD_DIR/cbindgen" ]; then
		git clone https://github.com/eqrion/cbindgen "$BUILD_DIR/cbindgen"
	fi

	git -C "$BUILD_DIR/cbindgen" fetch --tags
	git -C "$BUILD_DIR/cbindgen" checkout v0.20.0
	cargo update --manifest-path "$BUILD_DIR/cbindgen/Cargo.toml" -p indexmap --precise "1.6.2" --verbose
	cargo install --locked --path "$BUILD_DIR/cbindgen"
}

prepare_rust_sources() {
	if command -v rustup >/dev/null 2>&1; then
		rustup component add rust-src --toolchain "$RUST_TOOLCHAIN" || true
	fi

	local sysroot
	sysroot="$(rustc --print sysroot 2>/dev/null || true)"
	if [ "$sysroot" != "" ]; then
		mkdir -p "$sysroot/lib/rustlib/src/rust"
		touch "$sysroot/lib/rustlib/src/rust/Cargo.lock"
	fi

	if [ -d /usr/lib/rustlib/src/rust ]; then
		touch /usr/lib/rustlib/src/rust/Cargo.lock || true
	fi
}

checkout_sources() {
	if [ ! -d "$BUILD_DIR/rust-lightning" ]; then
		git clone https://github.com/lightningdevkit/rust-lightning "$BUILD_DIR/rust-lightning"
	fi
	git -C "$BUILD_DIR/rust-lightning" fetch origin
	git -C "$BUILD_DIR/rust-lightning" checkout origin/0.2-bindings
	cargo update --manifest-path "$BUILD_DIR/rust-lightning/Cargo.toml" -p syn --precise "2.0.106" --verbose
	cargo update --manifest-path "$BUILD_DIR/rust-lightning/Cargo.toml" -p quote --precise "1.0.41" --verbose

	if [ ! -d "$BUILD_DIR/ldk-c-bindings" ]; then
		git clone https://github.com/lightningdevkit/ldk-c-bindings "$BUILD_DIR/ldk-c-bindings"
	fi
	git -C "$BUILD_DIR/ldk-c-bindings" fetch origin
	git -C "$BUILD_DIR/ldk-c-bindings" checkout 0.2
	cargo update --manifest-path "$BUILD_DIR/ldk-c-bindings/lightning-c-bindings/Cargo.toml" -p syn --precise "2.0.106" --verbose
	cargo update --manifest-path "$BUILD_DIR/ldk-c-bindings/lightning-c-bindings/Cargo.toml" -p quote --precise "1.0.41" --verbose
	cargo update --manifest-path "$BUILD_DIR/ldk-c-bindings/c-bindings-gen/Cargo.toml" -p quote --precise "1.0.30" --verbose
	cargo update --manifest-path "$BUILD_DIR/ldk-c-bindings/c-bindings-gen/Cargo.toml" -p proc-macro2 --precise "1.0.65" --verbose
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

prepare_ndk() {
	if [ "${ANDROID_TOOLCHAIN:-}" != "" ] && [ -x "$ANDROID_TOOLCHAIN/bin/clang" ]; then
		return
	fi

	if [ "${ANDROID_NDK_HOME:-}" != "" ] && [ -x "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
		export ANDROID_TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
		return
	fi

	if [ ! -f "$BUILD_DIR/$NDK_ZIP" ]; then
		curl -L "https://dl.google.com/android/repository/$NDK_ZIP" -o "$BUILD_DIR/$NDK_ZIP"
	fi

	if [ "$(sha256_file "$BUILD_DIR/$NDK_ZIP")" != "$NDK_SHA256" ]; then
		echo "Bad NDK archive hash" >&2
		exit 1
	fi

	if [ ! -d "$BUILD_DIR/android-ndk-${NDK_VERSION}" ]; then
		unzip -q "$BUILD_DIR/$NDK_ZIP" -d "$BUILD_DIR"
	fi

	export ANDROID_TOOLCHAIN="$BUILD_DIR/android-ndk-${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64"
}

fetch_java_bins() {
	local release_page
	local android_page
	local snapshot_link

	release_page="https://git.bitcoin.ninja/index.cgi?p=ldk-java-bins;a=tree;f=${LDK_GARBAGECOLLECTED_GIT_OVERRIDE};hb=refs/heads/main"
	snapshot_link="$(curl "$release_page" | grep snapshot | grep -o 'href="[a-zA-Z0-9/?\.=;\-]*"' | sed 's/href="//' | tr -d '"' | grep snapshot)"
	curl -L -o "$BUILD_DIR/bins-snapshot.tgz" "https://git.bitcoin.ninja${snapshot_link}"

	android_page="https://git.bitcoin.ninja/index.cgi?p=ldk-java-bins;a=tree;f=android-artifacts;hb=refs/heads/main"
	snapshot_link="$(curl "$android_page" | grep snapshot | grep -o 'href="[a-zA-Z0-9/?\.=;\-]*"' | sed 's/href="//' | tr -d '"' | grep snapshot)"
	curl -L -o "$BUILD_DIR/android-snapshot.tgz" "https://git.bitcoin.ninja${snapshot_link}"

	rm -rf "$BUILD_DIR/ldk-java-bins"
	mkdir -p "$BUILD_DIR/ldk-java-bins/$LDK_GARBAGECOLLECTED_GIT_OVERRIDE"
	tar xzf "$BUILD_DIR/bins-snapshot.tgz" -C "$BUILD_DIR/ldk-java-bins/$LDK_GARBAGECOLLECTED_GIT_OVERRIDE" --strip-components=1

	mkdir -p "$BUILD_DIR/ldk-java-bins/android-artifacts"
	tar xzf "$BUILD_DIR/android-snapshot.tgz" -C "$BUILD_DIR/ldk-java-bins/android-artifacts" --strip-components=1
	cp "$BUILD_DIR/ldk-java-bins/$LDK_GARBAGECOLLECTED_GIT_OVERRIDE/ldk-java-classes.jar" "$ROOT_DIR/"
}

mkdir -p "$BUILD_DIR"
ensure_python
ensure_rust
install_cbindgen
prepare_rust_sources
checkout_sources
prepare_ndk
fetch_java_bins

export PATH="$PATH:$ANDROID_TOOLCHAIN/bin"
export ANDROID_JNI_LINKER_FLAGS="${ANDROID_JNI_LINKER_FLAGS:--Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384}"

./android-build.sh "$BUILD_DIR/rust-lightning" "$BUILD_DIR/ldk-c-bindings" java "$BUILD_DIR/ldk-java-bins/android-artifacts"
