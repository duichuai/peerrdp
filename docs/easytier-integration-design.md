# PeerRDP 集成 EasyTier 设计文档

| 项目 | 内容 |
| --- | --- |
| 文档版本 | v1.1 设计稿 |
| 状态 | **决策已确认，未实施** |
| 评估日期 | 2026-11-18 |
| 决策日期 | 2026-11-18 |
| 评估基线 | EasyTier `v2.6.4`（最新 release，2026-05-12）；main 分支 crate 2.7.1 |
| 关系 | `tailscale-integration-design.md` 的并列组网后端；`n2n-integration-design.md` 未采用 |
| 代码基线 | PeerRDP DB v4、Tailscale（tsnet）已实现 |

> **已确认决策**：v1 与 Tailscale 共存；接受 LGPL-3.0；spike 用公共节点、正式环境自建 public node；v1 不做 TUN 全局模式。详见 §14。

---

## 1. 目标与范围

### 1.1 产品目标

在现有 Tailscale（tsnet）之外，为 PeerRDP 增加 EasyTier 组网能力：手机与目标 Windows 主机加入同一个 EasyTier 虚拟网络，RDP 通过虚拟 IP 连接，不依赖自建 Headscale。

| 编号 | 需求 | 说明 |
| --- | --- | --- |
| E1 | EasyTier 配置管理 | 保存网络名、网络密钥、对等节点、虚拟 IP/DHCP、主机名 |
| E2 | 应用内用户态组网 | 使用 `no_tun = true` + 内置 SOCKS5，不申请 `VpnService` |
| E3 | 与 RDP 联动 | 连接前自动启动 EasyTier，等待就绪后通过本地 SOCKS5 发起 RDP |
| E4 | 与现有后端共存 | 直连、Tailscale、EasyTier 三种方式由连接配置选择 |
| E5 | 可诊断 | 启动失败能回传错误与日志尾部，状态可查询 |

### 1.2 本次交付范围

本文档只输出方案与设计：选型结论、数据模型、模块划分、JNI 调用约定、TOML 配置、构建打包、风险与合规。**不修改应用代码、不产出 APK。**

### 1.3 非目标（v1 不做）

- 不做 `VpnService` / TUN 全局模式（作为 v2 可选项，见 §2.2）。
- 不做 EasyTier 配置服务器（config server）托管。
- 不做同一时间多个 EasyTier 实例并发（EasyTier 支持多实例，但 v1 只保留一个 `peerrdp` 实例）。
- 不做 MagicDNS，RDP 主机字段仍填虚拟 IP。
- 不做 WireGuard Portal、Exit Node、子网代理（`proxy_networks` 留作后续）。
- 不做 iOS。

---

## 2. 方案选型

### 2.1 为什么选 EasyTier

| 维度 | n2n（已否决） | Tailscale/tsnet（现状） | EasyTier |
| --- | --- | --- | --- |
| 协议层级 | 二层 TAP，需 tun2tap | 三层 TUN | 三层，`no_tun` + SOCKS5 |
| Android 集成 | 无官方，需自写 JNI + tun2tap | gomobile AAR + 自写 SOCKS5 | 官方 JNI + 内置 SOCKS5 |
| 控制面 | supernode 仅中继 | 需自建 Headscale | 去中心化，网络名 + 密钥；可用公共共享节点 |
| NAT 穿透 | UDP 打洞，失败走 supernode | DERP 中继 + DISCO | UDP/TCP 打洞 + 节点中转 |
| 许可 | GPLv3 | BSD-3-Clause | **LGPL-3.0** |
| 集成工作量 | 高（tun2tap） | 中 | 中低（主要是构建链） |

EasyTier 正好绕开了 n2n 的两个否决点：不需要 TAP/tun2tap，不是 GPLv3；但 LGPL-3.0 仍需合规处理（见 §10）。

### 2.2 TUN vs SOCKS5

| 维度 | TUN（VpnService + `setTunFd`） | SOCKS5（`no_tun` + `socks5_proxy`） |
| --- | --- | --- |
| 系统权限 | 需要 `VpnService.prepare()` 授权、`BIND_VPN_SERVICE`、前台服务与通知权限 | 不需要 VPN 权限 |
| 流量范围 | 整机或按 App/路由限定 | 仅显式走代理的 App（本项目为 FreeRDP） |
| 协议支持 | TCP / UDP / ICMP | 主要 TCP；UDP/ICMP 不支持 |
| 与其它 VPN 共存 | 通常互斥 | 可以共存 |
| 状态栏 | VPN 图标 + 常驻通知 | 无 |
| RDP 连接 | 直接连虚拟 IP，无 `/proxy` | `/proxy:socks5://127.0.0.1:<port>` |
| 自身流量回环 | 需 `protect()` 或 `addDisallowedApplication` | 不存在 |
| 网络切换 | 虚拟 IP / proxy CIDR 变化时通常要重建 TUN | EasyTier 内部处理，上层重连即可 |
| 集成复杂度 | 高 | 低 |
| 安全面 | 整机流量进入虚拟网 | 本地无认证 SOCKS5，同机其它 App 知道端口也能借用 |
| 适用场景 | 系统级组网、多 App、UDP/ICMP | 单 App 接入、轻量、与其它 VPN 共存 |

### 2.3 选型结论

**v1 采用 `no_tun = true` + 内置 SOCKS5。** 理由：

1. RDP 只需 TCP，SOCKS5 能力足够。
2. 现有 `RdpConnector` 已支持 `/proxy:socks5://`，改动最小。
3. 不新增 Manifest 权限，不影响用户已有 VPN。
4. 失败影响面仅限 RDP，不会把整机网络搞断。
5. TUN 的收益（整机访问、UDP/ICMP）在本项目 v1 中不成立。

TUN 作为 v2 可选“全局模式”，单独设计权限、前台服务、路由与 IP 变化处理，不与 v1 混做。该结论已确认，见 §14.4。

---

## 3. EasyTier 技术事实与约束

| 项 | 结论 |
| --- | --- |
| Android 支持 | `easytier-contrib/easytier-android-jni`，`cargo-ndk` 构建 |
| 产物 | `libeasytier_android_jni.so` + `libeasytier_ffi.so`，两个都要打包 |
| Java/Kotlin 门面 | `com.easytier.jni.EasyTierJNI`（`kotlin/com/easytier/jni/EasyTierJNI.kt`） |
| 最低 Android | `minSdk 24`（项目 `minSdk 29`，满足） |
| 无 TUN 模式 | `[flags] no_tun = true` |
| 无 TUN 下主动访问 | 内置 SOCKS5 或 Port Forward |
| SOCKS5 配置 | `socks5_proxy = "socks5://127.0.0.1:<port>"` |
| 关键 TOML 字段 | `instance_name`、`hostname`、`dhcp`、`ipv4`、`listeners`、`socks5_proxy`、`[network_identity]`、`[[peer]]`、`[flags]` |
| 许可证 | 仓库 `LICENSE` 为 **LGPL-3.0** |
| 体积参考 | 官方 `app-arm64-release.apk` = 31.4MB（含 Tauri 前端） |
| 状态查询 | `collectNetworkInfos(maxLength)` 返回 JSON；`my_node_info.virtual_ipv4` 表示已分配虚拟 IP |

### 3.1 上游坑位

1. **README 示例配置已过期**：`easytier-android-jni/README.md` 使用 `inst_name`、`network`，当前真实 schema 为 `instance_name`、`[network_identity] network_name`。以固定 tag 的 `easytier-core/src/config/toml.rs` 与 magisk 的 `config/config.toml` 为准。
2. **两个 `.so`**：README 的目录示例只列了 `libeasytier_android_jni.so`，实际还需要 `libeasytier_ffi.so`；漏打会导致 `UnsatisfiedLinkError` 或加载失败。
3. **移动 FFI 仍在演进**：近期有 embedded runtime、managed network、panic-safe C ABI 等改动。必须固定 tag，并在升级前做互通回归。
4. **`socks5` 是编译特性**：`easytier` crate 默认特性包含 `socks5`，JNI 使用默认特性；若后续自行裁剪特性，必须保留 `socks5`（依赖 `smoltcp`）。
5. **16KB 页对齐**：targetSdk 35+ 需要原生库支持 16KB 页；官方 `build.sh` 未显式设置，需自行验证/加固（见 §8.3）。

---

## 4. 总体架构

```
┌──────────────────────────────────────────────────────────────┐
│ UI 层                                                         │
│  MainActivity                菜单：Tailscale 配置 / EasyTier 配置 │
│  ConnectionEditActivity      「组网方式」：直连 / Tailscale / EasyTier │
│  EasyTierConfigEditActivity  EasyTier 配置编辑                │
├──────────────────────────────────────────────────────────────┤
│ 应用逻辑层                                                    │
│  EasyTierManager             生成 TOML、启停、状态轮询、SOCKS5 端口 │
│  RdpConnector                按配置注入 /proxy:socks5://...    │
├──────────────────────────────────────────────────────────────┤
│ 数据层                                                        │
│  Room：easytier_configs / connections.easytierConfigId        │
├──────────────────────────────────────────────────────────────┤
│ EasyTier 原生层（预编译）                                      │
│  libeasytier_android_jni.so → EasyTierJNI                     │
│  libeasytier_ffi.so → EasyTier core（no_tun + SOCKS5）        │
├──────────────────────────────────────────────────────────────┤
│ RDP 引擎层（已有）                                             │
│  SessionActivity → LibFreeRDP → /proxy:socks5://127.0.0.1:port │
└──────────────────────────────────────────────────────────────┘

外部依赖：
  Windows 目标主机安装 EasyTier 并加入同一网络（TUN 模式）
  公共共享节点或自建 EasyTier public node（用于发现/中转）
```

设计原则：

1. **EasyTier 与应用解耦**：所有 JNI 调用收敛到 `EasyTierManager`，`RdpConnector` 只拿 SOCKS5 端口。
2. **不申请 VpnService**：`no_tun` 用户态运行，不与系统其它 VPN 冲突。
3. **单实例**：实例名固定 `peerrdp`，切换配置时先停后启，避免残留。
4. **配置不落盘**：TOML 在内存中生成，通过 `runNetworkInstance(config)` 传入；网络密钥仍存 Room。

---

## 5. 数据层设计

### 5.1 新增表 `easytier_configs`（DB v5）

| 字段 | 类型 | 约束 / 默认 | 说明 |
| --- | --- | --- | --- |
| id | INTEGER | PK AUTOINCREMENT | 主键 |
| name | TEXT | NOT NULL | 配置显示名 |
| networkName | TEXT | NOT NULL | EasyTier 网络名 |
| networkSecret | TEXT | NOT NULL | 网络密钥（明文，见 §5.5） |
| peers | TEXT | NOT NULL | 对等节点 URI，换行分隔 |
| ipv4 | TEXT | NOT NULL, 默认 `""` | 固定虚拟 IP；空且 dhcp=true 时自动分配 |
| dhcp | INTEGER | NOT NULL, 默认 1 | 1 = 自动分配虚拟 IP |
| hostname | TEXT | NOT NULL, 默认 `peerrdp` | 节点主机名 |
| createdAt | INTEGER | NOT NULL | 创建时间戳 |

实体建议：

```kotlin
@Entity(tableName = "easytier_configs")
data class EasyTierConfigEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val name: String,
    val networkName: String,
    val networkSecret: String,
    /** 换行分隔，例如 tcp://public.example.com:11010 */
    val peers: String = "",
    /** 空 + dhcp=true 时由 EasyTier 自动分配 */
    val ipv4: String = "",
    val dhcp: Boolean = true,
    val hostname: String = "peerrdp",
    val createdAt: Long = System.currentTimeMillis()
)
```

### 5.2 修改 `connections`

| 字段 | 类型 | 约束 / 默认 | 说明 |
| --- | --- | --- | --- |
| easytierConfigId | INTEGER | NOT NULL, 默认 0 | 绑定的 `easytier_configs.id`；0 = 不使用 |

保留现有 `tailscaleConfigId`。UI 层保证两者互斥：选择 EasyTier 时把 `tailscaleConfigId` 置 0，反之亦然。

### 5.3 迁移 SQL（DB v4 → v5）

```sql
CREATE TABLE IF NOT EXISTS easytier_configs (
    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    name TEXT NOT NULL,
    networkName TEXT NOT NULL,
    networkSecret TEXT NOT NULL,
    peers TEXT NOT NULL,
    ipv4 TEXT NOT NULL,
    dhcp INTEGER NOT NULL,
    hostname TEXT NOT NULL,
    createdAt INTEGER NOT NULL
);

ALTER TABLE connections ADD COLUMN easytierConfigId INTEGER NOT NULL DEFAULT 0;
```

按现有约定，必须连续迁移，不能 `fallbackToDestructiveMigration`。

### 5.4 DAO 契约

`EasyTierConfigDao`：

| 方法 | 说明 |
| --- | --- |
| `observeAll(): Flow<List<EasyTierConfigEntity>>` | 配置列表 |
| `getAll(): List<EasyTierConfigEntity>` | 编辑页下拉 |
| `getById(id): EasyTierConfigEntity?` | 连接前读取 |
| `insert` / `update` / `delete(id)` | 增删改 |

### 5.5 安全说明

`networkSecret` 与现有 `tailscale_configs.authKey`、`connections.password` 一样是明文 SQLite。v1 沿用现状；后续与 R1/R13 一并做 Keystore 加密或启用 SQLCipher。

---

## 6. 应用层设计

### 6.1 `EasyTierManager`

单例 `object`，所有 JNI 调用在 `Dispatchers.IO` + `Mutex` 中串行执行。

```kotlin
object EasyTierManager {
    private const val INSTANCE_NAME = "peerrdp"

    /** 启动（或复用）实例，返回本地 SOCKS5 端口 */
    suspend fun ensureReady(context: Context, configId: Long): Int

    /** 停止当前实例 */
    suspend fun stop()

    /** 当前状态：stopped / starting / running / error */
    suspend fun status(): String

    fun socks5Port(): Int?
    fun isRunning(): Boolean
}
```

职责：

| 方法 | 说明 |
| --- | --- |
| `ensureReady` | 读取配置 → 分配端口 → 生成 TOML → `parseConfig` → `runNetworkInstance` → 等待就绪 → 返回端口 |
| `stop` | `deleteNetworkInstance("peerrdp")`，清空状态 |
| `status` | 轮询 `collectNetworkInfos()`；未启动返回 `stopped` |
| 错误处理 | 失败时附带 `getLastError()`；必要时附 logcat 尾部 |

### 6.2 TOML 生成

```kotlin
private fun buildToml(
    cfg: EasyTierConfigEntity,
    socksPort: Int,
    listenPort: Int
): String {
    val peerBlocks = cfg.peers.lines()
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .joinToString("\n") { "[[peer]]\nuri = \"${tomlEscape(it)}\"" }

    return """
        instance_name = "peerrdp"
        hostname = "${tomlEscape(cfg.hostname)}"
        ${if (cfg.dhcp) "dhcp = true" else "ipv4 = \"${tomlEscape(cfg.ipv4)}\""}
        listeners = [
          "tcp://0.0.0.0:$listenPort",
          "udp://0.0.0.0:$listenPort",
        ]
        socks5_proxy = "socks5://127.0.0.1:$socksPort"

        [network_identity]
        network_name = "${tomlEscape(cfg.networkName)}"
        network_secret = "${tomlEscape(cfg.networkSecret)}"

        $peerBlocks

        [flags]
        no_tun = true
        enable_encryption = true
        mtu = 1380
    """.trimIndent()
}
```

说明：

- `socks5_proxy` 必须绑 `127.0.0.1`，不要用 `0.0.0.0`，避免局域网或同机其它 App 直接借用。
- `listeners` 端口由应用分配（见 §6.3）；若与其它程序冲突，启动失败后换端口重试一次。
- `peers` 支持多行，每行一个 `tcp://` / `udp://` / `wg://` URI；公共共享节点也填在这里。
- TOML 字符串必须转义 `"`、`\` 和换行，避免网络密钥破坏配置。

### 6.3 端口分配与就绪判断

```kotlin
private fun freePort(): Int = ServerSocket(0).use { it.localPort }
```

就绪流程：

1. `EasyTierJNI.parseConfig(toml)` 返回 0。
2. `EasyTierJNI.runNetworkInstance(toml)` 返回 0。
3. 每 500ms 调用 `collectNetworkInfos(10)`，解析 JSON：
   - 返回结构为 protobuf JSON 的 `{ "map": { "<instance_name>": { ... } } }`，先按实例名 `peerrdp` 取出节点；
   - 实例 `running == true`；
   - `my_node_info.virtual_ipv4` 非空；
   - 超时 30s（可配置）。
4. `Socket("127.0.0.1", socksPort)` 探测成功。
5. 返回 `socksPort`。

JSON 解析优先用 Android 内置 `org.json`，不引入上游 `Moshi + Wire` 生成的 `common.Ipv4Inet` / `web.NetworkInstanceRunningInfoMap`，避免额外依赖。

### 6.4 `RdpConnector` 改造

在现有 Tailscale 分支旁增加 EasyTier 分支：

```kotlin
if (conn.easytierConfigId > 0) {
    val port = EasyTierManager.ensureReady(context, conn.easytierConfigId)
    builder.appendQueryParameter("proxy", "socks5://127.0.0.1:$port")
}
```

约束：

- 若 `tailscaleConfigId > 0 && easytierConfigId > 0`，直接抛异常；UI 应保证互斥。
- `host` 字段填目标主机的 EasyTier 虚拟 IP（如 `10.126.126.2`），不使用 MagicDNS。
- 连接失败时把 `getLastError()` / 日志尾部带回 Toast，与现有 Tailscale 失败反馈一致。

### 6.5 UI 设计

**连接编辑页**：把现有“Tailscale 配置”下拉改为“组网方式”：

- 直连（默认，两个 ID 都为 0）
- Tailscale（显示 Tailscale 配置下拉）
- EasyTier（显示 EasyTier 配置下拉）

选中一种后，另一后端 ID 自动清零。保留现有字段与校验逻辑，新增字段不参与 host/port 校验。

**EasyTier 配置页**：新增 `EasyTierConfigEditActivity`，字段：

| 字段 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| 名称 | 是 | — | 配置显示名 |
| 网络名 | 是 | — | `network_name` |
| 网络密钥 | 是 | — | `network_secret` |
| 对等节点 | 否 | — | 多行 URI；公共共享节点或自建 public node |
| 自动分配 IP | 否 | 开 | 关闭时显示虚拟 IP 输入框 |
| 虚拟 IP | 条件 | — | 如 `10.126.126.2/24` |
| 主机名 | 是 | `peerrdp` | `hostname` |
| SOCKS5 端口 / 监听端口 | 否 | 自动 | 不暴露给用户 |

**入口**：在 `main_menu.xml` 增加 `action_easytier`（“EasyTier 配置”），与现有 Tailscale 菜单项并列。配置页沿用现有 Toolbar + ScrollView + TextInputLayout 布局。

### 6.6 状态与错误

- 启动中：连接点击后显示“正在启动 EasyTier…”（可复用现有 Toast/加载态）。
- 失败：`EasyTierJNI.getLastError()` + 最近 logcat（`EasyTier-JNI`）尾部。
- 成功：Toast/日志记录虚拟 IP 与 SOCKS5 端口，便于排障。
- 不做常驻状态页；v1 只保证连接前可用。

### 6.7 生命周期与线程

- 实例与应用进程同生命周期；进程被系统回收后 EasyTier 停止，与现有 tsnet 一致。
- 切换 EasyTier 配置时：`stop()` → `ensureReady()`，避免旧实例残留。
- 应用退出不主动停止（与 tsnet 一致）；后续可加“断开组网”入口。
- 所有 JNI 调用阻塞式，统一 `withContext(Dispatchers.IO)` + `Mutex`，避免 ANR。
- Rust panic 可能直接中止进程；调用点必须 `try/catch`，并把错误写入日志。

---

## 7. 配置模型

### 7.1 完整示例

```toml
instance_name = "peerrdp"
hostname = "peerrdp"
dhcp = true
listeners = [
  "tcp://0.0.0.0:11010",
  "udp://0.0.0.0:11010",
]
socks5_proxy = "socks5://127.0.0.1:18080"

[network_identity]
network_name = "my-net"
network_secret = "change-me"

[[peer]]
uri = "tcp://<公共共享节点或自建public节点>:11010"

[flags]
no_tun = true
enable_encryption = true
mtu = 1380
```

### 7.2 UI → TOML 字段映射

| UI 字段 | TOML | 说明 |
| --- | --- | --- |
| 网络名 | `network_identity.network_name` | 必填 |
| 网络密钥 | `network_identity.network_secret` | 必填 |
| 对等节点 | `[[peer]].uri` | 每行一条 |
| 自动分配 IP | `dhcp` | true/false |
| 虚拟 IP | `ipv4` | dhcp=false 时使用 |
| 主机名 | `hostname` | 默认 `peerrdp` |
| （自动） | `instance_name` | 固定 `peerrdp` |
| （自动） | `socks5_proxy` | 固定 `socks5://127.0.0.1:<port>` |
| （自动） | `listeners` | 自动分配端口 |
| （固定） | `flags.no_tun` | `true` |

---

## 8. 构建与打包

### 8.1 构建脚本 `scripts/build-easytier-so.sh`

建议流程：

```bash
EASYTIER_VERSION="${EASYTIER_VERSION:-v2.6.4}"
SRC="deps/easytier-$EASYTIER_VERSION"

# 1) 获取源码（入 deps/，不入库）
#    网络受限时走现有 socks5 代理
git clone --depth 1 --branch "$EASYTIER_VERSION" \
  https://github.com/EasyTier/EasyTier.git "$SRC"

# 2) 工具链
rustup target add aarch64-linux-android
cargo install cargo-ndk   # 已安装则跳过

# 3) 构建 FFI 与 JNI
(cd "$SRC/easytier-contrib/easytier-ffi" && \
  cargo ndk -t arm64-v8a build --release)
(cd "$SRC/easytier-contrib/easytier-android-jni" && \
  cargo ndk -t arm64-v8a build --release)

# 4) 回填两个 .so
mkdir -p app/src/main/jniLibs/arm64-v8a
cp "$SRC/target/aarch64-linux-android/release/libeasytier_ffi.so" \
   app/src/main/jniLibs/arm64-v8a/
cp "$SRC/target/aarch64-linux-android/release/libeasytier_android_jni.so" \
   app/src/main/jniLibs/arm64-v8a/

# 5) 校验
llvm-readelf -lW app/src/main/jniLibs/arm64-v8a/libeasytier_ffi.so
llvm-readelf -lW app/src/main/jniLibs/arm64-v8a/libeasytier_android_jni.so
```

注意：上游 `build.sh` 会先构建 `easytier-ffi`，再在 `easytier-android-jni` 目录构建 JNI；两者产物都在仓库根 `target/<rust-target>/release/`。以固定 tag 的脚本为准，不要直接复制 README。

### 8.2 打包方式

两种可选：

| 方式 | 优点 | 缺点 |
| --- | --- | --- |
| `app/src/main/jniLibs/arm64-v8a/` | 简单、Gradle 原生支持 | 二进制散落，需脚本维护 |
| `app/libs/easytier.aar` | 与 `tsnet.aar` 风格一致，便于版本化 | 需手工组装 AAR（`AndroidManifest.xml` + `jni/`） |

v1 建议 **jniLibs**，减少 AAR 组装与 AGP 兼容问题；若团队坚持 `app/libs` 模式，再把两个 `.so` 打进最小 AAR。无论哪种，**两个 `.so` 必须同时存在**。

### 8.3 16KB 页对齐

targetSdk 37 需要关注 Android 15+ 的 16KB 页设备：

- 使用 NDK r28+，或显式加链接参数：
  ```bash
  export RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384"
  ```
- 校验 ELF 的 LOAD 段 `Align` 为 `0x4000`（或更大）。
- 校验 APK：
  ```bash
  zipalign -c -P 16 -v 4 app-release.apk
  ```
- 若官方预编译 `.so` 不满足，必须自行用上述参数重建，不能直接使用 release 附件。

### 8.4 R8 keep 规则

在 `app/proguard-rules.pro` 增加：

```proguard
# EasyTier JNI：native 方法按名称绑定，类名/方法名不能混淆
-keep class com.easytier.jni.** { *; }
```

现有 `-keepclasseswithmembernames ... native <methods>` 已覆盖 native 方法名，但 JNI 回调接口（如 `ConfigServerEventCallback`）也需要保留；v1 不使用 config server，可只保留门面类。

### 8.5 CI 与产物校验

在 `scripts/build-app.sh` 与 `.github/workflows/*` 增加：

- APK 内存在 `lib/arm64-v8a/libeasytier_android_jni.so` 与 `lib/arm64-v8a/libeasytier_ffi.so`。
- 两个 `.so` 的 LOAD 段 16KB 对齐。
- `aapt2 dump permissions` 不出现新增 VPN/通知权限（v1）。
- `THIRD_PARTY_NOTICES.md` / `SOURCE.md` 包含 EasyTier 条目。
- 产物 SHA-256 记录。

### 8.6 体积估算与裁剪

- 现状 release ≈35MB（`libgojni.so` 19MB）。
- EasyTier 官方 Android arm64 APK 31.4MB，核心 `.so` 预计 15–25MB；叠加后预计 **50–60MB**（需实测）。
- 可选裁剪（按收益排序）：
  1. `strip` + `lto = true` + `codegen-units = 1` + `opt-level = "z"`。
  2. 关闭未用特性：`websocket`、`quic`、`kcp`、`magic-dns`、`faketcp`、`vpn-portal` 等；**必须保留 `socks5` 与 `smoltcp`**。
  3. ABI 分包（当前只 arm64，收益有限）。
  4. 若同时保留 Tailscale，考虑 product flavor 或后续二选一，避免双运行时长期叠加。

特性裁剪需要修改 `easytier-android-jni/Cargo.toml`（当前 `default-features = true`），属于维护 fork 的成本，建议 v2 再做。

---

## 9. 权限与 Manifest

v1（SOCKS5）**不新增权限**，现有清单足够：

| 权限 | 用途 |
| --- | --- |
| `INTERNET` | EasyTier 与 RDP |
| `ACCESS_NETWORK_STATE` | 网络状态判断 |

保持 `POST_NOTIFICATIONS`、`CAMERA`、`RECORD_AUDIO` 等 `tools:node="remove"` 不变。

v2 若做 TUN，需要新增：

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<service
    android:name=".easytier.EasyTierVpnService"
    android:exported="false"
    android:foregroundServiceType="specialUse"
    android:permission="android.permission.BIND_VPN_SERVICE">
    <intent-filter>
        <action android:name="android.net.VpnService" />
    </intent-filter>
</service>
```

并实现 `VpnService.prepare()` 授权流程、前台通知、路由/DNS、虚拟 IP 变化重建接口、自身流量回环处理。该部分不在 v1 范围。

---

## 10. 许可合规（LGPL-3.0）

EasyTier 仓库 `LICENSE` 为 **GNU LGPL-3.0**。**决策：接受该许可**（见 §14.2）：本项目自身 Apache-2.0 且源码公开，EasyTier 以独立 `.so` 动态链接、不修改上游，按下列方式合规即可。分发包含 EasyTier 的 APK 时，至少做到：

1. **动态链接、独立文件**：保持 `libeasytier_android_jni.so` / `libeasytier_ffi.so` 为独立共享库，不静态链接进应用自有 `.so`。
2. **不修改上游**：直接使用固定 tag 的源码构建；若修改，修改部分需按 LGPL 提供源码。
3. **声明与文本**：在 `THIRD_PARTY_NOTICES.md` 增加 EasyTier（LGPL-3.0）、其依赖（Rust crates）与版权信息；随包提供 LGPL-3.0 全文。
4. **源码获取**：在 `SOURCE.md` 注明 EasyTier 版本（tag）、源码地址、构建脚本与编译参数。
5. **可替换性**：文档说明如何重建 `.so` 并重新打包 APK；不要用静态链接或混淆手段阻止替换。
6. **Kotlin 门面**：若直接复制上游 `EasyTierJNI.kt`，该文件按 LGPL-3.0 处理，保留版权头；更稳妥的做法是只保留必要的 native 方法声明，并在 notices 中说明。
7. **商业分发**：若后续闭源商业发布，建议法务确认；必要时改为独立进程/独立 APK 形态。

与 Tailscale 的 BSD-3-Clause 相比，这是本方案最主要的非技术成本；已确认接受，但需把上述条目纳入发布检查清单。

---

## 11. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| LGPL-3.0 | 分发义务、商业合规 | 独立 `.so`、不修改、声明 + 源码获取、可替换；商业前法务确认 |
| APK 体积 | 35MB → 50–60MB | v1 单 APK 共存为已确认方案；`strip`/LTO/`opt-level=z`；裁剪未用特性；后续确定替代 Tailscale 后体积可回落；暂不做 flavor |
| 双后端维护 | 两套原生库、两套配置入口 | v1 共存验证；稳定后删除 Tailscale 或再评估 product flavor |
| 16KB 页对齐 | Android 15+ 设备加载失败 | NDK r28+ / `max-page-size=16384`；CI 校验 ELF 与 APK |
| 移动 FFI 演进 | 升级破坏 API | 固定 tag；JNI 收敛到 `EasyTierManager`；升级跑互通回归 |
| Rust panic/abort | 进程被杀 | 调用点 `try/catch`；记录 `getLastError()` 与 logcat；关键路径兜底 |
| 后台存活 | 进程回收后组网断开 | 与 tsnet 相同；v2 可加前台服务 |
| 本地 SOCKS5 无认证 | 同机其它 App 可借用隧道 | 只绑 `127.0.0.1`；随机高位端口；实例随连接生命周期；不长期常驻 |
| 公共节点依赖 | 节点不可用/UDP 被封 | 正式默认自建 public node；公共共享节点仅 spike 使用；失败提示可切换 |
| 自建节点运维 | 需维护一个公网节点 | 复用现有 VPS；节点只做中转/发现，不承载控制面 |
| 共享密钥模型 | 无设备级 ACL/审计 | 自用可接受；多设备用 secure mode/credential，或继续 Tailscale |
| 配置 schema 漂移 | 启动失败 | 以固定 tag 的 `toml.rs` 为准；启动前 `parseConfig` 校验 |
| 虚拟 IP 规划 | 目标主机不在同网段 | UI 提示网络名/密钥需一致；默认 DHCP；文档说明 Windows 端加入方式 |
| Windows 端接入 | 用户不会配 | README 增加 Windows 安装、加入网络、查看虚拟 IP 的步骤 |
| 多实例残留 | 旧实例占用端口 | 切换配置先 `deleteNetworkInstance`；固定实例名 |
| FreeRDP SOCKS5 兼容性 | 连接失败 | spike 阶段先用 `curl --socks5`，再端到端 RDP；必要时退回 Port Forward |

---

## 12. 验收标准

**构建**

- APK 含 `lib/arm64-v8a/libeasytier_android_jni.so` 与 `lib/arm64-v8a/libeasytier_ffi.so`。
- APK 同时保留 tsnet 的 `libgojni.so`（v1 共存）。
- 两个 EasyTier `.so` LOAD 段 16KB 对齐；`zipalign -c -P 16` 通过。
- v1 不新增 VPN/通知权限。

**功能**

- 连接绑定 EasyTier 配置后，不弹 `VpnService` 授权。
- EasyTier 实例进入 running，虚拟 IP 非空，SOCKS5 端口可连通。
- FreeRDP 通过 `/proxy:socks5://127.0.0.1:<port>` 成功连接 Windows 虚拟 IP 的 3389。
- 自建 public node 可用；公共共享节点仅作为备用/对比。
- 直连、Tailscale 连接无回归。

**健壮性**

- Wi-Fi ↔ 蜂窝切换后可重连。
- 应用重启后可重新启动实例。
- 配置错误（网络名/密钥/peer 非法）能显示明确错误。
- SOCKS5/监听端口冲突时能换端口重试。
- 切换配置时旧实例被正确停止。

**合规**

- `THIRD_PARTY_NOTICES.md`、`SOURCE.md` 已更新，包含 LGPL-3.0 文本与源码获取方式。

---

## 13. 实施顺序

1. **Spike**：固定 tag 构建两个 `.so`，真机验证 `no_tun + socks5_proxy`；先用公共共享节点跑通 `curl --socks5` 与 FreeRDP，再用自建 `easytier-core` public node 复测。
2. **构建流水线**：`build-easytier-so.sh`、jniLibs 打包、16KB 校验、CI 产物校验。
3. **数据层**：DB v5、`EasyTierConfigEntity/Dao`、`connections.easytierConfigId`。
4. **Manager**：TOML 生成、端口分配、启动/停止、就绪轮询、错误回传。
5. **Connector**：`RdpConnector` 增加 EasyTier 分支，处理互斥与失败提示。
6. **UI**：EasyTier 配置页、连接编辑页“组网方式”、主菜单入口。
7. **加固**：网络切换、端口冲突、实例清理、日志与状态。
8. **合规与发布**：notices/source、许可文本、体积评估、release 校验；补充自建 public node 的部署步骤。

每步完成后跑一次 `scripts/build-app.sh release` 与真机冒烟，避免最后集中排错。

---

## 14. 已确认决策（2026-11-18）

| # | 决策 | 结论 |
| --- | --- | --- |
| 1 | 共存还是替代 | **v1 与 Tailscale 共存（单 APK）**；验证稳定后再评估是否替代 |
| 2 | 是否接受 LGPL-3.0 | **接受**，按 §10 执行合规 |
| 3 | 公共节点还是自建 | **spike 用公共共享节点，正式默认自建 public node**（优先复用现有 VPS） |
| 4 | 是否需要 TUN 全局模式 | **v1 不做**，保留 v2 设计入口 |

### 14.1 共存而不是立即替代

- **结论**：v1 单 APK 同时保留 Tailscale 与 EasyTier；连接配置三选一（直连 / Tailscale / EasyTier）。
- **理由**：Tailscale 已实现、可回退；EasyTier 的移动 FFI、NAT 穿透与长时间稳定性仍需真机验证；先共存便于 A/B 对比。
- **代价**：APK 预计 50–60MB；两套原生库、两套配置入口需要同时维护。
- **后续**：连续验证 Wi-Fi/蜂窝切换、对称 NAT、长时间稳定后，若 EasyTier 满足需求，再删除 tsnet，体积可回落；暂不引入 product flavor。

### 14.2 接受 LGPL-3.0

- **结论**：接受 EasyTier 的 LGPL-3.0。
- **理由**：项目自身 Apache-2.0 且源码公开；EasyTier 以独立 `.so` 动态链接、不修改上游；合规成本主要是 notices、源码获取方式与可替换性说明。
- **边界**：若未来闭源商业分发，重新评估；必要时改为独立进程/独立 APK 形态。

### 14.3 spike 用公共节点，正式自建

- **结论**：spike 阶段使用 EasyTier 公共共享节点快速验证；正式默认自建 `easytier-core` public node，优先复用现有 Headscale VPS。
- **理由**：公共节点不可控，可能限速、被封或不可用；自建节点只承担中转/发现，不引入 Headscale 那样的控制面，运维成本低。
- **影响**：配置页 `peers` 默认填自建节点；README/文档补充 VPS 部署步骤；公共节点作为备用与对比项。

### 14.4 v1 不做 TUN 全局模式

- **结论**：v1 只用 `no_tun + socks5_proxy`；TUN 作为 v2 可选项。
- **触发条件**：其它 App 需要访问虚拟网、需要 UDP/ICMP，或 FreeRDP 的 SOCKS5 路径出现无法解决的兼容性问题。
- **影响**：v1 Manifest 不新增 VPN/通知权限；`EasyTierManager` 预留“返回代理地址”的接口，未来可用 TUN 后端替换实现。

---

## 附录 A：EasyTierJNI API 映射

| Java/Kotlin 方法 | 作用 | v1 使用 |
| --- | --- | --- |
| `parseConfig(config)` | 校验 TOML | 是 |
| `runNetworkInstance(config)` | 启动实例 | 是 |
| `deleteNetworkInstance(name)` | 停止指定实例 | 是 |
| `retainNetworkInstance(names)` | 保留指定实例，停止其它 | 可选 |
| `collectNetworkInfos(maxLength)` | 查询运行信息（JSON） | 是 |
| `listInstances(maxLength)` | 列出实例名/ID | 调试 |
| `callJsonRpc(service, method, domain, payload)` | 调 RPC（如 PatchConfig） | 否（v2 Port Forward/动态配置） |
| `getLastError()` | 最近错误 | 是 |
| `setTunFd(name, fd)` | 绑定 TUN fd | 否（v2 TUN） |
| `startConfigServerClient(...)` | 配置服务器客户端 | 否 |

## 附录 B：TOML 字段速查

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `instance_name` | string | 实例名，v1 固定 `peerrdp` |
| `hostname` | string | 节点主机名 |
| `dhcp` | bool | 自动分配虚拟 IP |
| `ipv4` | string | 固定虚拟 IP（dhcp=false） |
| `listeners` | array<string> | 监听 URI，自动分配端口 |
| `socks5_proxy` | string(URL) | `socks5://127.0.0.1:<port>` |
| `network_identity.network_name` | string | 网络名 |
| `network_identity.network_secret` | string | 网络密钥 |
| `[[peer]].uri` | string(URL) | 对等节点/公共节点 |
| `flags.no_tun` | bool | v1 固定 `true` |
| `flags.enable_encryption` | bool | 默认 `true` |
| `flags.mtu` | int | 默认 1380 |

## 附录 C：参考资料

| 资料 | 用途 |
| --- | --- |
| https://github.com/EasyTier/EasyTier | 源码、release、LICENSE |
| https://github.com/EasyTier/EasyTier/tree/main/easytier-contrib/easytier-android-jni | Android JNI 门面与构建脚本 |
| https://easytier.cn/guide/network/no-root.html | 无 TUN 模式与主动访问 |
| https://easytier.cn/guide/network/socks5.html | SOCKS5 服务 |
| https://easytier.cn/guide/network/port-forward.html | Port Forward（备选） |
| https://easytier.cn/guide/network/configurations.html | 完整配置项 |
| https://easytier.cn/guide/network/config-file.html | 配置文件加载 |
| https://deepwiki.com/EasyTier/EasyTier/8.5-mobile-and-embedded-platforms | Android/移动端集成概览 |
| https://developer.android.com/guide/topics/connectivity/vpn | VpnService（v2 TUN 参考） |
| https://developer.android.com/guide/practices/page-sizes | 16KB 页适配 |
