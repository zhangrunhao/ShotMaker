# ShotMarker 质量状态

- 最后复核：2026-09-10
- 验证代码：`da129c1`；沿用的独立验证范围在表中注明
- 工程版本：1.3（Build 3）

## 当前结论

可编辑集锦任务、数据世代重置、停止语义、文件事务及媒体生命周期已有自动测试和真实媒体 Simulator 证据。完整 iPhone、Watch 测试及干净 Release Simulator 构建通过。真机、VoiceOver 和线上链路未验证，不记录为通过。

## 已验证

| 范围 | 环境 | 日期 | 结果 |
| --- | --- | --- | --- |
| iPhone 完整测试 | iPhone 17 Pro / iOS 26.5 Simulator | 2026-09-10 | 393 通过，0 失败，0 跳过；含 14 项 UI 测试 |
| 连续确认真实媒体 UI | 真实任务 Store/Session、AVPlayer 和帧提取 | 2026-09-10 | 合并片段 1–3 → 片段 4（691.1 秒）→ 另一来源 → 返回重开均通过；定位、8 帧胶片、手柄位置及播放推进正确 |
| Watch 完整测试 | Apple Watch Series 11 46mm / watchOS 26.5 Simulator；`1975784` | 2026-09-10 | 31 通过，0 失败，0 跳过；本次导航修复未改动 Watch 代码 |
| Release 构建 | generic iOS Simulator；本次增量构建 | 2026-09-10 | 成功；主 App/Watch 均为 1.3（3），dSYM UUID 对应；全新 DerivedData 构建的最近验证代码为 `1975784` |
| Release 边界 | App/Watch 二进制及 App 包 | 2026-09-10 | 三个 DEBUG 入口、真实媒体测试场景及计数观测均不在产物中；Privacy Manifest 存在，Tracking=false，无后台生成模式 |
| 真实视频导出 | AVFoundation + 真实文件 | 2026-09-10 | 41 秒成片修改后替换为 26 秒，旧文件清理，重载与外部源保护通过 |
| 数据升级与交互 | 专用 iPhone Simulator 原生入口及沙盒核验 | 2026-09-10 | 创建恢复、独立任务、编辑、停止/后台/进程终止、播放/保存、删除和一次性升级通过；具体覆盖方式见验证记录 |
| Git 文本检查 | git diff --check | 2026-09-10 | 通过 |
| 正式签名 Archive / Organizer Validate | 1.2（Build 1） | 2026-08-19 | 最近已知成功；未作为当前代码验收 |

完整命令、结果包、规格 20 项验收对应的证据和执行方式见 [任务验证记录](../archive/2026-09/2026-09-10-editable-highlight-task-validation.md)。表中没有把自动测试替代项宣称为人工操作。

连续确认黑屏与时间轴错位的复现、修复和当前完整测试结果见 [导航修复验证](../archive/2026-09/2026-09-10-clip-review-navigation-validation.md)。用户原始视频所在真机尚未复测。

## 当前覆盖

- 保留全部既有训练、同步、视频准备、范围/编号/合并、播放、导出、相册、日志、GlitchTip、Analytics 和隐私契约回归。
- 新增任务 schema、训练身份隔离、revision/无变化事务、损坏和未来版本保护、文件复制/回滚/补回、配置协调、队列互斥、迟到回调、后台及运行中刷新边界。
- 输出移动/提交/清理与 Photos 保存的失败注入验证稳定成片和事件边界。
- 缩略图保留上限为 64 项，退出弱引用 AVAsset 释放及帧数据清理已有测试；真实流程无逐片段导出。
- 14 项 UI 回归包括 4 项任务操作/最大字号、5 项片段确认、1 项真实媒体连续确认导航、4 项真实时间轴拖动。连续导航用例通过正式任务与媒体组件加载合成 H.264 文件，包含 720 秒横屏和 40 秒竖屏来源。
- 真实原生流程使用 640×360 H.264/AAC、360×640 无音轨和额外 3840×2160 测试视频；均为合成数据。
- iPhone 实际模拟旧 epoch 升级验证业务文件、缓存、临时文件及偏好清理，Photos 保留，第二次启动保留新数据和固定 cutover。
- Watch 真实临时目录测试验证 outbox 世代重置；手机同步测试覆盖旧/等于 cutover 载荷只 ACK 和新载荷正常导入。

## 现有风险和未覆盖

- 没有当前代码的真机完整回归、VoiceOver 人工验收、TestFlight 安装或 App Store Connect 当前状态验证。
- 没有当前代码的正式签名 Archive、Release Analytics 生产验收、真机崩溃符号化及 GlitchTip 告警验收。
- Watch 真机联机升级流程未执行；自动测试结论不代替它。
- 没有 iPad 功能验收、快照测试、XCTest Plan 或仓库内 CI。
- SwiftLint 最近记录为 2026-08-18：42 个 violation、其中 5 个 error，均为 type_body_length。本次没有重跑，不能据旧记录断言当前数量。
- Release 仍有既有播放观察者 Sendable 警告及无 AppIntents 依赖时的 metadata 提取提示，构建不是 warning-free。

## 验证规则

- 测试、构建和外部服务结论必须注明日期及代码范围。
- Simulator dSYM 只证明构建配置，不替代正式 Archive dSYM。
- 外部状态没有当次核验时，仅保留最后日期或标为未确认；完整私有证据由独立私有台账维护。
