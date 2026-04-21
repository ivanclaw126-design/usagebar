# UsageBar

UsageBar 是一个原生 macOS 菜单栏应用，用来聚合查看多个 AI 编码服务的 coding plan / 配额使用情况。目前主要面向 Bailian、Z.ai Global 和 OpenAI Codex 这几类日常会频繁切换的订阅来源。

它的目标很直接：把分散在不同网页、CLI 和登录态里的剩余额度，统一收进菜单栏里，减少来回切窗口确认状态的成本。

## 功能特性

- 原生 SwiftUI 菜单栏应用，常驻 macOS 顶部状态栏
- 聚合展示 Bailian、Z.ai Global、OpenAI Codex 的使用状态
- 支持中英文界面切换
- 支持自动刷新，并为各供应商缓存最近一次快照
- Bailian 支持通过网页登录态抓取真实用量
- Z.ai Global 支持订阅信息与配额窗口监控
- OpenAI Codex 优先读取本地 `codex` CLI 登录状态，并提供网页登录兜底
- 凭据保存在 macOS Keychain 中

## 运行要求

- macOS 14 或更高版本
- Xcode（用于本地运行和调试）

## 本地运行

1. 用 Xcode 打开 [UsageBar.xcodeproj](/Users/spicyclaw/MyProjects/UsageBar/UsageBar.xcodeproj)
2. 选择 `UsageBar` scheme
3. 运行目标选择 `My Mac`
4. 启动后应用会出现在 macOS 菜单栏中

首次使用时，建议先在设置页连接至少一个供应商，再执行测试连接，确认菜单栏已经开始显示实时状态。

## 支持的连接方式

### Bailian

- 更适合通过网页登录态读取真实 coding plan 用量
- 可在应用内完成会话捕获

### Z.ai Global

- 支持 API Key
- 可读取订阅与额度相关信息

### OpenAI Codex

- 优先检测本机 `codex` CLI 登录状态
- 网页登录态作为有限兜底方案

## 项目结构

```text
Sources/UsageBar/App        应用入口与菜单栏生命周期
Sources/UsageBar/Models     数据模型
Sources/UsageBar/Providers  各平台用量读取与适配逻辑
Sources/UsageBar/Services   设置、凭据、缓存与会话管理
Sources/UsageBar/Views      菜单栏面板与设置界面
UsageBarTests               解析与状态存储相关测试
```

## Release 构建产物

当前本地 Release 构建输出路径：

`./.derived-release/Build/Products/Release/UsageBar.app`

## 说明

这是一个 macOS 原生工具项目，核心体验围绕“快速查看订阅余额”展开，因此会优先保证菜单栏状态展示、连接配置和自动刷新链路的稳定性。
