#!/usr/bin/env bash
# =============================================================================
# build-easytier-so.sh
#
# 由固定 tag 的 EasyTier 源码构建 Android 原生库（arm64-v8a）：
#   libeasytier_ffi.so          EasyTier core（no_tun + socks5）
#   libeasytier_android_jni.so  com.easytier.jni.EasyTierJNI 的 JNI 实现
#
# 产物回填 app/src/main/jniLibs/arm64-v8a/，并校验 LOAD 段 16KB 对齐。
#
# 用法：
#   scripts/build-easytier-so.sh
#   EASYTIER_VERSION=v2.6.4 WORKDIR=/tmp/peerrdp-easytier-build scripts/build-easytier-so.sh
#
# 前置条件：
#   - Rust（rustup）+ aarch64-linux-android target
#   - cargo-ndk（cargo install cargo-ndk 或使用发行包）
#   - Android NDK r28+（默认取 $ANDROID_HOME/ndk 下最高版本，可用 ANDROID_NDK_HOME 覆盖）
#
# 说明：源码与构建目录默认放 /tmp，不写入仓库（deps/ 不入库，共享挂载盘编译也慢）。
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EASYTIER_VERSION="${EASYTIER_VERSION:-v2.6.4}"
WORKDIR="${WORKDIR:-/tmp/peerrdp-easytier-build}"
SRC="$WORKDIR/EasyTier-$EASYTIER_VERSION"
GIT_URL="${EASYTIER_GIT_URL:-https://github.com/EasyTier/EasyTier.git}"
OUT_DIR="$REPO_ROOT/app/src/main/jniLibs/arm64-v8a"
RUST_TARGET="aarch64-linux-android"
ANDROID_ABI="arm64-v8a"
PLATFORM="${ANDROID_API:-29}"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 环境
export PATH="$HOME/.cargo/bin:$PATH"
# 仓库内 rust-toolchain.toml 固定了具体版本；构建机只需稳定的新版 stable
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"

command -v cargo >/dev/null 2>&1 || die "未找到 cargo，请先安装 Rust（https://rustup.rs）"
command -v rustup >/dev/null 2>&1 || die "未找到 rustup"
cargo ndk --version >/dev/null 2>&1 \
  || die "未找到 cargo-ndk，请执行 cargo install cargo-ndk"
# EasyTier 的 RPC 代码生成需要 protoc
command -v protoc >/dev/null 2>&1 || [[ -n "${PROTOC:-}" && -x "${PROTOC:-}" ]] \
  || die "未找到 protoc：请安装 protobuf-compiler，或用 PROTOC=/path/to/protoc 指定"

rustup target list --installed | grep -qx "$RUST_TARGET" \
  || rustup target add "$RUST_TARGET"

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  SDK="${ANDROID_HOME:-/opt/android-sdk}"
  # 取 ndk 目录下版本号最大的一个
  ANDROID_NDK_HOME="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
[[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]] || die "找不到 Android NDK，请设置 ANDROID_NDK_HOME"
export ANDROID_NDK_HOME

READELF="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
STRIP="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
[[ -x "$READELF" && -x "$STRIP" ]] || die "NDK 缺少 llvm-readelf/llvm-strip：$ANDROID_NDK_HOME"

# kcp-sys 通过 bindgen 生成绑定，需要 libclang；NDK 自带的即可
export LIBCLANG_PATH="${LIBCLANG_PATH:-$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib}"

echo "    VERSION      = $EASYTIER_VERSION"
echo "    NDK          = $ANDROID_NDK_HOME"
echo "    SRC          = $SRC"
echo "    OUTPUT       = $OUT_DIR"

# ---------------------------------------------------------------- 源码
if [[ ! -d "$SRC/.git" ]]; then
  log "克隆 EasyTier $EASYTIER_VERSION"
  mkdir -p "$WORKDIR"
  git clone --depth 1 --branch "$EASYTIER_VERSION" "$GIT_URL" "$SRC"
else
  log "复用已有源码：$SRC"
fi

# ---------------------------------------------------------------- 构建
# 16KB 页对齐（Android 15+）；Rust 默认按 4KB 链接
export RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"

log "构建 libeasytier_ffi.so（$ANDROID_ABI）"
(cd "$SRC/easytier-contrib/easytier-ffi" && \
  cargo ndk -t "$ANDROID_ABI" --platform "$PLATFORM" build --release)

log "构建 libeasytier_android_jni.so（$ANDROID_ABI）"
# JNI 库通过 extern C 调用 ffi 的符号，显式链接以便生成 DT_NEEDED，
# 运行时由 Android 动态链接器从 APK 的 lib 目录加载 libeasytier_ffi.so。
JNI_RUSTFLAGS="$RUSTFLAGS -C link-arg=-L$SRC/target/$RUST_TARGET/release -C link-arg=-leasytier_ffi"
(cd "$SRC/easytier-contrib/easytier-android-jni" && \
  RUSTFLAGS="$JNI_RUSTFLAGS" cargo ndk -t "$ANDROID_ABI" --platform "$PLATFORM" build --release)

# ---------------------------------------------------------------- 回填
log "回填 .so 到 $OUT_DIR"
mkdir -p "$OUT_DIR"
# 共享挂载盘（CIFS/vboxsf）不支持 llvm-strip 的临时文件+rename，
# 先在本地临时目录 strip，再复制进仓库。
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
for so in libeasytier_ffi.so libeasytier_android_jni.so; do
  src="$SRC/target/$RUST_TARGET/release/$so"
  [[ -f "$src" ]] || die "构建产物缺失：$src"
  # 去掉调试符号（上游 release profile 未必开启 strip）
  cp "$src" "$STAGE/$so"
  "$STRIP" --strip-unneeded "$STAGE/$so"
  cp "$STAGE/$so" "$OUT_DIR/$so"
done

# ---------------------------------------------------------------- 校验
log "校验 16KB 页对齐（LOAD Align >= 0x4000）"
for so in libeasytier_ffi.so libeasytier_android_jni.so; do
  f="$OUT_DIR/$so"
  echo "-- $so"
  "$READELF" -lW "$f" | awk '$1 == "LOAD" { print }'
  # mawk 不支持 strtonum，这里用可移植的十六进制转换
  bad="$("$READELF" -lW "$f" | awk '
    function hex2dec(h,   i, c, n) {
      sub(/^0x/, "", h); n = 0
      for (i = 1; i <= length(h); i++) {
        c = index("0123456789abcdef", tolower(substr(h, i, 1))) - 1
        n = n * 16 + c
      }
      return n
    }
    $1 == "LOAD" && hex2dec($NF) < 16384 { print }
  ')"
  [[ -z "$bad" ]] || die "$so 存在未按 16KB 对齐的 LOAD 段"
  "$READELF" -dW "$f" | grep -q 'SONAME' || true
done

log "校验 JNI 库导出与依赖"
"$READELF" --dyn-syms -W "$OUT_DIR/libeasytier_android_jni.so" \
  | grep -q 'Java_com_easytier_jni_EasyTierJNI_runNetworkInstance' \
  || die "libeasytier_android_jni.so 缺少 EasyTierJNI 导出"
if ! "$READELF" -dW "$OUT_DIR/libeasytier_android_jni.so" | grep -q 'libeasytier_ffi.so'; then
  echo "注意：libeasytier_android_jni.so 未记录 libeasytier_ffi.so 的 DT_NEEDED（将依赖运行时加载顺序）"
fi

ls -lh "$OUT_DIR"/libeasytier_*.so
log "完成"
