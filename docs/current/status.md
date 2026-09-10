# ShotMarker 当前状态

- 最后复核：2026-09-10
- 验证代码：`codex/editable-highlight-tasks` / `1975784`
- 工程版本：1.3（Build 3）
- 当前阶段：可编辑集锦任务已实施并完成 Simulator 验证；正式 Archive、真机和分发验收待执行

## 当前结论

ShotMarker 已覆盖 iPhone/Watch 训练同步、视频准备、长期可编辑集锦任务、逐片段审核、序数样式、串行生成、手动保存、本地日志及精简远端观测。任务在进入审核时创建并固定训练快照；生成可停止，修改后保留旧成片。新数据世代首次启动按已确认规格清理旧本地数据，不提供迁移。

## 已验证事实

- 完整 iPhone 测试 392 项、Watch 测试 31 项在 2026-09-10 通过，均无失败或跳过；保留全部既有回归。
- 同日全新 DerivedData 的 Release generic iOS Simulator 构建通过；App/Watch dSYM 对应、隐私清单存在、DEBUG 入口不进入产物。
- 专用 Simulator 的真实媒体流程验证任务创建/恢复/隔离、编辑、默认值和重置、实际播放/相册保存、主动/后台/异常退出停止、删除及数据世代升级。故障与文件边界由自动测试补充。
- 正式 App 不再使用旧任务 Manager 或组合确认 Store；训练后续删除/合并/导入与任务无级联关系。
- iPhone/Watch 当前 epoch 为 1；iPhone 使用固定 cutover ACK 丢弃旧 Watch 载荷，成功后的新数据继续保留。
- Release iPhone 会发送四个固定 Analytics 事件和 GlitchTip 错误/崩溃信息；当前没有登录、账号或业务云同步。

## 已确认但未实现

[iOS 语音口令打点与技术统计](../changes/2026-07-29-ios-voice-command-marking-spec.md) 已完成设计确认；当前没有语音识别、语音事件或球员统计能力。

## 发布前待办

- 披露本次升级会清理旧训练、任务、审核、App 内成片、缓存、日志和偏好；系统相册、HealthKit、外部导出及远端历史保留。
- 为当前代码生成正式签名 Archive，并执行真机、TestFlight、Analytics、崩溃符号化、告警与隐私披露验收。
- 当前正式 Archive/Organizer Validate 最近证据仍为 2026-08-19 的 1.2（Build 1）；外部状态没有在本次重新核验。
- VoiceOver、iPad 和 Watch 真机联机升级尚无当前验收证据；SwiftLint 当前数量未复核，最近记录仍为非绿色基线。

## 详细入口

- [产品事实](product.md)
- [技术架构](architecture.md)
- [产品埋点](analytics.md)
- [质量状态](quality.md)
- [发布状态](release.md)
- [任务验证记录](../archive/2026-09/2026-09-10-editable-highlight-task-validation.md)
