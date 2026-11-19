#!/usr/bin/env bash
# =============================================================================
# build-freerdpcore-aar.sh
#
# 产出 app/libs/freeRDPCore-release.aar —— 即设计文档 §7「方案 A」的①段：
# 用上游 FreeRDP 自带的 Studio 工程，把 freeRDPCore 库模块预编译成 AAR。
#
# 流程：
#   1) 把仓库同步到 /tmp 工作区（共享挂载盘（CIFS/vboxsf）不支持符号链接，不能就地构建）
#   2) 缺少上游源码或依赖镜像时，按版本自动下载
#   3) 在上游 Studio 工程上打齐 11 处必要补丁（见下方 PATCH 说明）
#   4) ./gradlew :freeRDPCore:assembleRelease
#   5) AAR 回填到 <repo>/app/libs/ 并校验内容
#
# 用法：
#   scripts/build-freerdpcore-aar.sh                    # 全流程
#   WORKDIR=/tmp/other scripts/build-freerdpcore-aar.sh # 指定工作区
#   CLEAN=1 scripts/build-freerdpcore-aar.sh            # 先清掉工作区里的增量产物
#   SKIP_BUILD=1 scripts/build-freerdpcore-aar.sh       # 只同步+打补丁，不编译
#   FREERDP_VERSION=3.32.2 OPENSSL_VERSION=4.0.1 \
#     scripts/build-freerdpcore-aar.sh                  # 指定引擎/加密库版本
#
# 前置条件：
#   - deps/freerdp-$FREERDP_VERSION（上游源码；缺失时自动下载）
#   - deps/mirror/*.tar.gz（OpenSSL/cJSON/uriparser；缺失时自动下载）
#   - ANDROID_HOME（默认 /opt/android-sdk）：platform 37.0 / build-tools 37.0.0 /
#     NDK 29.0.13113456 / cmake 4.1.2
#   - JDK 21（默认 /usr/lib/jvm/java-21-openjdk-amd64）
#   - 宿主依赖：ninja / make / perl / unzip / rsync / python3 / curl / tar
#
# 说明：上游 Studio 工程要求 Gradle 9.6.1 + AGP 9.2.1；
#       应用侧（仓库根工程）同为 Gradle 9.6.1 + AGP 9.2.1，两者独立构建、互不干扰。
#
# PATCH 一览（均作用于工作区副本，不改动 deps 下的引擎源码目录）：
#   1. gradle-wrapper.properties → Gradle 9.6.1（腾讯镜像；AGP 9.2.1 的最低要求）
#   2. settings.gradle           → 只 include ':freeRDPCore'（去掉示例 App :aFreeRDP）
#   3. build.gradle（根）         → 删除 com.gladed.androidgitversion 插件（deps 无 .git/tag，必然失败）
#   4. freeRDPCore/build.gradle  → 注入 namespace（上游未声明，AGP 7.3+ 必需）
#   5. release.properties        → 覆盖上游默认值（只出 arm64-v8a、精简原生开关等）
#   6. proguard-rules.txt        → 补建（release buildType 引用了这个上游缺失的文件）
#   7. gradle.properties         → 收紧 JVM 堆与并行度（构建机内存有限）
#   8. *.cmake                   → 本地 mirror 归一化（CMake 4.x 不允许本地路径出现在 URL 列表中）
#   9. cmake/DepVersions.cmake   → 按环境变量与镜像实际 sha256 锁定依赖版本
#  10. ClipboardImageProvider   → authority 改为 com.peerrdp.freerdpcore.clipboard（上游硬编码
#      com.freerdp.freerdpcore.clipboard，任何两个内嵌 freeRDPCore 的应用共存即报
#      INSTALL_FAILED_CONFLICTING_PROVIDER(-13)；调用方 ClipboardManagerProxy 引用
#      AUTHORITY/CONTENT_URI 常量，自动跟随，无需修改）
#  11. SessionView / SessionInputManager → 客户端输入法文本输入（上游 inputType=TYPE_NULL
#      且 commitText 被丢弃，只能靠服务器输入法）。改为 TYPE_CLASS_TEXT，自定义
#      InputConnection 把提交的文本逐 UTF-16 单元转成 RDP Unicode 按键事件，退格/删除转为
#      VK_BACK/VK_DELETE，IME 回车的 key event 走原有物理键盘通道
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-/tmp/peerrdp-build}"

# 引擎与原生依赖版本：升级时改默认值或在命令行用同名环境变量覆盖
FREERDP_VERSION="${FREERDP_VERSION:-3.33.1}"
OPENSSL_VERSION="${OPENSSL_VERSION:-4.0.3}"
CJSON_VERSION="${CJSON_VERSION:-1.7.19}"
URIPARSER_VERSION="${URIPARSER_VERSION:-1.0.3}"

SRC_DEPS="$REPO_ROOT/deps"
MIRROR="$SRC_DEPS/mirror"
FREERDP_SRC="$SRC_DEPS/freerdp-$FREERDP_VERSION"
STUDIO_REL="deps/freerdp-$FREERDP_VERSION/client/Android/Studio"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 按顺序尝试多个 URL 下载到指定路径，全部失败则返回非零
fetch_file() {
  local dest="$1"; shift
  local tmp="$dest.part"
  mkdir -p "$(dirname "$dest")"
  for url in "$@"; do
    printf '    下载 %s\n' "$url"
    if curl -fL --retry 3 --connect-timeout 15 --max-time 900 -o "$tmp" "$url"; then
      mv "$tmp" "$dest"
      return 0
    fi
    rm -f "$tmp"
  done
  return 1
}

# ---------------------------------------------------------------- 环境
export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
if [[ -z "${JAVA_HOME:-}" ]]; then
  for j in /usr/lib/jvm/java-21-openjdk-amd64 /usr/lib/jvm/java-17-openjdk-amd64; do
    if [[ -x "$j/bin/java" ]]; then export JAVA_HOME="$j"; break; fi
  done
fi
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmake/4.1.2/bin:$PATH"

# ---------------------------------------------------------------- 前置检查
log "检查前置条件"
echo "    FreeRDP      = $FREERDP_VERSION"
echo "    OpenSSL      = $OPENSSL_VERSION"
echo "    cJSON        = $CJSON_VERSION"
echo "    uriparser    = $URIPARSER_VERSION"

# 先做静态前置检查，避免工具链缺失时白下载上百 MB 源码
[[ -f "$FREERDP_SRC/cmake/DepVersions.cmake" ]] \
  || die "缺少 $FREERDP_SRC/cmake/DepVersions.cmake（上游依赖版本定义），请核对 FreeRDP $FREERDP_VERSION 的工程结构"
[[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]] || die "找不到 JDK，请设置 JAVA_HOME"
[[ -d "$ANDROID_HOME" ]] || die "找不到 Android SDK：$ANDROID_HOME"
[[ -x "$ANDROID_HOME/cmake/4.1.2/bin/cmake" ]] || die "缺少 NDK CMake：$ANDROID_HOME/cmake/4.1.2"
for t in ninja perl unzip rsync python3 curl tar sha256sum; do
  command -v "$t" >/dev/null 2>&1 || die "缺少宿主工具：$t"
done

# 上游源码：缺失时按版本自动下载，并重命名为反查路径约定的 deps/freerdp-$FREERDP_VERSION
if [[ ! -d "$FREERDP_SRC/client/Android/Studio" ]]; then
  log "本地缺少 FreeRDP $FREERDP_VERSION 源码，开始下载"
  tgz="/tmp/freerdp-$FREERDP_VERSION.tar.gz"
  fetch_file "$tgz" \
    "https://codeload.github.com/FreeRDP/FreeRDP/tar.gz/refs/tags/$FREERDP_VERSION" \
    "https://github.com/FreeRDP/FreeRDP/archive/refs/tags/$FREERDP_VERSION.tar.gz" \
    || die "无法下载 FreeRDP $FREERDP_VERSION（也可手动解压到 $FREERDP_SRC）"
  tmpdir="$(mktemp -d)"
  tar -xzf "$tgz" -C "$tmpdir"
  top="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$top" && -d "$top/client/Android/Studio" ]] \
    || die "源码包结构异常：缺少 client/Android/Studio"
  rm -rf "$FREERDP_SRC"
  mkdir -p "$(dirname "$FREERDP_SRC")"
  mv "$top" "$FREERDP_SRC"
  rm -rf "$tmpdir" "$tgz"
fi

# 原生依赖镜像：文件名是上游 cmake 脚本按版本拼接查找的格式，缺失时自动下载
OSSL_TGZ="$MIRROR/openssl-$OPENSSL_VERSION.tar.gz"
CJSON_TGZ="$MIRROR/cJSON-$CJSON_VERSION.tar.gz"
URIPARSER_TGZ="$MIRROR/uriparser-$URIPARSER_VERSION.tar.gz"
if [[ ! -f "$OSSL_TGZ" ]]; then
  log "下载 OpenSSL $OPENSSL_VERSION 源码包"
  fetch_file "$OSSL_TGZ" \
    "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" \
    "https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-$OPENSSL_VERSION" \
    || die "无法下载 OpenSSL $OPENSSL_VERSION"
fi
if [[ ! -f "$CJSON_TGZ" ]]; then
  log "下载 cJSON $CJSON_VERSION 源码包"
  fetch_file "$CJSON_TGZ" \
    "https://codeload.github.com/DaveGamble/cJSON/tar.gz/refs/tags/v$CJSON_VERSION" \
    || die "无法下载 cJSON $CJSON_VERSION"
fi
if [[ ! -f "$URIPARSER_TGZ" ]]; then
  log "下载 uriparser $URIPARSER_VERSION 源码包"
  fetch_file "$URIPARSER_TGZ" \
    "https://codeload.github.com/uriparser/uriparser/tar.gz/refs/tags/uriparser-$URIPARSER_VERSION" \
    || die "无法下载 uriparser $URIPARSER_VERSION"
fi

for f in "$OSSL_TGZ" "$CJSON_TGZ" "$URIPARSER_TGZ"; do
  tar -tzf "$f" >/dev/null 2>&1 || die "压缩包损坏（删除后重跑即可重新下载）：$f"
done
OPENSSL_SHA="$(sha256sum "$OSSL_TGZ" | awk '{print $1}')"
CJSON_SHA="$(sha256sum "$CJSON_TGZ" | awk '{print $1}')"
URIPARSER_SHA="$(sha256sum "$URIPARSER_TGZ" | awk '{print $1}')"

echo "    ANDROID_HOME = $ANDROID_HOME"
echo "    JAVA_HOME    = $JAVA_HOME"
echo "    WORKDIR      = $WORKDIR"

# ---------------------------------------------------------------- 同步工作区
log "同步仓库到工作区（排除 .git/.gradle/build/.cxx/jniLibs/local.properties）"
mkdir -p "$WORKDIR"
# 排除项说明：'.git/.gradle/build/.cxx' 与 'freeRDPCore/src/main/jniLibs' 都是构建产物，
# 必须同时排除「传输」与「--delete」，否则增量运行会把上轮编好的原生库清掉。
rsync -a --delete \
  --exclude '.git' --exclude '.gradle' --exclude 'build' --exclude '.cxx' \
  --exclude 'freeRDPCore/src/main/jniLibs' \
  --exclude 'local.properties' \
  "$REPO_ROOT"/ "$WORKDIR"/

STUDIO="$WORKDIR/$STUDIO_REL"
CMAKE_DIR="$WORKDIR/deps/freerdp-$FREERDP_VERSION/client/Android/cmake"
DEP_VERSIONS="$WORKDIR/deps/freerdp-$FREERDP_VERSION/cmake/DepVersions.cmake"
NATIVE_PREFIX="$STUDIO/freeRDPCore/src/main/jniLibs/arm64-v8a"
[[ -d "$STUDIO" ]] || die "工作区里没有上游 Studio 工程：$STUDIO"
[[ -d "$CMAKE_DIR" ]] || die "上游工程结构变化，缺少 $CMAKE_DIR（请核对 FreeRDP $FREERDP_VERSION）"
[[ -f "$DEP_VERSIONS" ]] || die "工作区缺少 $DEP_VERSIONS"
for f in "$STUDIO/build.gradle" "$STUDIO/settings.gradle" \
         "$STUDIO/gradle/wrapper/gradle-wrapper.properties" "$STUDIO/freeRDPCore/build.gradle"; do
  [[ -f "$f" ]] || die "上游工程结构变化，缺少 $f（请核对 FreeRDP $FREERDP_VERSION）"
done

# 判定是否需要重编原生部分：
#   - CLEAN=1 强制重编；
#   - 原生安装前缀不完整（原生库或 cJSON 的 cmake config 缺失）时也必须重编，
#     否则 freerdp 子构建会因找不到 cJSON 而在 reconfigure 阶段失败。
need_native_clean=0
[[ "${CLEAN:-0}" == "1" ]] && need_native_clean=1
if [[ ! -f "$NATIVE_PREFIX/libfreerdp3.so" || ! -d "$NATIVE_PREFIX/lib/cmake/cJSON" ]]; then
  need_native_clean=1
fi
if [[ "$need_native_clean" == "1" ]]; then
  log "清理工作区的增量产物（freeRDPCore/build、.cxx、jniLibs 与 Studio/build）"
  rm -rf "$STUDIO/freeRDPCore/build" "$STUDIO/freeRDPCore/.cxx" "$NATIVE_PREFIX"
  rm -rf "$STUDIO/build" "$STUDIO/.gradle"
fi

# ---------------------------------------------------------------- PATCH 1/9
log "补丁 1/9：wrapper → Gradle 9.6.1（腾讯镜像）"
cat > "$STUDIO/gradle/wrapper/gradle-wrapper.properties" <<'EOF'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://mirrors.cloud.tencent.com/gradle/gradle-9.6.1-bin.zip
networkTimeout=30000
retries=3
retryBackOffMs=500
validateDistributionUrl=true
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOF

# ---------------------------------------------------------------- PATCH 2/9
log "补丁 2/9：settings.gradle → 只构建 :freeRDPCore"
cat > "$STUDIO/settings.gradle" <<'EOF'
// 仅构建引擎库模块；示例 App :aFreeRDP 不参与 AAR 产出
include ':freeRDPCore'
EOF

# ---------------------------------------------------------------- PATCH 3/9
log "补丁 3/9：删除 androidgitversion 插件（deps 无 .git/tag，必然失败）"
python3 - "$STUDIO/build.gradle" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# plugins { id 'com.gladed.androidgitversion' version '0.4.14' }
s = re.sub(r"plugins\s*\{\s*id 'com\.gladed\.androidgitversion'[^}]*\}\s*", "", s, count=1)
# androidGitVersion { ... }
s = re.sub(r"androidGitVersion\s*\{[^}]*\}\s*", "", s, count=1)
open(p, 'w', encoding='utf-8').write(s)
PY

# ---------------------------------------------------------------- PATCH 4/9
log "补丁 4/9：为 freeRDPCore 注入 namespace"
python3 - "$STUDIO/freeRDPCore/build.gradle" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if "namespace 'com.freerdp.freerdpcore'" not in s:
    s = s.replace("android {", "android {\n    namespace 'com.freerdp.freerdpcore'", 1)
    open(p, 'w', encoding='utf-8').write(s)
PY

# ---------------------------------------------------------------- PATCH 5/9
log "补丁 5/9：写入 release.properties（覆盖上游过重的默认值）"
cat > "$STUDIO/release.properties" <<EOF
COMPILE_API=37
TARGET_API=37
MIN_API=29
TOOLS_VERSION=37.0.0
NDK_VERSION=29.0.13113456
CMAKE_VERSION=4.1.2
ABI_FILTERS=arm64-v8a
SPLIT_ENABLED=false
BUILD_UNIVERSAL=true
SPLIT_ARCHITECTURES=arm64-v8a
CMAKE_ARGUMENTS=-DWITH_FFMPEG=OFF;-DWITH_OPENH264=OFF;-DWITH_OPUS=OFF;-DWITH_WEBP=OFF;-DWITH_JPEG=OFF;-DWITH_PNG=OFF;-DWITH_CJSON=ON;-DWITH_OPENSSL=ON
VERSION_NAME=$FREERDP_VERSION
VERSION_CODE=1
EOF

# ---------------------------------------------------------------- PATCH 6/9
log "补丁 6/9：补建上游缺失的 freeRDPCore/proguard-rules.txt"
if [[ ! -f "$STUDIO/freeRDPCore/proguard-rules.txt" ]]; then
  cat > "$STUDIO/freeRDPCore/proguard-rules.txt" <<'EOF'
# 上游 freeRDPCore 的 release buildType 引用了本文件却未随源码提供；
# minifyEnabled=false，内容为空即可。
EOF
fi

# ---------------------------------------------------------------- PATCH 7/9
log "补丁 7/9：收紧 Studio gradle.properties 的堆与并行度"
cat > "$STUDIO/gradle.properties" <<'EOF'
# 构建机内存有限：限制 Gradle 堆与并行度
org.gradle.jvmargs=-Xmx2048M -XX:MaxMetaspaceSize=768m -Dfile.encoding=UTF-8
org.gradle.workers.max=1
org.gradle.parallel=false
org.gradle.caching=true
org.gradle.daemon=true

# 以下为上游 Studio 工程原有开关，需保留
android.useAndroidX = true
android.enableJetifier = false
android.defaults.buildfeatures.resvalues=true
android.sdk.defaultTargetSdkToCompileSdkIfUnset=false
android.enableAppCompileTimeRClass=false
android.usesSdkInManifest.disallowed=false
android.uniquePackageNames=false
android.dependency.useConstraints=true
android.r8.strictFullModeForKeepRules=false
android.r8.optimizedResourceShrinking=false
android.builtInKotlin=false
android.newDsl=false
EOF

# ---------------------------------------------------------------- PATCH 8/9
log "补丁 8/9：cmake 依赖下载改为本地 mirror"

# 上游（3.33.x）把三个依赖都写成 GitHub 单条 URL；GitHub 不可达环境下统一改写为
# deps/mirror 下的本地压缩包。只保留一条 URL：CMake 4.x 对多 URL 列表校验更严格，
# 单一本地路径形式在 3.32.2 上已验证可用。
python3 - "$CMAKE_DIR" "$CJSON_VERSION" "$URIPARSER_VERSION" <<'PY'
import os, re, sys

cmake_dir, cjson_ver, uri_ver = sys.argv[1:4]
mirror = '${CMAKE_CURRENT_LIST_DIR}/../../../../mirror'
targets = {
    'ExternalOpenSSL.cmake':   mirror + '/${OPENSSL_VERSION}.tar.gz',
    'ExternalCJSON.cmake':     mirror + '/cJSON-' + cjson_ver + '.tar.gz',
    'ExternalUriparser.cmake': mirror + '/uriparser-' + uri_ver + '.tar.gz',
}

changed = []
for name, url in targets.items():
    p = os.path.join(cmake_dir, name)
    with open(p, encoding='utf-8') as f:
        s = f.read()
    # 先按 token 去掉既有的 URL 与地址（3.33.x 的 cJSON 把 URL 和 URL_HASH 写在同一行，
    # 不能整行删除），再在 URL_HASH 前插入唯一的本地镜像地址
    s2 = re.sub(r'\bURL[ \t]+\S+', '', s)
    s2 = re.sub(r'[ \t]*URL_HASH',
                lambda m: '\n  URL ' + url + '\n  ' + m.group(0).lstrip(),
                s2, count=1)
    s2 = s2.replace('make -j SHLIB_EXT', 'make -j4 SHLIB_EXT')
    if s2 != s:
        with open(p, 'w', encoding='utf-8') as f:
            f.write(s2)
        changed.append(name)

print('    changed:', ', '.join(changed) if changed else '(无，已是镜像状态)')
PY

# uriparser 的哈希在上游写死过；这里确保引用 DepVersions 里的变量。
python3 - "$CMAKE_DIR/ExternalUriparser.cmake" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s2 = re.sub(r'URL_HASH\s+SHA256=[0-9a-f]{64}', 'URL_HASH ${URIPARSER_HASH}', s)
if s2 != s:
    open(p, 'w', encoding='utf-8').write(s2)
PY

# 校验：每个文件必须恰好一条 URL，且不含 GitHub 远端
for f in "$CMAKE_DIR/ExternalOpenSSL.cmake" "$CMAKE_DIR/ExternalCJSON.cmake" "$CMAKE_DIR/ExternalUriparser.cmake"; do
  n=$(grep -cE '^[[:space:]]*URL[[:space:]]' "$f" || true)
  [[ "$n" == "1" ]] || die "$(basename "$f") 的 URL 行数为 $n（应为 1）"
  if grep -qE 'https?://' "$f"; then
    die "$(basename "$f") 仍含远端 URL"
  fi
done
echo "    cmake 依赖已指向本地 mirror"

# ---------------------------------------------------------------- PATCH 9/9
log "补丁 9/9：DepVersions.cmake → 按环境变量与镜像实际 sha256 锁定依赖版本"
python3 - "$DEP_VERSIONS" "openssl-$OPENSSL_VERSION" "$OPENSSL_SHA" \
        "v$CJSON_VERSION" "$CJSON_SHA" "$URIPARSER_VERSION" "$URIPARSER_SHA" <<'PY'
import re, sys
p, ossl_v, ossl_h, cjson_v, cjson_h, uri_v, uri_h = sys.argv[1:8]
s = open(p, encoding='utf-8').read()

def set_line(name, value, text):
    line = 'set(%s "%s")' % (name, value)
    pat = re.compile(r'^set\(\s*%s\s+"[^"]*"\s*\)' % name, re.M)
    if pat.search(text):
        return pat.sub(line, text, count=1)
    return text.rstrip() + '\n' + line + '\n'

for name, value in [('OPENSSL_VERSION', ossl_v), ('OPENSSL_HASH', 'SHA256=' + ossl_h),
                    ('CJSON_VERSION', cjson_v), ('CJSON_HASH', 'SHA256=' + cjson_h),
                    ('URIPARSER_VERSION', uri_v), ('URIPARSER_HASH', 'SHA256=' + uri_h)]:
    s = set_line(name, value, s)

open(p, 'w', encoding='utf-8').write(s)
print('    OPENSSL   =', ossl_v)
print('    cJSON     =', cjson_v)
print('    uriparser =', uri_v)
PY
grep -q "openssl-$OPENSSL_VERSION" "$DEP_VERSIONS" \
  || die "DepVersions.cmake 未写入 OpenSSL $OPENSSL_VERSION"
echo "    DepVersions.cmake 已锁定当前版本与镜像哈希"

# ---------------------------------------------------------------- PATCH 10/10
log "补丁 10/10：ClipboardImageProvider authority → com.peerrdp.freerdpcore.clipboard"
python3 - "$STUDIO/freeRDPCore/src/main/java/com/freerdp/freerdpcore/utils/ClipboardImageProvider.java" \
          "$STUDIO/freeRDPCore/src/main/AndroidManifest.xml" <<'PY'
import sys
OLD, NEW = 'com.freerdp.freerdpcore.clipboard', 'com.peerrdp.freerdpcore.clipboard'
for p in sys.argv[1:3]:
    with open(p, encoding='utf-8') as f:
        s = f.read()
    if NEW in s:
        continue
    assert OLD in s, f'{p} 缺少预期 authority 字符串（上游结构变化？）'
    with open(p, 'w', encoding='utf-8') as f:
        f.write(s.replace(OLD, NEW))
    print('    patched:', p.rsplit('/', 3)[-3] + '/' + p.rsplit('/', 2)[-2] + '/' + p.rsplit('/', 1)[-1])
PY

# ---------------------------------------------------------------- PATCH 11/11
log "补丁 11/11：客户端输入法文本输入（InputConnection → RDP Unicode 事件）"
python3 - "$STUDIO/freeRDPCore/src/main/java/com/freerdp/freerdpcore/presentation/SessionView.java" \
          "$STUDIO/freeRDPCore/src/main/java/com/freerdp/freerdpcore/presentation/SessionInputManager.java" <<'PY'
import sys

view_path, input_path = sys.argv[1], sys.argv[2]

with open(view_path, encoding='utf-8') as f:
    view = f.read()

if 'SessionInputConnection' in view:
    print('    SessionView 已打过补丁')
else:
    # 1) 需要 KeyEvent
    old = 'import android.view.InputDevice;\n'
    assert old in view, 'SessionView: InputDevice import 缺失（上游结构变化？）'
    view = view.replace(old, old + 'import android.view.KeyEvent;\n', 1)

    # 2) 监听接口新增文本输入回调
    old = '\t\tvoid onSessionViewHScroll(boolean right);\n\t}\n'
    assert old in view, 'SessionViewListener 尾部缺失（上游结构变化？）'
    view = view.replace(old,
        '\t\tvoid onSessionViewHScroll(boolean right);\n'
        '\n'
        '\t\t// 客户端输入法提交的文本。由监听方转成 RDP Unicode 按键事件，\n'
        '\t\t// 因此远端不再需要自己的输入法。\n'
        '\t\tboolean onSessionViewCommitText(CharSequence text);\n'
        '\n'
        '\t\tvoid onSessionViewDeleteText(int beforeLength, int afterLength);\n'
        '\n'
        '\t\tboolean onSessionViewImeKeyEvent(KeyEvent event);\n'
        '\t}\n', 1)

    # 3) TYPE_NULL → TYPE_CLASS_TEXT，并换上真正转发文本的 InputConnection
    old = (
        '\t@Override public InputConnection onCreateInputConnection(EditorInfo outAttrs)\n'
        '\t{\n'
        '\t\toutAttrs.actionLabel = null;\n'
        '\t\toutAttrs.inputType = InputType.TYPE_NULL;\n'
        '\t\toutAttrs.imeOptions = EditorInfo.IME_ACTION_NONE | EditorInfo.IME_FLAG_NO_EXTRACT_UI |\n'
        '\t\t                      EditorInfo.IME_FLAG_NO_FULLSCREEN;\n'
        '\t\treturn new BaseInputConnection(this, false);\n'
        '\t}\n')
    assert old in view, 'onCreateInputConnection 结构变化？'
    new = (
        '\t// 纯 View 默认不是文本编辑器；声明为 true，输入法才会稳定地附着到本视图。\n'
        '\t@Override public boolean onCheckIsTextEditor()\n'
        '\t{\n'
        '\t\treturn true;\n'
        '\t}\n'
        '\n'
        '\t@Override public InputConnection onCreateInputConnection(EditorInfo outAttrs)\n'
        '\t{\n'
        '\t\toutAttrs.actionLabel = null;\n'
        '\t\t// 普通文本输入框：输入法在本地组词，提交后的文本以 Unicode 按键事件发往远端。\n'
        '\t\t// 上游的 TYPE_NULL + BaseInputConnection 会丢弃 commitText，用户只能依赖服务器输入法。\n'
        '\t\toutAttrs.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE;\n'
        '\t\toutAttrs.imeOptions = EditorInfo.IME_ACTION_NONE | EditorInfo.IME_FLAG_NO_EXTRACT_UI |\n'
        '\t\t                      EditorInfo.IME_FLAG_NO_FULLSCREEN;\n'
        '\t\t// 视图本身没有文本，光标固定在 0；避免输入法把远端内容当作可替换文本。\n'
        '\t\toutAttrs.initialSelStart = 0;\n'
        '\t\toutAttrs.initialSelEnd = 0;\n'
        '\t\toutAttrs.initialCapsMode = 0;\n'
        '\t\treturn new SessionInputConnection(this);\n'
        '\t}\n'
        '\n'
        '\t// 只转发、不保存文本的 InputConnection：视图没有自己的文本缓冲区，文本属于远端。\n'
        '\tprivate class SessionInputConnection extends BaseInputConnection\n'
        '\t{\n'
        '\t\tSessionInputConnection(View targetView)\n'
        '\t\t{\n'
        '\t\t\tsuper(targetView, false);\n'
        '\t\t}\n'
        '\n'
        '\t\t@Override public boolean commitText(CharSequence text, int newCursorPosition)\n'
        '\t\t{\n'
        '\t\t\tif (text == null || text.length() == 0)\n'
        '\t\t\t\treturn true;\n'
        '\t\t\treturn sessionViewListener != null && sessionViewListener.onSessionViewCommitText(text);\n'
        '\t\t}\n'
        '\n'
        '\t\t// 组词过程留在输入法内部（候选框由输入法绘制），只发送最终提交的文本。\n'
        '\t\t@Override public boolean setComposingText(CharSequence text, int newCursorPosition)\n'
        '\t\t{\n'
        '\t\t\treturn true;\n'
        '\t\t}\n'
        '\n'
        '\t\t@Override public boolean finishComposingText()\n'
        '\t\t{\n'
        '\t\t\treturn true;\n'
        '\t\t}\n'
        '\n'
        '\t\t@Override public boolean deleteSurroundingText(int beforeLength, int afterLength)\n'
        '\t\t{\n'
        '\t\t\tif (beforeLength <= 0 && afterLength <= 0)\n'
        '\t\t\t\treturn true;\n'
        '\t\t\tif (sessionViewListener == null)\n'
        '\t\t\t\treturn false;\n'
        '\t\t\tsessionViewListener.onSessionViewDeleteText(beforeLength, afterLength);\n'
        '\t\t\treturn true;\n'
        '\t\t}\n'
        '\n'
        '\t\t@Override public boolean deleteSurroundingTextInCodePoints(int beforeLength,\n'
        '\t\t                                                          int afterLength)\n'
        '\t\t{\n'
        '\t\t\treturn deleteSurroundingText(beforeLength, afterLength);\n'
        '\t\t}\n'
        '\n'
        '\t\t@Override public boolean sendKeyEvent(KeyEvent event)\n'
        '\t\t{\n'
        '\t\t\treturn sessionViewListener != null && sessionViewListener.onSessionViewImeKeyEvent(event);\n'
        '\t\t}\n'
        '\t}\n')
    view = view.replace(old, new, 1)

    with open(view_path, 'w', encoding='utf-8') as f:
        f.write(view)
    print('    patched: SessionView.java')

with open(input_path, encoding='utf-8') as f:
    inp = f.read()

if 'onSessionViewCommitText' in inp:
    print('    SessionInputManager 已打过补丁')
else:
    old = '\tprivate static final int MOVE_EVENT_THROTTLE_MS = 16;\n'
    assert old in inp, 'SessionInputManager 常量区缺失（上游结构变化？）'
    inp = inp.replace(old,
        old
        + '\n'
        + '\t// 软键盘路径使用的虚拟键码；与 KeyboardMapper 中同名的包内常量保持一致。\n'
        + '\t// VK_DELETE 是扩展键，需带 0x0100 标志位。\n'
        + '\tprivate static final int VK_RETURN = 0x0D;\n'
        + '\tprivate static final int VK_TAB = 0x09;\n'
        + '\tprivate static final int VK_BACK = 0x08;\n'
        + '\tprivate static final int VK_DELETE = 0x2E | 0x0100;\n', 1)

    old = (
        '\t@Override public boolean isUnicodeInputSupported()\n'
        '\t{\n'
        '\t\treturn instance != 0 && LibFreeRDP.isUnicodeInputSupported(instance);\n'
        '\t}\n')
    assert old in inp, 'isUnicodeInputSupported 结构变化？'
    new = old + (
        '\n'
        '\t// ****************************************************************************\n'
        '\t// 客户端输入法文本输入\n'
        '\n'
        '\t@Override public boolean onSessionViewCommitText(CharSequence text)\n'
        '\t{\n'
        '\t\tif (instance == 0)\n'
        '\t\t\treturn false;\n'
        '\t\tfor (int i = 0; i < text.length(); i++)\n'
        '\t\t{\n'
        '\t\t\tfinal char c = text.charAt(i);\n'
        '\t\t\t// 输入法把回车/制表符当作文本提交；改发真正的按键。\n'
        '\t\t\tif (c == \'\\n\' || c == \'\\r\')\n'
        '\t\t\t{\n'
        '\t\t\t\tprocessVirtualKey(VK_RETURN, true);\n'
        '\t\t\t\tprocessVirtualKey(VK_RETURN, false);\n'
        '\t\t\t}\n'
        '\t\t\telse if (c == \'\\t\')\n'
        '\t\t\t{\n'
        '\t\t\t\tprocessVirtualKey(VK_TAB, true);\n'
        '\t\t\t\tprocessVirtualKey(VK_TAB, false);\n'
        '\t\t\t}\n'
        '\t\t\telse if (c >= 0x20 && c < 0x7F)\n'
        '\t\t\t{\n'
        '\t\t\t\t// 可打印 ASCII 仍走扫描码：远端输入法照样能组词，Ctrl+Space 之类的\n'
        '\t\t\t\t// 组合键（含浮层键盘锁定的修饰键）也依旧生效。\n'
        '\t\t\t\tkeyboardMapper.processUnicodeFallback(c);\n'
        '\t\t\t}\n'
        '\t\t\telse\n'
        '\t\t\t\tprocessUnicodeKey(c);\n'
        '\t\t}\n'
        '\t\treturn true;\n'
        '\t}\n'
        '\n'
        '\t@Override public void onSessionViewDeleteText(int beforeLength, int afterLength)\n'
        '\t{\n'
        '\t\tif (instance == 0)\n'
        '\t\t\treturn;\n'
        '\t\tfor (int i = 0; i < beforeLength; i++)\n'
        '\t\t{\n'
        '\t\t\tprocessVirtualKey(VK_BACK, true);\n'
        '\t\t\tprocessVirtualKey(VK_BACK, false);\n'
        '\t\t}\n'
        '\t\tfor (int i = 0; i < afterLength; i++)\n'
        '\t\t{\n'
        '\t\t\tprocessVirtualKey(VK_DELETE, true);\n'
        '\t\t\tprocessVirtualKey(VK_DELETE, false);\n'
        '\t\t}\n'
        '\t}\n'
        '\n'
        '\t@Override public boolean onSessionViewImeKeyEvent(KeyEvent event)\n'
        '\t{\n'
        '\t\treturn onAndroidKeyEvent(event);\n'
        '\t}\n')
    inp = inp.replace(old, new, 1)

    with open(input_path, 'w', encoding='utf-8') as f:
        f.write(inp)
    print('    patched: SessionInputManager.java')
PY

if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  log "SKIP_BUILD=1：已停在打补丁阶段，未编译"
  exit 0
fi

# ---------------------------------------------------------------- 编译
log "执行 :freeRDPCore:assembleRelease（AGP 9.2.1 + Gradle 9.6.1）"
( cd "$STUDIO" && ./gradlew :freeRDPCore:assembleRelease --console=plain )

# ---------------------------------------------------------------- 回填与校验
AAR_OUT="$STUDIO/freeRDPCore/build/outputs/aar/freeRDPCore-release.aar"
[[ -f "$AAR_OUT" ]] || die "构建未产出 AAR：$AAR_OUT"

DEST="$REPO_ROOT/app/libs/freeRDPCore-release.aar"
mkdir -p "$(dirname "$DEST")"
cp "$AAR_OUT" "$DEST"

log "校验 $DEST"
# 注意：这里先把清单接到变量再匹配，避免 `unzip | grep -q` 在 pipefail 下
# 因 grep 提前退出、unzip 收到 SIGPIPE 而误报失败。
LISTING="$(unzip -l "$DEST")"
has() { grep -q "$1" <<<"$LISTING"; }

has 'classes\.jar'                    || die "AAR 缺少 classes.jar"
has 'jni/arm64-v8a/libfreerdp-android\.so' || die "AAR 缺少 JNI 库 libfreerdp-android.so"
for so in libfreerdp3 libfreerdp-client3 libwinpr3 libssl libcrypto libcjson liburiparser; do
  has "jni/arm64-v8a/$so\.so" || die "AAR 缺少 jni/arm64-v8a/$so.so"
done
grep -E 'classes\.jar|jni/arm64-v8a/' <<<"$LISTING"
printf '\n'
ls -lh "$DEST"
sha256sum "$DEST"

log "完成"
cat <<EOF
下一步（可选）：
  构建应用 →  rsync 仓库到 /tmp 后执行 ./gradlew :app:assembleDebug
  重新完整构建引擎 AAR → CLEAN=1 $0
EOF
