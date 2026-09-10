# ShotMarker 技术架构

- 最后复核：2026-09-10
- 代码范围：`da129c1`

## 运行单元

- ShotMarker：SwiftUI iPhone App；工程保留未验收的 iPad destination。
- ShotMarkerWatchApp：SwiftUI、HealthKit、WatchConnectivity。
- ShotMarkerTests：iPhone 单元、文件事务、媒体和服务测试。
- ShotMarkerUITests：时间轴拖动、片段确认、真实媒体连续导航及任务权限/配置/最大字号测试；三个 DEBUG 专用入口不进入 Release。
- ShotMarkerWatchAppTests：同步、outbox、运行时和数据世代重置测试。
- Shared：同步载荷及 `AppDataResetCoordinator`。

工具链为 Xcode 26.6、Swift 6.3.3，语言模式 Swift 5；iOS 下限 26.4，watchOS 下限 26.2。主 App 不配置 macOS、Mac Catalyst 或 visionOS destination。

## 启动和数据世代

`ShotMarkerBootstrap` 在构造任何业务、日志、Analytics、GlitchTip 或 WatchConnectivity 服务前执行数据世代事务。失败只显示阻塞重试页。Watch 也在重置成功后才构造同步服务。

- 当前 epoch 为 1；缺失或低版本触发清理，不迁移旧数据。
- iPhone 先将仅含目标 epoch 与固定 `dataCutoverAt` 的 journal 原子写入 Application Support/ShotMarkerReset/reset-state.json，再清理 ShotMarker 业务目录、Caches、tmp 和完整 UserDefaults domain。
- 成功写入 epoch 和切割时间后移除 journal。journal 优先于已写入 epoch，重试复用首次时间，不扩大旧载荷丢弃范围。
- Watch 清理自身 Application Support（含 outbox）、完整 UserDefaults、Caches、tmp，最后写入 epoch。
- 重置不访问 Photos/HealthKit 删除 API 或沙盒外目录。安装标识随偏好清理重新生成。
- 任务文档加载成功后才按引用清理孤立文件；损坏或未知版本文档不提供清理依据。

## 模型与持久化

- `TrainingSession` 保存 ID、训练起止和 `ShotMarkerEvent(id, markedAt)`；路径为 Application Support/ShotMarker/training-sessions.json。
- `HighlightTask` 拥有不可变训练快照、任务视频、`ClipSettings`、全部 `reviewItems`、活动执行、最近结果及当前成片。
- 新建快照使用新的任务本地打点 UUID、毫秒时间及稳定 `sourceOrder`，不保存原训练 ID 或原打点 ID；临时训练适配对象仅供纯规划和只读 UI。
- `HighlightTaskStore` actor 是 schema 1 的 highlight-tasks.json 唯一写入者。读取后校验、原子写盘，成功后才发布 UI。
- 配置更新校验 expectedRevision；有变化才递增一次，无变化不写盘。生成进度、结果及相册状态不改变配置 revision。
- 未知高 schema 只读保护；损坏文档改名保留并报告错误，后续启动仍不当作空文档清理文件。
- PhotoKit 来源使用稳定资源引用；文件来源流式 SHA-256 后放入 HighlightTasks/<task>/Inputs/<video>.<ext>。所有已选文件均归任务持有，包括当前未参与成片的来源。
- 文件只存受控相对路径，拒绝越界及符号链接。创建用 staging；更新先移动新增文件、提交 JSON 后才清理旧副本，失败回滚本次新增文件。
- 当前成片为 HighlightTasks/<task>/Outputs/<output>/highlight.mov；每次输出使用新的 UUID 目录。
- 旧 `HighlightJob` 和组合确认类型仍保留供旧契约回归，正式 App 不再实例化旧 Manager/Store，也不读取或迁移旧文档。训练服务默认不注入组合确认 Store。

## 任务与生成数据流

~~~text
训练 + 有序视频 + 设置
→ HighlightTaskPlanner.makeTask
→ 任务文件事务 + HighlightTaskStore.create
→ 任务配置 / HighlightReviewSession
→ expectedRevision 配置事务
→ HighlightRenderExecution（不可变快照）
→ HighlightTaskManager 全 App 串行调度
→ HighlightRenderRunner / VideoClipEditingService
→ 新输出移动 → 原子提交当前引用 → 清理旧输出
~~~

- `HighlightTaskPlanner` 复用默认范围规则；视频变化保留精确安全确认，确认项占位并分隔默认合并链；时长变化保留人工范围并更新默认基线，样式变化不规划。
- `HighlightReviewSession` 持有任务 revision、审核 ViewModel 和单一播放器，统一释放请求、AVAsset、播放器 item/观察者、帧数据和准备文件。
- 编辑器使用工作副本；Store 成功后更新卡片、汇总和连续导航，过期提交或写盘失败保留当前调整。
- 导航目标使用片段 UUID 作为编辑器视图身份；连续确认切换时重新初始化局部时间轴和媒体任务，旧片段的退出清理只作用于旧播放器及胶片请求。
- `HighlightClipReviewMediaProvider` 与 ViewModel 保留的缩略图数据均有上限；局部胶片退出时释放，审核不导出逐片段文件。
- 本地照片资源先校验可用，审核和生成关闭网络访问；下载由配置页明确准备流程承担。
- `HighlightRenderRunner` 只读取执行快照，使用已确认精确片段建立单一 AVMutableComposition/导出，并使用该执行独有临时目录。
- 活动状态统一推导操作集合为停止。停止先持久化执行失效，再取消；旧 Runner 真正退出和清理前不释放串行槽。
- 回调通过 task/execution/revision 门槛验证；迟到结果和进度不能覆盖停止或新执行。
- background 禁止调度并停止所有执行，inactive 不触发。启动将遗留执行改为 stopped，不自动恢复。
- 输出移动或 JSON 提交失败保留旧成片；新引用提交后再清理旧输出。删除先移除任务文档，再清理任务自有文件。
- `MarkerLabelLayout` 统一完整画幅、标签边界及坐标转换；导出显式接收样式，不访问全局设置 Store。

## Watch 同步

~~~text
Watch outbox → transferUserInfo → PhoneWatchSyncService
→ cutover 门槛 → TrainingSessionImporter → ACK → Watch 移除 outbox
~~~

- 同步入口在导入和内容日志前检查 payload.endedAt；小于或等于固定 cutover 的旧载荷只 ACK，不导入、不发送成功事件。
- 新载荷按训练 ID 幂等导入，成功写盘后、ACK 前记录同步成功事件。
- Watch 未激活、发送失败或等待 ACK 时保留 outbox 并重试。
- iPhone 提供同步诊断快照；Watch 没有独立日志导出。

## 日志与远端观测

- AppLogger 在本地写结构化 JSONL，保留 14 天、总量上限 30 MB；导出包含 manifest、设备/App 信息、日志和 iPhone 同步诊断。
- iPhone 通过官方 sentry-cocoa 9.26.0 源码产品 SentrySPM 对接 GlitchTip，业务适配层导入 SentrySwift；Watch 不链接 Sentry。
- AppLogger.error 同时发送精简错误事件；其他级别仅写本地。不开启性能追踪、Profiling、Session Replay 或自动 Session Tracking。
- 任务相关日志仅包含状态、计数、总时长及封闭错误类别；导出和相册错误不传递原 NSError 的来源信息，日志不记录片段起止范围。
- Analytics 仅在 Release iPhone 启用；生成成功事件在当前输出引用提交后，保存事件在实际 Photos 成功后发送，见 [产品埋点](analytics.md)。

## 有效隐私边界

- PrivacyInfo.xcprivacy 声明 Device ID、Product Interaction、UserDefaults 和文件时间戳用途；Tracking 为 false。本 Change 不增加数据类别或后台生成声明。
- 任务、训练、视频、帧、来源标识、摘要、UUID、文件名和绝对路径不进入 Analytics 或 GlitchTip metadata。
- GlitchTip 不配置用户身份，不上传训练、视频、截图或本地日志文件。客户端 DSN 可随 App 分发；管理令牌不得进入 Git。
- 训练与任务创建后无回查、同步或级联删除关系；完整契约见 [任务规格](../archive/2026-09/2026-09-03-editable-highlight-task-spec.md)。
