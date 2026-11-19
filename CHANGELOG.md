# 更新日志

本项目的所有重要变更都记录在此文件中。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
发布产物由 GitHub Actions 在推送 `v*` tag 时自动构建并附加 APK。

## [2.3.7] - 2026-11-19

### 修复
- 回退剪贴板粘贴为 Java 方式（`sendClipboardData` + Ctrl+V via `processVirtualKey`），native `pasteTextViaClipboard` 在 VRDP 上无法完成粘贴（仅出数字）；保留 PasteThread 后台执行避免阻塞 UI，并加 50ms（剪贴板→Ctrl+V）+ 200ms（Ctrl+V→下一次）延迟缓解次序问题

### 构建
- 重编 freeRDPCore AAR（补丁 11/11：SessionInputManager 粘贴改回 Java 方式）

## [2.3.6] - 2026-11-19

### 修复
- 修复 VirtualBox VRDP 上中文输入只出数字的问题：`pasteTextViaClipboard` 阻塞 UI/IME 线程（最多 2 秒）导致输入法行为异常、粘贴失败；改由独立 `HandlerThread` 后台线程执行粘贴，UI 线程立即返回

### 构建
- 重编 freeRDPCore AAR（补丁 11/11：SessionInputManager 新增 PasteThread 后台线程）

## [2.3.5] - 2026-11-19

### 修复
- 修复 VirtualBox VRDP 等服务器上剪贴板粘贴失败：cliprdr 通道的 FormatList 与输入通道的 Ctrl+V 跨通道乱序，服务器可能先处理 Ctrl+V 再收到 FormatList，导致远端粘贴时无剪贴板数据；现 `pasteTextViaClipboard` 先等待服务器 `FormatListResponse` 确认再发送 Ctrl+V

### 构建
- 重编 freeRDPCore AAR（native 新增 `pasteFormatListAckEvent` 跨通道同步）

## [2.3.4] - 2026-11-19

### 修复
- 修复受控机无法输入：ASCII 可打印字符恢复走扫描码（所有服务器均支持），不再全部强制剪贴板粘贴；仅非 ASCII 文本（中文等）在服务器不支持 Unicode 键盘事件时走剪贴板粘贴
- 修复 VirtualBox VRDP 等服务器上连续输入中文次序错乱：RDP 剪贴板为懒投递，服务器在远端应用粘贴时才回拉数据，连续写入会互相覆盖；改为 native 层投递确认同步——`pasteTextViaClipboard` 写剪贴板 + Ctrl+V 后阻塞等待 `server_format_data_request` 确认服务器已收到数据，确认后才返回，杜绝后一次覆盖前一次

### 构建
- 修复 `build-freerdpcore-aar.sh` 增量构建失败：rsync 未排除 `freeRDPCore/src/main/cpp/external`，openssl 源码被 `--delete` 清掉而 `.cxx` stamp 仍在，cmake 跳过解压直接 configure 失败；已加排除项
- 重编 freeRDPCore AAR（native 新增 `pasteDeliveredEvent` 同步机制，补丁 11/11 更新 `SessionInputManager` commitText 逻辑）

## [2.3.3] - 2026-11-19

### 修复
- 所有可打印文本（ASCII 与非 ASCII）统一走「写剪贴板 + Ctrl+V」上屏，不再区分 ASCII/非 ASCII：避免受控端开启中文输入法时，ASCII 扫描码被远端 IME 拦截组词导致输入异常；仅回车、制表符等控制字符仍走虚拟键

### 构建
- 重编 freeRDPCore AAR（补丁 11/11 更新：`SessionInputManager` 简化 commitText 逻辑）

## [2.3.2] - 2026-11-19

### 修复
- 修复 VirtualBox VRDP 等服务器上中文仍无法输入的问题：不再依赖 `isUnicodeInputSupported` 判断（部分服务器即使声明 `INPUT_FLAG_UNICODE` 也不真正处理 Unicode 键盘事件），非 ASCII 文本统一走「写剪贴板 + Ctrl+V」上屏
- 剪贴板粘贴增加 50ms 延时与队列：确保服务器已处理剪贴板格式列表后再触发粘贴，连续上屏时避免后一次剪贴板内容覆盖前一次

### 构建
- 重编 freeRDPCore AAR（补丁 11/11 更新）

## [2.3.1] - 2026-11-19

### 修复
- 修复在不支持 Unicode 键盘事件的 RDP 服务器（如 VirtualBox VRDP）上无法输入中文等非 ASCII 文本的问题：服务器能力协商会关闭客户端的 Unicode 输入，原扫描码回退无法表示 CJK 字符导致被丢弃；现检测到服务器不支持 Unicode 键盘输入且提交文本含非 ASCII 字符时，回退为「写入共享剪贴板 + Ctrl+V」上屏（剪贴板通道在这些服务器上始终可用）

### 构建
- 重编 freeRDPCore AAR（补丁 11/11 更新：`SessionInputManager` 新增剪贴板粘贴回退）

## [2.3.0] - 2026-11-19

### 新增
- 新增「问题反馈」入口（主界面菜单 → 问题反馈）：填写问题/需求描述与联系方式，可附带设备信息、logcat 与应用日志文件，经系统分享或邮件发送

### 修复
- 修复客户端输入法文本无法上屏：FreeRDP 默认关闭 Unicode 输入，连接现显式传入 `/kbd:unicode:on`，中文等非 ASCII 提交才能发送到远端
- 修复远端输入法失效：输入法提交的可打印 ASCII 恢复为扫描码发送，远端输入法组词与浮层键盘锁定的 Ctrl/Win 组合键（如 Ctrl+Space）继续生效
- 输入法提交的回车/制表符改为发送真实按键；`SessionView` 声明 `onCheckIsTextEditor`，输入法附着更稳定

### 构建
- 重编 freeRDPCore AAR（补丁 11/11 更新）

## [2.2.0] - 2026-11-19

### 新增
- 移动端文本输入不再依赖服务器输入法：客户端输入法在本地组词，提交后的文本以 RDP Unicode 按键事件发送到远端
  - 退格/向后删除发送 `VK_BACK` / 扩展 `VK_DELETE`，输入法回车发送 `VK_RETURN`
  - 组词与候选框保留在客户端，仅上屏文本进入远端
- 连接编辑新增更大分辨率：2560×1600、2880×1800、3440×1440、3840×2160

### 构建
- `scripts/build-freerdpcore-aar.sh` 新增补丁 11/11（`SessionView` / `SessionInputManager` 客户端文本输入），并重编 freeRDPCore AAR

## [2.1.2] - 2026-11-19

### 安全
- 升级 FreeRDP 3.33.0 → 3.33.1，修复 11 个安全公告（含客户端侧 use-after-free、越界读等）
- 升级 uriparser 1.0.2 → 1.0.3，修复 CVE-2026-48841（`ComposeQueryEngine` 整数溢出），并重编 freeRDPCore AAR
- 关闭 `allowBackup`，避免包含 RDP 密码、Tailscale pre-auth key、EasyTier 网络密钥的数据库随系统备份外泄
- 引擎 AAR 合并的 6 个导出组件（含带 `freerdp://` BROWSABLE intent-filter 的 SessionActivity）改为不导出

### 修复
- 修正 EasyTier 原生库版本：此前 `.so` 实际为 v2.6.4，现按 v2.7.1 源码重编（版本串 `EasyTier-v2.7.1`）
  - v2.7.1 的 JNI 库改为静态链接 `easytier-ffi`，两个 `.so` 与 APK 体积相应增大

### 构建
- `scripts/build-freerdpcore-aar.sh` 默认 FreeRDP 改为 3.33.1、uriparser 改为 1.0.3
- README/BUILD/SOURCE/THIRD_PARTY_NOTICES/设计文档同步引擎版本与重编日期

## [2.1.1] - 2026-11-19

### 变更
- 升级 EasyTier 至 v2.7.1（JNI 常量、`scripts/build-easytier-so.sh`、README/SOURCE/THIRD_PARTY_NOTICES 同步）

### 修复
- 移除主界面 Tailscale 配置悬浮按钮（配置入口统一收敛到连接编辑页）

### 构建
- `scripts/*.sh` 补齐可执行位（原先以 100644 提交，直接 `./scripts/xxx.sh` 会报权限不足）
- `tsnet-android/` 归档 gobind 生成的 Java 源码 jar

## [2.1.0] - 2026-11-18

### 新增
- 集成 EasyTier 组网：`no_tun=true` + 应用内 SOCKS5 模式，不申请 VpnService 权限，可与 Tailscale 方案共存
- `docs/easytier-integration-design.md` 集成设计文档

## [2.0.1] - 2026-11-09

### 修复
- freeRDPCore 剪贴板 Provider authority 改为 `com.peerrdp.freerdpcore.clipboard`，
  修复与其它内嵌 freeRDPCore 的应用共存安装时报 `INSTALL_FAILED_CONFLICTING_PROVIDER(-13)`

## [2.0.0] - 2026-11-08

### 变更
- 项目由 AnRDP 更名为 PeerRDP：`applicationId` 由 `com.anrdp` 改为 `com.peerrdp`，
  与 v1.0.1 属不同应用，**无法覆盖升级，需先卸载旧版**

### 新增
- 集成 Tailscale（tsnet）：RDP 连接可经 tailnet 虚拟网络建立
- `docs/n2n-integration-design.md` 集成设计文档

### 构建
- tsnet wrapper（Go module）源码入库，新增 `scripts/build-tsnet-aar.sh`
- tsnet AAR 体积优化：`-s -w`、`-trimpath`、`ts_omit_*` 特性裁剪
- release 签名支持回退读取 `../peerrdp-secrets/keystore.properties`
- 修复状态栏图标在白色背景下不可见

## [1.0.1] - 2026-11-08

### 变更
- 首个使用固定 release 签名密钥的发布（可长期覆盖升级）

## [1.0.0]

首个版本（标记为已撤销：当时 CI 未注入签名密钥，产物为临时 debug 签名，无法覆盖升级，Release 与 tag 已删除）。
