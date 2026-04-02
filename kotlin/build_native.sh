#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RNNOISE_DIR="$PROJECT_ROOT/rnnoise"
JNI_DIR="$PROJECT_ROOT/jni"
OUTPUT_DIR="$SCRIPT_DIR/libs"

if [ -z "$ANDROID_NDK_ROOT" ]; then
    echo "Error: ANDROID_NDK_ROOT is not set."
    exit 1
fi

RUST_SYSROOT="$(rustc --print sysroot 2>/dev/null)"
HOST_TRIPLE="$(rustc -vV 2>/dev/null | awk '/^host:/ {print $2}')"
RUST_LLD_BIN="$RUST_SYSROOT/lib/rustlib/$HOST_TRIPLE/bin/rust-lld"
if [ -x "$RUST_LLD_BIN" ]; then
    LLD_DIR="$SCRIPT_DIR/.lld-bin"
    mkdir -p "$LLD_DIR"
    ln -sf "$RUST_LLD_BIN" "$LLD_DIR/ld.lld"
    RUST_LLD="$LLD_DIR/ld.lld"
    echo "Using Rust LLD for cross-language LTO: $RUST_LLD"
    echo "  version: $("$RUST_LLD" --version 2>/dev/null)"
else
    RUST_LLD=""
    echo "Warning: rust-lld not found, cross-language LTO disabled"
fi

USE_LITE=1

# ── Step 1: Build DeepFilterNet static libs ──────────────────────────
echo "============================"
echo "Step 1: Building DeepFilterNet..."
echo "============================"
bash "$SCRIPT_DIR/build_deepfilter.sh"

# ── Step 2: Prepare RNNoise sources (extract model + use lite) ────────
echo "============================"
echo "Step 2: Preparing RNNoise sources..."
echo "============================"

cd "$RNNOISE_DIR"

MODEL_HASH=$(cat model_version)
MODEL_TAR="rnnoise_data-${MODEL_HASH}.tar.gz"

if [ ! -f "src/rnnoise_data.c" ] || [ ! -f "src/rnnoise_data.h" ]; then
    if [ -f "$MODEL_TAR" ]; then
        echo "Extracting model weights from $MODEL_TAR"
        tar xf "$MODEL_TAR"
    else
        echo "Error: rnnoise_data.c not found and model archive $MODEL_TAR is missing."
        echo "Run rnnoise/download_model.sh first."
        exit 1
    fi
fi

if [ -f src/rnnoise_data_little.c ] && [ -f src/rnnoise_data_little.h ] && [ "$USE_LITE" = "1" ]; then
    echo "Using lite RNNoise model"
    cp src/rnnoise_data.h src/rnnoise_data_big.h.bak
    cp src/rnnoise_data.c src/rnnoise_data_big.c.bak
    cp src/rnnoise_data_little.h src/rnnoise_data.h
    cp src/rnnoise_data_little.c src/rnnoise_data.c
fi

# ── Step 3: Build unified .so with CMake + NDK ──────────────────────
echo "============================"
echo "Step 3: Building libaudio_pipeline.so..."
echo "============================"

ABIS=("arm64-v8a" "armeabi-v7a" "x86" "x86_64")

CMAKE_TOOLCHAIN="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake"

if [ ! -f "$CMAKE_TOOLCHAIN" ]; then
    echo "Error: NDK CMake toolchain not found at $CMAKE_TOOLCHAIN"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

for ABI in "${ABIS[@]}"; do
    echo "--- Building for $ABI ---"

    BUILD_DIR="$SCRIPT_DIR/build_cmake_$ABI"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    CMAKE_LTO_ARGS=""
    if [ -n "$RUST_LLD" ]; then
        CMAKE_LTO_ARGS="-DRUST_LLD=$RUST_LLD"
    fi

    cmake -S "$JNI_DIR" -B "$BUILD_DIR" \
        -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM=android-21 \
        -DCMAKE_BUILD_TYPE=Release \
        $CMAKE_LTO_ARGS

    cmake --build "$BUILD_DIR" --config Release -j "$(nproc 2>/dev/null || sysctl -n hw.ncpu)"

    mkdir -p "$OUTPUT_DIR/$ABI"
    cp "$BUILD_DIR/libaudio_pipeline.so" "$OUTPUT_DIR/$ABI/"

    STRIP_TOOL=""
    for candidate in \
        "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt"/*/bin/llvm-strip \
        "$(command -v llvm-strip 2>/dev/null)" \
        "$(command -v strip 2>/dev/null)"; do
        [ -x "$candidate" ] && STRIP_TOOL="$candidate" && break
    done

    if [ -n "$STRIP_TOOL" ]; then
        SO_FILE="$OUTPUT_DIR/$ABI/libaudio_pipeline.so"
        BEFORE=$(wc -c < "$SO_FILE" | tr -d ' ')
        "$STRIP_TOOL" --strip-unneeded "$SO_FILE"
        AFTER=$(wc -c < "$SO_FILE" | tr -d ' ')
        echo "Stripped $ABI: $(( BEFORE / 1048576 ))MB -> $(( AFTER / 1048576 ))MB ($STRIP_TOOL)"
    else
        echo "Warning: no strip tool found, skipping strip"
    fi

    rm -rf "$BUILD_DIR"

    echo "--- Done: $ABI ---"
done

# ── Step 4: Clean up RNNoise generated/extracted files ───────────────
cd "$RNNOISE_DIR"
rm -f src/rnnoise_data_big.h.bak src/rnnoise_data_big.c.bak
rm -f src/rnnoise_data.c src/rnnoise_data.h
rm -f src/rnnoise_data_little.c src/rnnoise_data_little.h
rm -f models/*.pth
echo "Cleaned up extracted RNNoise files"

rm -rf "$SCRIPT_DIR/.lld-bin"

echo "============================"
echo "Build complete! Libraries at $OUTPUT_DIR"
echo "============================"
ls -la "$OUTPUT_DIR"/*/libaudio_pipeline.so
