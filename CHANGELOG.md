# 更新日志

本项目的所有重要变更都记录在此文件中。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
发布产物由 GitHub Actions 在推送 `v*` tag 时自动构建并附加 APK。

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
