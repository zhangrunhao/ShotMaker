# 可编辑集锦任务实施计划

> 执行方式：用户已指定 inline；使用 `superpowers:executing-plans` 在当前任务内按清单实施、测试和复核，不派发子代理。

**目标：** 进入审核即形成独立任务，任务持续可编辑，生成执行可停止，重新生成安全替换当前成片。

**架构：** `HighlightTaskStore` actor 是任务文档唯一写入者；`HighlightTaskManager` 协调纯规划、文件事务和串行执行。保留已有视频准备、范围编辑和单 composition 导出能力，审核持久化改为任务 revision 事务。共享启动重置协调器在任何业务服务初始化之前完成数据世代切换。

**技术：** Swift 5 语言模式、SwiftUI、Foundation actor、AVFoundation、PhotoKit、WatchConnectivity、XCTest；沿用当前依赖和平台下限。

**规格：** [已确认规格](2026-09-03-editable-highlight-task-spec.md)

## 全局约束

- iOS 26.4、watchOS 26.2；不调整发布版本与 Build。
- 不迁移旧数据；`currentDataEpoch = 1`，首次进入该世代完整清理本地 App 数据。
- 重置不访问 Photos、HealthKit 或沙盒外文件；iPhone 重试必须复用首次 cutoverAt。
- 任务训练快照不保存原训练或原打点 ID；每次新建流程随机任务身份，视频数量 1–20。
- 配置成功一次事务只递增一次 revision；无变化不写盘；活动执行时禁止配置、播放、保存和删除。
- 原范围规则保留：前 9 秒、后 4 秒、1 秒相邻合并、0.1 秒与 timescale 600 规范化。
- 所有文件路径是受控相对路径；输出先写新 UUID 目录，再提交引用，提交成功后才清理旧输出。
- 退出审核释放所有媒体资源；后台停止执行；不引入后台生成。
- 不增加 Analytics 事件或远端字段，不记录媒体身份、任务/执行 ID 或绝对路径。
- 自动测试与实际 Simulator 媒体验证分别记录；不把未执行的真机或外部验证写成通过。

## 1. 数据世代与同步边界

文件：新增 `Shared/AppDataResetCoordinator.swift`、`ShotMarkerTests/AppDataResetCoordinatorTests.swift`、`ShotMarkerWatchAppTests/WatchDataResetTests.swift`；修改两个 App 入口、`PhoneWatchSyncService.swift`、`TrainingSessionImporter.swift`。

接口：`AppDataResetCoordinator.resetIfNeeded() throws -> Date?`，可注入沙盒根目录、UserDefaults domain、时钟及文件删除动作；`PhoneWatchSyncService` 接收固定 `dataCutoverAt`，在导入及内容日志之前 ACK 丢弃旧载荷。

- [x] 写出真实临时目录测试：旧文件与设置消失、第二次启动保留新数据、失败重试沿用切割时间、Watch outbox 清空。

```swift
let cutover = try coordinator.resetIfNeeded()
try Data("new".utf8).write(to: newBusinessFile)
XCTAssertEqual(try coordinator.resetIfNeeded(), cutover)
XCTAssertTrue(FileManager.default.fileExists(atPath: newBusinessFile.path))
```

- [x] 运行对应测试，确认缺少实现的失败；实现固定 reset journal、清理顺序、成功后 epoch 写入和阻塞重试页。
- [x] 给旧／新 Watch payload 添加边界测试，覆盖等于 cutover 被 ACK 丢弃且没有 Analytics。
- [x] 运行 iPhone 与 Watch 对应测试；确认同步／日志／Analytics／GlitchTip 依赖只在重置成功后创建。

## 2. 任务模型、状态和 actor Store

文件：新增 `ShotMarker/Models/HighlightTask.swift`、`ShotMarker/Models/HighlightTaskState.swift`、`ShotMarker/Services/HighlightTaskStore.swift`、模型与 Store 测试；使共享值类型明确可跨 actor 传递。

接口：严格区分 `HighlightTask`、`HighlightTaskTrainingSnapshot`、`HighlightTaskVideo`、`PersistedHighlightTaskClip`、`HighlightRenderSnapshot`、`HighlightRenderExecution`、结果与当前输出。Store 提供 `create`、`updateConfiguration`、`installExecution`、`updateProgress`、`finishExecution`、`savePhotoResult`、`delete`、`loadForLaunch`；每个配置写入使用 expectedRevision，每个执行写入匹配 task/execution/revision 三元组。

- [x] 写 JSON 往返、训练身份隔离、状态权限、无变化更新、stale revision、失败不发布、停止/完成先到者生效的测试。

```swift
let updated = try await store.updateConfiguration(id: task.id, expectedRevision: 1,
    videos: task.videos, settings: changedSettings, items: task.reviewItems)
XCTAssertEqual(updated.configurationRevision, 2)
await XCTAssertThrowsErrorAsync(try await store.updateConfiguration(
    id: task.id, expectedRevision: 1, videos: task.videos,
    settings: task.clipSettings, items: task.reviewItems))
```

- [x] 实现 schema 1 原子文档；未知高版本只读，损坏备份后报告错误并禁止孤立文件清理；启动遗留执行转 stopped。
- [x] 跑模型与 Store 测试，检查输出保存状态不改变 revision，活动执行操作集合严格为停止。

## 3. 任务文件与规划协调

文件：新增 `HighlightTaskFileStore.swift`、`HighlightTaskPlanner.swift` 及对应测试；必要时扩展既有 planner 的稳定打点顺序输入。

接口：文件层 `prepareInputs` 返回稳定视频与本次新增文件集合，`commitCreation` 完成 staging 改名；`moveOutput` 使用新 output UUID；清理只接受明确 task/execution 身份或可靠文档引用。规划层 `makeTask`、`reconcile`、`reviewDraft`、`renderSnapshot`。

- [x] 写真实文件测试：相册不复制，文件复制后对副本流式计算 SHA-256，创建失败清理，视频更新失败保留旧文件，相对路径越界及符号链接拒绝。
- [x] 写规划测试：初始范围、同时间 sourceOrder、换序改变映射、确认项保留/重置计数、多字段最终值事务、默认基线更新、样式不重排、全部重置。

```swift
let result = try HighlightTaskPlanner.reconcile(task: confirmedTask,
    videos: confirmedTask.videos, settings: ClipSettings(secondsBeforeMarker: 3, secondsAfterMarker: 2))
XCTAssertEqual(result.items.first?.start, 7)
XCTAssertEqual(result.items.first?.defaultStart, 7)
XCTAssertEqual(result.items.first?.confirmationState, .confirmed)
```

- [x] 实现任务本地身份和明确确认保留规则；确认打点占位分隔默认规划，避免重复打点或跨排除项合并。
- [x] 跑文件、规划及原片段范围/编号回归。

## 4. Manager、Runner、停止和成片提交

文件：新增 `HighlightTaskManager.swift`、`HighlightRenderRunner.swift` 及测试；修改 `VideoClipEditingService.swift` 以支持执行独有输出路径并可靠清理取消输出。

接口：Manager 提供 `createTask`、`updateConfiguration`、`confirmClip`、`resetClips`、`start`、`restart`、`stop`、`stopAllExecutions`、`delete`、`saveToPhotoLibrary`。Runner 只接收 `HighlightRenderExecution` 的不可变输入与输出 URL，返回一个临时 MOV；回调携带执行三元组。

- [x] 写可控制挂起/不合作导出的队列测试，确认停止落盘先于取消，取消完成前不会启动下一项，迟到成功/进度不改变任务。

```swift
try await manager.stop(taskID: first.id)
XCTAssertEqual(manager.tasks.first { $0.id == first.id }?.state, .stopped)
XCTAssertEqual(controlledExporter.startedCount, 1)
controlledExporter.finishCancelledRun()
await waitUntil { controlledExporter.startedCount == 2 }
```

- [x] 写移动失败、JSON 提交失败、成功替换、旧输出清理失败与相册保存测试；使用真实文件及 Store，只有外部导出/Photos 边界替身。
- [x] 实现先落盘再入队；后台先禁止调度再停止全队列；不合作 Runner 必须退出与清理后才释放串行槽。
- [x] 将生成成功事件绑定原子输出引用提交，将相册事件绑定实际 Photos 成功；错误使用封闭码。
- [x] 跑 Manager/Runner 与已有导出/Photos 测试。

## 5. 配置、审核与首页集成

文件：改造 `TrainingSessionHighlightView.swift` 为可复用的新建/任务配置表单；新增 `HighlightTaskEditorView.swift`、`HighlightTaskRow.swift`、`HighlightReviewSession.swift`；修改审核 ViewModel/View、首页、ContentView 和 App 服务组装。

接口：新建表单冻结一次随机创建 ID，成功后继续同一任务；已有配置页以进入时 task revision 为草稿基线，提交后进入审核。审核 ViewModel 通过 `persistConfirmation` closure 提交任务事务，Store 成功后更新本地 revision 与导航。

- [x] 添加任务确认持久化、失败保留工作副本、媒体释放和配置草稿行为测试。
- [x] 新建下一步调用 create，已有下一步调用 update；提供增加/删除/换序、固定训练摘要、脏草稿放弃、重置全部二次确认和旧成片提示。
- [x] 审核使用任务中的全部卡片；“生成视频”和“退出到首页”统一释放播放器、缓存、请求与准备文件。
- [x] 首页从模型统一推导状态；排队与生成仅显示停止；删除要求破坏性确认。
- [x] 正式 App 不再初始化组合 Store 或旧 Job Manager，训练改动与任务不存在级联关系。
- [x] 保留已有审核/范围/视频准备测试覆盖，新增任务行可访问名称、操作与最大字号 UI 回归。

## 6. 完整验证与文档收尾

文件：`ShotMarkerUITests/EditableHighlightTaskUITests.swift`、必要的 DEBUG 媒体测试入口、`docs/current/` 相关事实和带日期验证记录。

- [x] 完整 iPhone 测试（原基线 342 项）和 Watch 测试（原基线 30 项），不得通过跳过回归降低覆盖。

```sh
xcodebuild test -project ShotMarker.xcodeproj -scheme ShotMarker \
  -destination 'platform=iOS Simulator,name=ShotMarker Editable Tasks QA' \
  -derivedDataPath /tmp/shotmarker-editable-tasks-dd \
  -resultBundlePath /tmp/shotmarker-editable-complete.xcresult
xcodebuild test -project ShotMarker.xcodeproj -scheme ShotMarkerWatchApp \
  -destination "platform=watchOS Simulator,id=$WATCH_SIMULATOR_ID" \
  -derivedDataPath /tmp/shotmarker-editable-watch-dd \
  -resultBundlePath /tmp/shotmarker-editable-watch-final.xcresult
```

- [x] 全新 DerivedData Release generic iOS Simulator 构建；核验 App/dSYM/Privacy Manifest、DEBUG 入口不进二进制。

```sh
xcodebuild build -project ShotMarker.xcodeproj -scheme ShotMarker \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/shotmarker-editable-verified-release-dd
git diff --check
```

- [x] 专用 Simulator 使用带打点、普通片段/合并片段和两段真实媒体，核验创建、退出恢复、任务隔离、编辑、停止、后台、重启、输出替换与删除；记录环境和实际结果。
- [x] inline 自审规格覆盖、文件事务、竞态、隐私、导航与清理；修正发现的问题并运行对应回归。
- [x] 更新 current 的实现事实与当次验证；再归档完成的规格和计划到对应月份，并修正入口链接。
- [x] 按实际改动使用中文 `feat:` / `fix:` / `docs:` 提交，保留本地开发分支供审阅，不推送或合并。

## 完成记录

- 2026-09-10 inline 实施完成，代码提交 `1975784`。
- 完整 iPhone 392 项、Watch 31 项通过，均无失败或跳过；干净 Release 构建、dSYM、Privacy Manifest 和 DEBUG 边界通过。
- 原生媒体、进程中断、一次性升级及自动补充的逐项证据见[验证记录](2026-09-10-editable-highlight-task-validation.md)。WATCH_SIMULATOR_ID 使用本机明确选择的 Watch，避免同名配对设备歧义。
- 真机、VoiceOver 和生产服务未验证；保留本地分支，不推送或合并。
