#! /usr/bin/env bash

set -e
LLVM_DIR="$(realpath "$1")"
BUILD_DIR="$2"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

readonly COMMON_FLAGS="-Wno-unsafe-buffer-usage -fno-omit-frame-pointer"
readonly LINKER="mold"

cmake "$LLVM_DIR"/llvm -GNinja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DLLVM_ENABLE_PROJECTS='mlir;clang;clang-tools-extra;flang;lld;lldb' \
      -DCLANG_ENABLE_CIR=1 \
      -DLLVM_ENABLE_ASSERTIONS=1 \
      -DMLIR_INCLUDE_INTEGRATION_TESTS=1 \
      -DLLVM_INCLUDE_SPIRV_TOOLS_TESTS=1 \
      -DMLIR_ENABLE_VULKAN_RUNNER=1 \
      -DMLIR_ENABLE_SPIRV_CPU_RUNNER=1 \
      -DLLVM_BUILD_EXAMPLES=1 \
      -DMLIR_ENABLE_BINDINGS_PYTHON=1 \
      -DPython3_EXECUTABLE="$(which python3)" \
      -DLLVM_TARGETS_TO_BUILD='X86;AMDGPU' \
      -DLLVM_INSTALL_UTILS=1 \
      -DLLVM_USE_SPLIT_DWARF=1 \
      -DLLVM_USE_LINKER="$LINKER" \
      -DCMAKE_C_FLAGS="$COMMON_FLAGS" \
      -DCMAKE_CXX_FLAGS="$COMMON_FLAGS" \
      -DCMAKE_CXX_COMPILER=clang++-20 -DCMAKE_C_COMPILER=clang-20 \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=1 \
      -DCMAKE_INSTALL_PREFIX=run
