# 更新日志

本项目的所有重要变更都记录在此文件中。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
发布产物由 GitHub Actions 在推送 `v*` tag 时自动构建并附加 APK。

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
