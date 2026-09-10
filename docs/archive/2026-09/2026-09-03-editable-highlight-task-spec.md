# ShotMarker 可编辑集锦任务与生成执行规格

- 日期：2026-09-03
- 状态：已实施，2026-09-10 完成本地验证；执行方式与边界见[验证记录](2026-09-10-editable-highlight-task-validation.md)
- 目标版本：不绑定发布版本；实施时单独决定版本号和构建号
- 设计基线：`main` / `b2c0371`
- 前置实现：[集锦片段审核与范围调整](2026-09-02-highlight-clip-review-spec.md)、[片段确认持久化与连续审核](2026-09-03-highlight-clip-confirmation-spec.md)

## 背景

当前实现把一次集锦流程拆成三个不同生命周期：训练记录独立持久化；视频选择和大部分审核状态属于当前页面；逐片段确认按“完整训练内容 + 严格有序视频组合”保存在共享 Store；只有用户最终点击“确认并生成”后才创建 `HighlightJob`。这使首页所称的“任务”只代表一次导出执行，而不代表用户从视频选择开始持续编辑的工作。

该模型存在以下产品断层：

- 用户点击“下一步：审核片段”后还没有一个可在首页恢复的独立任务。
- 相同训练和相同视频再次进入会复用共享片段确认，而不是形成独立工作。
- 已生成任务不能重新进入修改视频、默认时长、序数样式或片段。
- 当前取消生成会删除任务，不能表达“停止执行但保留工作”。
- 当前 App 重启把运行任务标为中断并允许恢复，与本规格确认的“不做后台生成、退出即停止”不一致。
- 逐片段确认与生成任务分别持久化，所有权不清晰，删除边界需要依赖组合身份协调。

本 Change 将“集锦任务”重新定义为长期、独立、可编辑的本地项目，并把一次视频生成定义为任务内部的不可变执行。点击“下一步：审核片段”即创建任务；任务保存固定训练快照、当前视频、设置和片段。生成、停止、再次编辑和重新生成都围绕同一任务进行。

## 当前实现差距

- `TrainingSessionHighlightView` 的视频选择和审核入口没有持久任务身份。
- `HighlightClipReviewStore` 以确定性组合键共享确认项，不能隔离相同输入创建的两次工作。
- `HighlightJob` 同时承担生成输入快照、执行状态和成片记录，但缺少可编辑配置。
- `HighlightJobManager.cancel` 会删除任务记录及所有任务文件。
- `HighlightJobStore.loadJobsForLaunchRecovery` 会把排队、运行或保存状态转换为 `interrupted`，而不是停止全部执行。
- `HighlightJobManager` 只保存最终引用的视频；被排除片段独占的视频不会进入任务，因此不能完整恢复编辑配置。
- 片段审核媒体缓存的清理边界依赖多个页面回调；从审核图集返回上级页面时不保证立即释放全部缓存。
- iPhone 与 Watch 没有统一的数据世代切割机制；清空手机数据后，Watch 旧 outbox 仍可能把旧训练重新同步回来。

## 已确认产品决定

1. 用户选定训练记录、一个或多个原始视频、默认时长和片段序数样式后，点击“下一步：审核片段”即创建一个持久化集锦任务。
2. 每次从训练记录发起并点击“下一步”都创建新的任务 UUID；即使训练记录、视频及设置完全相同，也不复用其他任务。
3. 同一次新建流程只允许成功创建一个任务；重复点击或导航重入不能产生重复任务。
4. 任务创建时复制完整训练记录作为不可变快照。创建成功后，任务与原训练记录彻底解除生命周期关系。
5. 任务内不能更换或修改训练记录。使用其他训练记录必须新建任务。
6. 原训练记录之后被修改、替换、合并或删除，不得改变或删除已有任务；删除任务也不得影响训练记录。
7. 任务的原始视频、选择顺序、默认前后时长、序数样式和审核片段可以在非生成状态下重新进入并修改。
8. 相册视频只保存稳定引用和必要元数据，不复制整段媒体；文件导入视频在任务创建或加入任务时复制到任务私有目录。
9. 相册来源被删除、权限撤销或暂时不可用时保留任务，并要求用户重新选择或替换来源；任务不得静默删除。
10. 视频集合或顺序变化后重新规划默认片段。只有视频稳定身份、关联打点集合和当前映射都精确匹配且范围仍有效的人工确认片段可以保留，其余片段恢复为新默认并明确报告重置数量。
11. 修改默认前后时长只重新计算默认片段；人工确认的范围与保留/排除状态保持不变。
12. “重置全部片段”是覆盖全部人工确认并重新应用当前默认时长的唯一批量入口，必须二次确认。
13. 修改片段序数样式不改变片段范围、关联打点或确认状态。
14. 审核页不生成逐片段视频文件。预览直接读取原视频指定范围，只缓存播放器、AVAsset、缩略图和胶片帧等运行时资源。
15. 一旦离开审核页，无论去生成视频还是返回首页，都取消媒体请求并释放全部审核运行时资源；任务中的轻量片段数据继续保存。
16. `HighlightTask` 是长期可编辑实体；`HighlightRenderExecution` 是每次开始生成时从任务当前配置建立的不可变快照。
17. 一个任务同一时间最多有一个生成执行；全 App 的视频生成继续使用串行队列。
18. 排队和生成过程中，用户唯一可执行操作是“停止”。即使任务已有旧成片，也不显示播放、保存、编辑、删除或其他操作。
19. 停止只取消当前执行并清理执行临时文件，不删除任务配置、任务输入或旧成片。
20. App 进入后台时停止所有排队和运行中的生成；不注册或使用后台视频生成。
21. App 被直接终止而无法及时清理时，下次启动把所有遗留执行统一处理为“已停止”，清理临时文件且不自动继续。
22. 停止或失败后，如果任务配置没有变化，可以直接重新生成；配置变化后必须重新进入审核页再生成。
23. 已完成任务可以再次编辑。修改后旧成片仍可播放并明确标记不包含最新修改。
24. 重新生成期间旧成片继续保留，但生成中的界面仍只允许停止。新成片成功提交后替换并清理旧成片。
25. 新生成停止、失败或提交失败时，旧成片保持不变。
26. 第一版只保留当前成片，不提供配置版本历史、执行历史或多成片历史。
27. 删除任务会删除任务记录、文件导入副本、当前成片和任务临时文件，但不会删除相册视频、相册成片、HealthKit 数据或外部导出文件。
28. 本 Change 不迁移任何旧 App 数据。升级时执行一次完整数据世代切割，把 iPhone 与 Watch 的 ShotMarker 本地状态重置为空。
29. 数据切割删除训练、打点、旧审核、旧任务、App 内成片、文件副本、设置、安装标识、日志、诊断、缓存、临时文件和 Watch outbox。
30. 数据切割不删除系统相册内容、Health App workout、用户导出的文件或已经发送到远端的 Analytics/GlitchTip 历史事件。
31. iPhone 保存切割时间并 ACK 后丢弃切割前结束的 Watch 旧 outbox 训练，防止旧数据回流；切割后新完成的训练继续正常导入。
32. 任务、训练、视频和审核内容仍只保存在本地，不增加账号、业务服务器或跨设备任务同步。

## 目标

1. 让用户从进入审核开始就拥有可在首页恢复、编辑、停止、重新生成和删除的独立任务。
2. 让相同输入创建的不同任务拥有完全隔离的视频配置、片段确认和成片。
3. 固化训练事实，同时允许任务的媒体与剪辑表现持续演进。
4. 明确区分长期任务配置与一次生成执行，避免可变配置影响运行中的导出。
5. 把停止与删除分开；任何停止、失败或 App 生命周期变化都不丢失任务。
6. 在重新生成失败时继续保留上一次成功成片。
7. 审核页退出后释放所有重型媒体资源，不依赖逐片段临时视频。
8. 通过一次数据世代切割消除旧组合确认、旧任务模型和 Watch 旧 outbox 的兼容歧义。

## 非目标

- 不允许任务内修改或替换训练快照。
- 不提供任务云同步、iCloud Drive 同步、账号同步或跨设备编辑。
- 不提供任务复制、模板、重命名、标签、文件夹或搜索；首页使用训练时间、任务创建时间和视频数量区分任务。
- 不保留配置 revision 历史、执行历史、撤销历史或多个生成成片。
- 不实现真正的断点续传；停止后重新生成从头开始。
- 不在后台继续排队或视频生成；视频准备不属于生成执行，其既有合同不由本 Change 改变。
- 不为审核创建逐片段 MOV 文件，也不缓存完整解码视频。
- 不改变默认打点前 9 秒、后 4 秒、1 秒相邻合并、0.1 秒规范化、最短片段和最终编号规则。
- 不增加片段重新排序、转场、变速、画幅裁切、滤镜或音频编辑。
- 不改变 Watch 训练开始、打点和结束交互。
- 不删除系统相册、HealthKit 或 App 沙盒以外的数据。
- 不迁移、导出或恢复旧训练、旧审核或旧任务数据。
- 不新增 Analytics 产品事件；现有成功事件语义按本规格重新绑定到新的生成执行和相册保存结果。

## 术语

### 新建任务表单

用户从一条训练记录进入后，用于选择视频、调整默认前后时长和序数样式的临时页面。点击“下一步：审核片段”前没有任务；退出表单会丢弃尚未创建的选择。

### 集锦任务

`HighlightTask`。具有随机 UUID 的长期本地工作，拥有不可变训练快照、可变视频与剪辑配置、审核片段、当前生成结果和当前成片。

### 配置 revision

任务每次成功提交配置变化时递增的单调整数。它只用于判断执行和成片对应哪一版当前配置，不构成可浏览或可恢复的历史版本。

### 审核片段

任务持久化的轻量片段定义，包含原始打点引用、来源视频、默认范围、当前范围、保留/排除状态和确认状态。它不是独立视频文件。

### 生成执行

`HighlightRenderExecution`。从任务某个配置 revision 创建的一次不可变、可取消的视频导出输入和运行状态。执行成功后只把成片结果提交回任务，不允许反向修改任务配置。

### 当前成片

任务最近一次成功提交的本地视频。它记录对应的配置 revision；任务修改后仍可播放，但显示为旧配置结果，直到新的成片成功替换。

### 数据世代

iPhone 与 Watch 本地数据契约的整体版本。进入本规格定义的新世代时不兼容旧数据，首次启动执行一次完整本地重置。

## 用户流程

### 新建任务

1. 用户从训练记录列表打开一条训练记录。
2. 页面显示只读训练摘要，并允许选择最多 20 个视频。
3. 用户调整打点前后时长和片段序数样式。新建表单初值来自本机最近使用的默认设置；这些值尚不属于任务。
4. App 读取视频稳定身份、录制开始时间、时长和可用性。需要用户同意 iCloud 下载时沿用明确的准备入口。
5. 用户点击“下一步：审核片段”。
6. App 禁用重复提交，冻结一份完整训练快照，为任务和任务视频分配稳定内部身份。
7. 文件导入来源复制到任务 staging 目录；相册来源只保存引用。
8. App 按当前默认时长规划并合并默认片段，验证至少存在一个可审核片段。
9. App 把 staging 目录原子移动为任务稳定目录，再原子保存新任务文档，并进入该任务的审核页。
10. 任务从保存成功时起出现在首页；训练列表和任务之间不保留外键或级联关系。

如果步骤 6–9 任一失败，不创建可见任务，不改变训练记录，并清理本次 staging 文件。一次按钮动作只能创建一个 UUID；保存成功后的导航重试继续使用同一任务。

### 审核任务

1. 审核图集从任务持久化的 `reviewItems` 建立，不从全局组合 Store恢复。
2. 默认片段和已确认片段继续使用现有状态、范围、保留/排除、汇总、编号及相邻合并语义。
3. 用户打开单片段时创建内存工作副本。拖动、精调、恢复默认和保留切换不直接改变任务。
4. 用户点击“确认片段”后，App 规范化并验证范围，原子更新任务片段并增加配置 revision。
5. 只有写盘成功后才更新图集、汇总、缩略图和连续导航；失败时保留工作副本并允许重试。
6. 未确认改动返回时继续显示“放弃本次调整？”；放弃不修改任务。
7. 用户可直接使用默认片段生成，不要求逐项确认。

审核页只有两个完整流程出口：

- “生成视频”：验证当前任务，创建生成执行并返回首页。
- “退出到首页”：保存已经成功确认的任务数据并返回首页，不创建执行。

两个出口都必须停止播放器、移除观察者、取消帧请求、清空 AVAsset/缩略图/胶片帧缓存，并删除审核准备临时文件。未确认工作副本不进入任务。

### 再次进入任务

1. 用户从首页点击一个非排队、非生成状态的任务。
2. 首先进入任务配置页，而不是直接进入某个片段编辑器。
3. 页面展示只读训练摘要、当前视频和顺序、默认时长、序数样式、生成结果与是否包含未生成修改。
4. 视频、时长和样式先进入页面工作草稿，不边输入边写任务。
5. 用户点击“下一步：审核片段”后，App 把工作草稿作为一个配置事务验证并提交，再进入同一任务的审核页。
6. 配置没有实际变化时不增加 revision；存在变化时无论包含几个字段都只增加一次 revision。
7. 该入口不创建新 UUID；所有修改只作用于当前任务。

带未提交草稿返回首页时显示“放弃本次调整？”；确认放弃后保留进入页面前的任务。视频复制、规划或写盘失败时继续停留在配置页，保留草稿并允许重试。

用户如果从训练记录重新发起流程并点击下一步，则始终创建另一任务，即使输入完全相同。

### 提交配置草稿

已有任务的“下一步：审核片段”使用草稿最终值执行一次事务：

1. 比较视频稳定身份和顺序、默认前后时长及完整序数样式，确认是否存在实际变化。
2. 最终视频列表必须包含 1–20 个稳定身份互不重复的视频，并能规划出至少一张审核卡片；不满足时不修改任务。
3. 没有变化时丢弃草稿并直接进入当前审核数据，不写盘、不增加 revision。
4. 视频或默认时长变化时，以草稿的最终视频顺序和最终时长只执行一次规划协调；视频确认项保留规则优先于默认时长规则，保留下来的确认项再用最终时长更新默认基线。
5. 只有样式变化时不运行片段规划；样式与其他字段同时变化时只把最终样式随同一事务提交。
6. 原子写入最终视频、设置和审核片段，把 `configurationRevision` 恰好增加 1；写盘成功后才发布到页面。
7. 成功后清理被最终配置解除引用的旧文件副本、报告被重置的确认项数量并进入审核页。

任何准备、规划或写盘失败都不改变原任务，也不提前删除旧输入。过期草稿提交必须通过期望 revision 被 Store 拒绝。

### 修改视频

视频变化必须作为单一任务事务处理：

1. 读取并验证新视频列表及严格顺序。
2. 为文件来源准备新的任务私有副本，但尚不删除旧副本。
3. 按固定训练快照和当前默认时长建立新默认规划。
4. 对每个已确认片段检查：稳定视频身份仍存在；新选择顺序下这些打点仍映射到该视频；关联打点集合完全相同；保存范围仍位于视频边界内。
5. 同时满足全部条件的确认项保留当前范围及保留/排除状态，并更新其当前默认基线；其他项恢复为新默认。
6. 剩余未被有效确认项占用的打点参加默认规划；一个打点只能出现一次。
7. 原子保存任务并增加配置 revision。
8. 保存成功后删除不再引用的任务输入副本，并提示被重置的人工片段数量。

任何身份、复制、规划或写盘失败都保留旧视频、旧片段和旧文件。不得通过相似时间、文件名或近似范围猜测迁移人工编辑。

### 修改默认时长

- 默认前后时长属于任务配置，不再通过共享组合决定审核状态。
- 修改后，已确认片段保留当前范围、关联打点和保留/排除状态。
- 默认片段使用新时长重新规划；已确认项占用的打点不得重复出现。
- 已确认片段的默认基线更新为当前设置下同组打点的合法默认范围，供以后单片段“恢复默认”使用。
- 修改成功增加配置 revision，并使旧成片成为“未包含最新修改”。
- “重置全部片段”经二次确认后丢弃全部确认状态，使用当前视频和时长重建所有默认片段。

### 修改序数样式

- 序数位置、字号、文字不透明度和黑底不透明度全部属于任务配置。
- 样式调整不重新规划片段、不改变确认状态或默认基线。
- 一次已提交的有效样式变化增加配置 revision。
- 新建任务表单可以继续把最近使用样式作为下一任务的默认模板；编辑已有任务不得反向改变其他任务。

### 开始生成

1. 用户在审核页点击“生成视频”。
2. App 验证任务当前至少包含一个保留且来源可用的最终片段，片段编号、边界和打点引用均有效。
3. App 从当前配置 revision 创建不可变生成快照和新的执行 UUID。
4. 执行记录先写入任务 Store，再加入串行队列。
5. 页面返回首页。排队和生成状态只显示进度与“停止”。
6. Runner 只读取执行快照，不读取之后的 UserDefaults、任务 ViewModel 或审核 Store。

生成快照必须包含独立完成本次导出所需的有序视频来源、精确最终片段、序数样式、有效打点集合和配置 revision。运行中任务配置保持只读。

### 停止和直接重新生成

- 用户停止排队执行时，执行不得启动。
- 用户停止运行执行时，先使执行 UUID 失效并持久化停止结果，再取消底层导出和清理临时文件。
- Runner 的串行执行槽必须等旧执行真正取消并完成临时文件清理后才交给下一执行；任务可以先显示已停止，但新执行不得与旧导出并行。
- 已失效执行的迟到进度或成功回调必须被忽略。
- 停止不删除任务、任务输入或当前成片。
- 停止或失败结果记录其配置 revision。任务配置仍为同一 revision 时允许直接重新生成。
- 用户先编辑任务后，旧停止/失败结果不再提供直接重新生成；必须经过审核页创建新执行。
- 直接重新生成也必须重新验证当前任务，并创建新的执行 UUID 和不可变快照；始终从头开始，不复用旧执行或部分输出。

### 完成后编辑与替换成片

- 生成成功后任务保存当前成片及其配置 revision。
- 用户再次进入修改任务时，旧成片继续可播放和保存到相册，并显示“当前成片不包含最新修改”。
- 开始重新生成后，任务仅显示进度与停止，暂时不提供旧成片操作。
- 新成片成功提交后取代 `currentOutput`；第一版不在任务中保留旧路径或历史条目。
- 新成片停止、失败、文件移动失败或任务 JSON 写入失败时，`currentOutput` 仍指向旧成片。
- 旧成片此前已经保存到系统相册的事实属于外部结果；新成片的相册保存状态从未保存开始。

### 删除任务

- 非排队、非生成状态允许删除任务并要求破坏性确认。
- 排队或生成状态只能先停止，不能直接删除。
- 删除事务先从任务文档移除任务，再清理该任务拥有的输入副本、当前成片、执行临时文件和孤立 staging 文件。
- 文件清理失败不得让已删除任务重新出现在首页；记录本地封闭错误类别并在后续孤立文件清理重试。
- 删除任务不得访问或删除训练记录、相册资产、相册成片、HealthKit workout 或外部导出文件。

## 状态与操作权限

任务的可见状态由当前执行、最后一次执行结果、当前配置 revision 和成片 revision 共同推导，不允许界面各自猜测。

| 可见状态 | 判定 | 允许操作 |
| --- | --- | --- |
| 审核中 | 无活动执行，尚无当前 revision 的成功或停止/失败结果 | 进入编辑、审核片段、删除 |
| 排队中 | 当前执行已持久化但尚未开始 | 仅停止 |
| 生成中 | 当前执行正在导出 | 仅停止 |
| 已停止 | 当前 revision 最近执行被用户、后台切换或启动恢复停止 | 直接重新生成、进入编辑、删除；存在旧成片时停止状态结束后可播放/保存旧成片 |
| 生成失败 | 当前 revision 最近执行失败 | 直接重新生成、进入编辑、删除；存在旧成片时可播放/保存旧成片 |
| 已完成 | 当前成片 revision 等于当前配置 revision | 播放、保存相册、进入编辑、重新生成、删除 |
| 有未生成修改 | 当前成片存在且 revision 小于当前配置 revision，且当前 revision 没有优先显示的停止/失败结果 | 播放/保存旧成片、继续编辑、审核并生成、删除 |

“排队中”和“生成中”的操作集合严格相同。界面不得因为旧成片存在而额外显示播放、保存、编辑或删除。

## 持久化数据模型

### 根文档

任务存储位置：

~~~text
Application Support/ShotMarker/highlight-tasks.json
~~~

语义模型：

~~~swift
struct HighlightTaskStoreDocument: Codable, Equatable {
    let schemaVersion: Int
    var tasks: [HighlightTask]
}
~~~

首版 `schemaVersion = 1`。文件不存在表示没有任务。高于当前实现的 schema 必须只读保护，不得覆盖；无法解码的文档先移动为带 UTC 时间戳的损坏备份，再向用户报告恢复错误。Store 无法可靠加载任务文档时不得执行孤立文件删除。

### HighlightTask

~~~swift
struct HighlightTask: Identifiable, Codable, Equatable {
    let id: UUID
    let trainingSnapshot: HighlightTaskTrainingSnapshot
    var configurationRevision: Int
    var videos: [HighlightTaskVideo]
    var clipSettings: ClipSettings
    var reviewItems: [PersistedHighlightTaskClip]
    var activeExecution: HighlightRenderExecution?
    var lastGenerationResult: HighlightTaskGenerationResult?
    var currentOutput: HighlightTaskOutput?
    let createdAt: Date
    var updatedAt: Date
}
~~~

契约：

- `trainingSnapshot` 创建后永远不变。它使用任务私有类型，不保存原 `TrainingSession.id`，也不得作为外键查询、更新或级联删除原训练。
- `configurationRevision` 初值为 1，只在用户可观察的任务配置事务成功时递增。
- 进度、临时错误、缓存和导航状态不增加配置 revision。
- 任务内视频使用任务稳定内部 ID，审核卡片不直接引用临时 URL 或 PhotoKit identifier。
- 当前执行和当前成片分别记录对应 revision。
- 所有路径都是相对于 ShotMarker Application Support 根目录的受控相对路径。

### HighlightTaskTrainingSnapshot

~~~swift
struct HighlightTaskTrainingSnapshot: Codable, Equatable {
    let startedAt: Date
    let endedAt: Date
    let markers: [HighlightTaskMarkerSnapshot]
}

struct HighlightTaskMarkerSnapshot: Identifiable, Codable, Equatable {
    let id: UUID
    let markedAt: Date
    let sourceOrder: Int
}
~~~

创建任务时复制训练起止时间，并按原训练当前的规范化打点顺序分配从 0 开始且不重复的 `sourceOrder`，同时为每个打点创建新的任务本地 UUID；任务不保留原训练 ID 或原打点 ID。全部时间值按既有规范复制，任务内打点顺序按 `markedAt`、`sourceOrder` 稳定确定。审核片段的 `markerIDs` 此后只引用任务本地打点，重复使用同一训练创建的两个任务不会共享任何训练或打点身份。

### HighlightTaskVideo

~~~swift
struct HighlightTaskVideo: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceIdentity: HighlightClipReviewSourceIdentity
    var recordedStartAt: Date
    var duration: TimeInterval
    var source: HighlightTaskVideoSource
}

enum HighlightTaskVideoSource: Codable, Equatable {
    case photoLibraryAsset(localIdentifier: String)
    case taskInputFile(relativePath: String)
}
~~~

- 相册来源身份使用带类型的 PhotoKit local identifier。
- 文件来源继续使用完整内容 SHA-256 作为稳定身份，哈希必须以固定缓冲区流式计算。
- 文件内容复制到任务目录后，持久化 source 使用相对路径；外部原 URL 不保存。
- 视频拍摄时间规范到 Unix epoch 毫秒，时长规范到 timescale 600 tick 后参与身份和规划验证。
- 任务内部 ID 在同一视频被保留或调整顺序时保持不变；重新选择不同来源时创建新 ID。

### PersistedHighlightTaskClip

~~~swift
struct PersistedHighlightTaskClip: Identifiable, Codable, Equatable {
    let id: UUID
    let videoID: UUID
    let markerIDs: [UUID]
    var defaultStart: TimeInterval
    var defaultDuration: TimeInterval
    var start: TimeInterval
    var duration: TimeInterval
    var isIncluded: Bool
    var confirmationState: HighlightClipConfirmationState
}
~~~

- 所有默认卡片和已确认卡片都持久化在任务中，不再只保存确认项。
- `markerIDs` 非空、只引用同一任务 `trainingSnapshot.markers` 中的任务本地 UUID，且一个任务内每个打点最多由一张卡片占用。
- 时间范围继续规范为 0.1 秒和 timescale 600 语义。
- 缩略图、胶片帧、播放器状态、编辑工作副本和错误提示不持久化。
- 最终 `ConfirmedHighlightSegment` 在创建生成执行时由当前卡片统一验证、过滤、编号和相邻合并。

### HighlightRenderExecution

~~~swift
struct HighlightRenderExecution: Identifiable, Codable, Equatable {
    let id: UUID
    let configurationRevision: Int
    let snapshot: HighlightRenderSnapshot
    var status: HighlightRenderExecutionStatus
    var progress: HighlightJobProgress
    let createdAt: Date
    var updatedAt: Date
}

enum HighlightRenderExecutionStatus: String, Codable, Equatable {
    case queued
    case running
}
~~~

执行快照必须包含规范化的 `ClipSettings`、任务视频快照、非空且已验证的最终精确片段，以及验证打点引用所需的数据。运行时只能通过返回新进度或最终结果更新任务，不能持有任务的可变引用。`running` 覆盖来源解析、composition 构建、导出、成片移动和任务成片引用提交的完整阶段；成功提交或停止/失败落盘之前都不得提前退出“生成中”权限集合。

停止、失败或成功后清除 `activeExecution`，并把结果写入 `lastGenerationResult`：

~~~swift
struct HighlightTaskGenerationResult: Codable, Equatable {
    let executionID: UUID
    let configurationRevision: Int
    let status: HighlightTaskGenerationResultStatus
    let finishedAt: Date
    let errorCode: HighlightTaskGenerationErrorCode?
}

enum HighlightTaskGenerationResultStatus: String, Codable, Equatable {
    case stopped
    case failed
    case succeeded
}
~~~

`stopped` 和 `succeeded` 的 `errorCode` 必须为空；`failed` 必须保存封闭错误码。结果不得保存用户可变文案、内部临时路径或底层错误对象；界面从封闭错误码生成本地化消息。

### HighlightTaskOutput

~~~swift
struct HighlightTaskOutput: Codable, Equatable {
    let id: UUID
    let relativePath: String
    let configurationRevision: Int
    let generatedAt: Date
    var photoLibrarySavedAt: Date?
    var photoLibrarySaveErrorCode: HighlightTaskPhotoSaveErrorCode?
}
~~~

第一版最多存在一个 `currentOutput`。保存到相册失败不改变成片或任务配置 revision；用户可以重复尝试。成功时写入 `photoLibrarySavedAt` 并清空错误码；失败时只保存封闭错误码，界面在运行时生成本地化文案。

## 文件布局

~~~text
Application Support/ShotMarker/
├── training-sessions.json
├── highlight-tasks.json
├── HighlightTasks/
│   └── <task UUID>/
│       ├── Inputs/
│       │   └── <task video UUID>.<extension>
│       └── Outputs/
│           └── <output UUID>/highlight.mov
└── Logs/
~~~

执行中间文件使用系统临时目录中带 ShotMarker 前缀和执行 UUID 的路径，不建立 `clip-1.mov`、`clip-2.mov` 等逐片段文件。新成片使用新 output UUID，确保提交前不覆盖当前成片。

## Store、文件事务与并发

### HighlightTaskStore

新增 actor 隔离的 `HighlightTaskStoring`，至少支持：

- 加载全部任务并执行启动状态规范化；
- 原子创建任务；
- 按任务 ID 和期望 revision 更新配置；
- 安装、更新和清除活动执行；
- 提交停止、失败或成功结果；
- 原子替换当前成片引用；
- 删除任务；
- 在任务文档可靠加载后清理孤立文件引用。

每次更新采用乐观 revision 检查。调用方提交的基线 revision 与磁盘当前值不一致时返回冲突，不允许后到页面覆盖先到修改。JSON 写入使用同目录临时文件和原子替换；UI 只有在 Store 成功后才发布新状态。

### 创建任务事务

1. 在唯一 staging 目录复制文件输入并完成稳定身份计算。
2. 构造、规范化并验证完整任务。
3. 确认目标任务目录不存在，把 staging 目录原子改名为任务稳定目录。
4. 使用期望根文档版本原子写入包含新任务的 JSON；只有这一步成功后任务才对 UI 可见。
5. 步骤 3 失败时不修改根文档并清理 staging；步骤 4 失败时删除尚未被文档引用的稳定任务目录。
6. 如果进程在步骤 3 与步骤 4 之间终止，启动时只有在根文档可靠加载后才把该目录识别为孤立目录并清理。
7. 写盘成功后允许导航；重复导航或页面回调继续使用同一任务 ID。

不得先写入会引用未落盘文件的任务记录，也不得把跨 JSON 和目录的操作描述为单个文件系统原子事务。

### 更新视频事务

先准备新增输入，再保存新配置，最后清理旧输入。任何失败保持旧文档和旧输入完整。多个快速视频变更必须取消或废弃过期结果，过期异步回调不得覆盖较新的任务 revision。

### 输出提交事务

1. 导出到执行唯一临时路径。
2. 把新文件移动到新 output UUID 目录。
3. 验证活动执行 UUID 和 revision 仍与任务匹配。
4. 原子更新任务，让 `currentOutput` 指向新文件并清除活动执行。
5. 写盘成功后删除旧 output 目录。
6. 任一步骤失败都不改变旧 `currentOutput`；未引用的新文件由安全清理回收。

### 停止竞态

停止事务必须先从任务中撤销活动执行并记录 stopped 结果，再请求 Runner 取消。所有进度和完成回调携带 task ID、execution ID 和 revision；只有三者仍匹配当前活动执行才可更新。这个门槛同时覆盖用户停止、App 后台化和启动时恢复。

停止与成功提交同时到达时，由 `HighlightTaskStore` actor 中先成功的事务决定结果：成功提交先完成时，后到停止成为幂等空操作；停止先完成时，后到成功回调失效，新文件不得替换旧成片并由孤立文件清理回收。

## 规划与编辑规则

### 初始默认规划

继续使用当前 `VideoClipSegmentPlanner`：

- 按规范化打点时间排序；相同时间用打点 UUID 稳定排序。
- 每个打点使用有序视频中第一个覆盖它的来源。
- 默认范围按任务前后时长建立并裁剪到视频边界。
- 同一视频内重叠或实际间隔不超过 1 秒的相邻片段合并为一张审核卡片。
- 原始打点不因合并、编辑或排除而改变。

### 最终规划

继续使用当前审核汇总语义：

- 排除卡片不进入结果并中断合并链。
- 只合并审核原顺序相邻、来源相同、仍保留且重叠或间隔不超过 1 秒的片段。
- 最终按保留打点重新编号。
- 执行快照固化精确范围、打点集合和序数样式。

### 编辑事务

单片段编辑器保持独立工作副本。确认顺序为：暂停播放、规范化范围、验证来源和边界、以期望 task revision 写入 Store、写入成功后发布图集和导航。失败不关闭编辑器、不修改图集、不增加 revision。

确认成功后继续打开当前卡片之后的第一个默认片段，跳过已确认片段；后面没有默认片段时返回图集，不循环。

## 审核媒体生命周期

审核卡片和编辑器不得导出单独视频。媒体层只允许持有：

- 当前页面需要的 AVAsset 引用；
- 一个活跃 AVPlayer item 及其时间观察者；
- 有明确上限的缩略图和胶片帧 JPEG Data；
- 当前页面的异步加载任务。

播放直接加载原视频并限制在片段范围内。退出单片段编辑器至少清理播放器和该片段胶片请求；退出整个审核页必须调用统一 `ReviewSession.release()`：

1. 取消所有缩略图和胶片帧任务。
2. 暂停播放器、移除周期/边界观察者并清空 current item。
3. 清空 AVAsset、帧 Data、请求索引和错误状态。
4. 删除不属于任务输入的媒体准备临时文件。

任务持久化片段、任务输入副本和当前成片不属于审核缓存，不能由 `ReviewSession` 删除。再次进入审核时完全根据任务 Store 和原始视频重新建立媒体状态。

## 生成队列与 App 生命周期

- 全 App 同时最多运行一个生成执行；其他已提交执行处于 queued。
- queued 和 running 任务的 UI 都只暴露停止。
- Scene 进入 `.background` 时同步发起 `stopAllExecutions`，停止当前 Runner 并把所有 queued/running 任务持久化为 stopped。
- `.inactive` 的短暂系统过渡不单独触发停止；真正进入 background 才停止。
- App 不申请视频生成后台时间，不创建 BGTask，不在后台启动下一任务。
- 进程被系统直接杀死时无法保证即时删临时文件；下次启动在展示首页前把所有持久 queued/running 执行规范为 stopped，并清理对应临时路径。
- 启动后不自动重新入队。用户可以直接重新生成未改配置的 stopped 任务，也可以先编辑。
- 保存到相册是用户主动触发的独立动作，不改变配置 revision；它不被描述为后台视频生成。

## 一次性全 App 数据切割

### 数据世代标记

iPhone 和 Watch 各自在标准 UserDefaults 中保存 `ShotMarker.dataEpoch`。本规格引入 `currentDataEpoch = 1`；缺失或小于 1 都进入重置。重置成功后才写入 1。重置中途失败或进程终止时，下次启动必须再次从头执行，且在成功前不能初始化业务 Store、同步、日志、Analytics 或崩溃上报。

iPhone 在 ShotMarker 业务目录之外使用唯一的启动事务文件 `Application Support/ShotMarkerReset/reset-state.json`。它只允许包含 `targetEpoch` 和首次重置生成的 `dataCutoverAt`，使用同目录临时文件原子写入；不得包含训练、媒体、设备或用户标识。首次进入重置时创建它；未完成重试读取并复用它；重置成功并写回 UserDefaults 后立即删除整个 `ShotMarkerReset` 目录。启动时只要该文件存在，就必须把重置视为未完成并优先重试，即使 UserDefaults 已经写入目标 epoch。该文件只是崩溃安全的重置日志，不是需要迁移或长期保留的业务数据。

### iPhone 重置顺序

1. 在 `ShotMarkerApp` 初始化其他服务前读取 epoch。
2. 原子创建或读取 `ShotMarkerReset/reset-state.json`，固定本次 `dataCutoverAt`；同一次未完成重试必须复用首次记录的切割时间，避免重试不断扩大丢弃窗口。
3. 删除 Application Support 下 ShotMarker 整个目录，包括训练、旧审核、旧任务、新旧任务文件、App 内成片、日志和诊断。
4. 清空当前 App 沙盒的 Caches 目录和 `NSTemporaryDirectory()` 内容。
5. 清除当前 App UserDefaults persistent domain，包括剪辑设置、安装标识和所有本地开关。
6. 写回 `ShotMarker.dataEpoch = 1` 与固定的 `ShotMarker.dataCutoverAt`。
7. 删除 `Application Support/ShotMarkerReset` 目录。
8. 只有全部成功后才初始化新 Store、GlitchTip、Analytics、WatchConnectivity 和首页。

系统相册权限、HealthKit 权限和系统通知权限由操作系统管理，清理沙盒不能也不得尝试重置它们。

### Watch 重置顺序

Watch 新版本首次启动时在创建同步服务前：

1. 删除 Watch Application Support 下的 `watch-training-sync-outbox.json` 及其他 ShotMarker 本地文件。
2. 清空 Watch App UserDefaults persistent domain。
3. 清空 Watch App 沙盒的 Caches 目录和 `NSTemporaryDirectory()` 内容。
4. 写入 Watch 自己的 `ShotMarker.dataEpoch = 1`。
5. 初始化空 outbox 和训练界面。

Watch 上不持久化当前训练 ViewModel；系统 HealthKit 中已经完成的 workout 不删除。

### 防止旧 Watch 数据回流

iPhone 切割后必须在训练导入最外层执行时间门槛：

- `payload.endedAt <= dataCutoverAt`：不写入训练 Store、不发送训练同步成功 Analytics；向 Watch 返回正常 ACK，使其删除旧 outbox 条目。
- `payload.endedAt > dataCutoverAt`：继续走当前幂等导入、持久化、Analytics 和 ACK 流程。

门槛同时适用于更新前 Watch 版本，不能要求 payload 新增字段后才生效。日志只记录丢弃数量和封闭原因，不记录训练 UUID 或时间内容。Watch 更新并执行本地重置后，旧 outbox 从来源端消失。

### 外部数据边界

数据切割不得删除或声称删除：

- 系统相册原视频；
- 用户此前保存到系统相册的成片；
- Health App 中的 workout；
- 用户导出到 Files、共享位置或其他 App 的训练 JSON 和日志包；
- 已经发送到 Analytics 或 GlitchTip 的远端事件。

切割会重置本地安装标识，之后 Analytics 使用新的随机安装标识。远端历史记录不会因此被主动删除。

## 错误处理

### 任务创建失败

保留新建表单当前选择和设置，显示可重试错误，不创建首页任务。已复制的 staging 文件清理失败时只记录本地封闭类别并由后续启动清理。

### 任务更新冲突或写盘失败

保留编辑工作副本或配置页面输入，不发布到任务列表。revision 冲突时重新加载当前任务并明确提示内容已变化；不能静默覆盖。

### 来源视频不可用

任务保留并显示具体来源不可用状态。用户可重新选择或替换视频；生成前再次验证所有最终保留片段来源。不可用片段可以被明确排除，但不能以保留状态进入执行。

### 生成失败

清除活动执行和临时输出，保存封闭错误类别及用户可理解的消息。任务配置和旧成片保持。当前 revision 未变化时允许直接重新生成。

### 停止或后台化

停止接口必须幂等。重复停止、后台回调与启动恢复可以同时发生，但最终只产生一个 stopped 结果，不删除任务或旧成片。

### 新任务文档损坏

先保存损坏文件副本，再显示无法加载任务的恢复提示。没有可靠任务引用集合时不得自动删除 `HighlightTasks` 文件目录，避免把可人工恢复的成片当成孤立文件。

### 数据切割失败

显示阻塞式“无法完成数据升级”页面和重试入口，不启动同步、Analytics、任务或训练界面。错误文案不包含绝对路径；本地系统日志只记录封闭阶段和错误类别。

## 组件边界

### AppDataResetCoordinator

在 App bootstrap 最前面负责 iPhone/Watch epoch 检查、全量本地重置、固定切割时间和失败阻塞。它不创建业务默认数据，不操作 Photos 或 HealthKit。

### HighlightTaskStore

任务文档的唯一写入者，负责 schema、actor 隔离、revision 检查、原子事务和启动状态规范化。它不读取 AVAsset、不规划片段、不控制页面。

### HighlightTaskFileStore

只处理任务输入副本、output UUID 目录、执行 staging 和受控相对路径。它不决定任务状态；删除必须接收已解析的精确任务或执行 ID，禁止宽泛递归目标。

### HighlightTaskPlanner

在现有 `VideoClipSegmentPlanner` 和 `HighlightClipReviewPlanner` 语义之上提供纯函数：初始任务草稿、视频变更协调、默认时长重算、全部重置、最终执行快照验证。它不执行文件 I/O。

### HighlightTaskManager

协调任务 Store、FileStore、Planner、串行 Runner 和 App 生命周期；负责 create/update/start/stop/restart/delete/output commit。所有异步回调通过 task ID、execution ID 和 revision 防过期。

### HighlightRenderRunner

由现有 `HighlightJobRunner` 演进，只接收不可变执行快照，直接用 `AVMutableComposition` 组合来源范围并导出一个 MOV。它不读取或修改长期任务，也不创建逐片段临时文件。

### NewHighlightTaskView

承载任务创建前的训练摘要、视频选择、默认时长和序数样式。只在用户点击下一步时调用一次创建事务。

### HighlightTaskEditorView

非生成状态的任务入口，展示固定训练摘要、可编辑视频/设置、当前成片和修改状态。进入审核继续使用同一任务 ID。

### HighlightClipReviewView / HighlightClipEditorView

继续承担图集与单片段交互，但数据源改为任务 revision 事务；页面离开统一释放 `ReviewSession`。不再读写组合级 `HighlightClipReviewStore`。

### TrainingSessionListView

首页任务区展示可见状态和允许操作。训练记录删除、合并和导入不再清理任务或审核数据，因为任务训练快照已经独立。

### Watch 同步入口

训练 importer 在写盘前应用 `dataCutoverAt` 门槛。旧 payload 被 ACK 丢弃；新 payload 继续现有幂等语义。

## 数据流

~~~text
TrainingSession（只在创建时读取）
        + ordered videos + task ClipSettings
                         ↓ 点击“下一步：审核片段”
              HighlightTask creation transaction
                         ↓
      immutable trainingSnapshot + persisted reviewItems
                         ↓
              HighlightTaskEditor / Review
                    ↓ 原子配置事务
             configurationRevision + 1
                         ↓ 点击生成
          immutable HighlightRenderExecution snapshot
                         ↓ 持久化后进入串行队列
                HighlightRenderRunner
                         ↓ 单次 composition/export
          new output file → atomic currentOutput commit
                         ↓
            delete old output after commit succeeds
~~~

训练列表与任务列表只在任务创建瞬间发生单向复制。创建后没有 lookup、同步、reconciliation 或级联删除。

## 隐私、日志与 Analytics

- 任务 JSON、输入文件副本、审核片段和 App 内成片只保存在沙盒，不上传。
- PhotoKit local identifier、文件 SHA-256、训练/打点 UUID、任务/执行 UUID、媒体文件名、时间范围和绝对路径不得进入 Analytics 或 GlitchTip metadata。
- 本地日志只记录状态、计数、总时长、是否有旧成片、重置阶段和封闭错误类别；不记录媒体身份或训练内容。
- 本 Change 不新增 Analytics 事件。
- 现有 `highlight_generate_succeeded` 在新成片成功提交到任务后发送；导出完成但任务提交失败不算成功。
- 现有 `highlight_save_succeeded` 只在当前成片实际保存相册成功后发送。
- 数据世代切割前已发送事件不删除；切割后安装标识重新生成。
- Watch 继续不发送 Analytics 或 GlitchTip。
- 不增加后台任务声明或新的 Privacy Manifest 数据类别；实现后必须重新检查实际 API 与清单一致性。

## 可访问性与界面要求

- 任务行读出任务日期、视频数量、可见状态、旧成片是否过期和当前唯一可用动作。
- 相同训练创建的多个任务通过任务创建时间和视频数量区分，不只显示相同训练标题。
- 排队/生成状态的辅助功能操作也只能包含停止，不能保留隐藏的播放或删除 action。
- 固定训练摘要明确显示“创建任务后训练记录不可更换”。
- “当前成片不包含最新修改”、视频不可用、片段重置数量和全量重置说明不能只依靠颜色表达。
- “重置全部片段”和“删除任务”使用破坏性确认，默认焦点不落在破坏性动作。
- 最大 Dynamic Type 下任务状态、进度、停止按钮、审核确认按钮和错误提示保持可读、可滚动且触摸目标至少 44 点。
- 本 Change 要求自动可访问名称与状态测试；没有实际执行前不得记录 VoiceOver 人工验收为通过。

## 自动测试

### 数据世代切割

- iPhone 缺失/旧 epoch 时清空 Application Support、Caches、已知临时文件和完整 UserDefaults domain。
- 重置成功写入固定 epoch 和 cutoverAt；第二次启动不删除新数据。
- 重置中途失败不初始化业务服务，重试复用同一 cutoverAt。
- GlitchTip、Analytics、日志和 WatchConnectivity 都在重置成功后初始化。
- Watch 首次进入新 epoch 时清空 outbox、UserDefaults、缓存和临时文件；第二次启动保留新 outbox。
- 切割前结束的旧 payload 被 ACK 丢弃，不写训练、不发送同步成功事件。
- 切割后结束的新 payload 正常导入和 ACK。
- 重置代码不调用 Photos 删除、HealthKit 删除或外部文件删除 API。

### 模型与 Store

- 根 schema 1、任务、视频、审核片段、执行、结果和成片完整 JSON 往返。
- 相同输入连续创建两次产生不同任务 UUID 且数据互不覆盖。
- 任务训练快照创建后不能通过任何更新 API 改变。
- 原训练删除、替换、合并和导入不修改任务。
- 配置事务成功只递增一次 revision；失败不递增、不发布。
- stale expected revision 被拒绝。
- 文件不存在、损坏根文档、未知高版本和原子写入失败行为明确且不误删任务文件。
- 删除任务不影响其他任务或训练 Store。

### 任务创建和视频文件

- 点击下一步只创建一个任务，重复回调不重复创建。
- 任务快照不保存原训练或原打点 ID；任务本地打点 ID 和 `sourceOrder` 完整往返。
- 相册视频不复制，文件视频复制进任务目录并只保存相对路径。
- 创建失败清理 staging 且首页无半任务。
- 视频更新成功后才清理旧副本；失败保留旧配置和旧文件。
- 删除任务清理任务拥有文件，不调用相册删除。

### 规划与编辑

- 初始任务默认片段与现有默认规划完全一致。
- 已有任务提交无变化草稿不写盘；同时修改多个配置字段只增加一次 revision，并使用全部草稿最终值规划。
- 视频增加、删除和换序后，只保留精确来源、打点集合、当前映射及范围都合法的确认项。
- 被重置确认项数量准确且一个打点只出现一次。
- 修改默认时长只重算默认项，确认项当前范围与状态不变。
- 确认项的默认基线随当前默认设置更新，单片段恢复默认使用新基线。
- 样式变化不重新规划片段。
- 重置全部片段清除确认状态并按当前输入完整重建。
- 编辑工作副本、保存失败、放弃、连续确认导航和最终相邻合并现有测试继续通过。

### 状态和权限

- 审核中、排队中、生成中、已停止、失败、已完成和有未生成修改的推导稳定。
- 排队和生成时操作集合严格等于 `{停止}`，包括存在旧成片的重新生成。
- 停止/失败且 revision 未变允许直接重新生成；修改后禁止直接重新生成。
- 成片 revision 落后时显示旧成片提示；匹配时显示已完成。
- 删除必须先停止活动执行。

### 生成、停止和输出

- 多任务串行且同一任务最多一个活动执行。
- 执行先持久化再运行。
- 停止 queued 不启动 Runner；停止 running 取消导出并保留任务。
- 重复停止幂等。
- 不合作 Runner 的迟到进度和完成被 execution ID/revision 门槛丢弃。
- App 进入 background 停止全部 queued/running；inactive 不误停。
- 启动发现遗留 queued/running 全部转 stopped，清理临时文件且不自动入队。
- 新输出移动、JSON 提交或清理任一步失败都保留旧成片引用。
- 新输出成功后当前引用更新，旧输出随后清理。
- Runner 直接从原视频范围建立单一 composition，不创建逐片段视频文件。

### 审核媒体生命周期

- 审核播放直接使用原 AVAsset 和活动时间范围。
- 缩略图/胶片帧缓存保持有界。
- 离开编辑器清理播放器和局部请求。
- 离开审核页取消全部请求，释放 AVAsset、播放器 item、观察者和帧 Data。
- 释放审核会话不删除任务片段、任务输入或成片。
- 再次进入只根据任务数据重建审核 UI。

### UI 回归

- 从训练记录选择一段和多段视频，点击下一步后任务立即出现在首页。
- 审核页退出首页后再次进入，恢复视频、时长、样式和片段。
- 相同训练与视频再次发起时创建独立任务。
- 非生成任务点击后先进入任务配置页。
- 视频变化后的保留与重置提示正确。
- 生成中页面与任务行只有进度和停止。
- 停止后可直接重新生成或进入编辑。
- 已完成任务编辑后旧成片可播放且显示过期提示。
- 新生成成功替换旧成片，失败仍保留旧成片。
- 删除任务二次确认及文件清理正确。
- App 后台化后任务显示已停止。

## 人工验收

使用至少一条含普通片段和默认合并片段的训练记录，以及两段可交换顺序的真实视频：

1. 从训练记录选择一段视频并调整序数样式，点击下一步，验证立即形成任务并进入审核。
2. 不生成直接退出首页，验证任务存在；重新进入配置页并进入审核，验证全部数据恢复。
3. 使用完全相同训练和视频重新发起，验证产生另一独立任务。
4. 在第一任务确认一个片段，验证第二任务不受影响。
5. 在任务中增加第二段视频，验证只有精确匹配确认项保留，其他项重置且提示数量。
6. 交换视频顺序导致打点映射变化时，验证相关人工确认不被错误保留。
7. 修改默认前后时长，验证默认项重算、确认项保持。
8. 执行“重置全部片段”，验证二次确认后所有片段使用当前默认值。
9. 修改序数样式，验证片段范围和确认状态不变。
10. 打开多个片段预览后退出审核，使用调试证据确认播放器、观察者、AVAsset 和帧缓存释放，且没有逐片段视频文件。
11. 开始生成，验证排队和运行中只有停止可用。
12. 停止生成，验证任务配置保留并可直接重新生成。
13. 生成中把 App 切到后台，验证执行停止且回到前台不自动继续。
14. 模拟进程在生成中终止，重新启动后验证任务显示已停止并可编辑。
15. 完成生成后修改任务，验证旧成片继续播放并提示未包含最新修改。
16. 重新生成失败，验证旧成片不丢失。
17. 重新生成成功，验证当前成片替换且旧 App 内文件被清理。
18. 删除任务，验证文件导入副本和 App 内成片删除，相册视频与相册成片仍存在。
19. 安装带新数据世代的版本，验证 iPhone 所有 ShotMarker 本地数据清空，第二次启动的新数据保留。
20. 验证 Watch outbox 被清空；模拟切割前旧 payload，确认 iPhone ACK 但不恢复训练；切割后新训练正常同步。

## 验证门槛

实施完成至少需要：

- 数据世代切割、任务 Store、文件事务、revision、规划协调、状态权限、停止竞态、输出替换和媒体释放的新增自动测试通过；
- 现有片段范围、播放、编号、视频准备、导出、Photos 保存、训练同步和 Watch outbox 回归通过；
- 完整 iPhone 测试通过，不能回退当前 342 项基线；
- 完整 Watch 测试通过，不能回退当前 30 项基线；
- 使用全新 DerivedData 的 Release generic iOS Simulator 构建成功；
- Release App、dSYM 和 Privacy Manifest 存在，DEBUG 测试入口不进入产物；
- `git diff --check` 通过；
- 真实媒体验收记录实际 Simulator/设备、系统版本、媒体属性和逐项结果；
- 没有实际执行时不得声明真机、VoiceOver、TestFlight、App Store Connect、Analytics 生产或 GlitchTip 生产通过；
- 实施完成后先更新受影响 `docs/current/`，再归档本规格和实施计划。

## 文档影响

设计确认后、实施前：

- `docs/current/product.md` 记录新的有效任务决定及当前实现差距。
- `docs/current/architecture.md` 记录已确认但尚未实现的双层任务架构和数据切割。
- `docs/current/status.md` 把本 Change 列为已确认、待实施。
- `docs/README.md` 增加本活跃 Change 入口。

实施并验证后：

- 以上 current 文档改为实际实现事实和验证结果。
- `docs/current/quality.md` 只记录当次实际执行的测试、构建和人工验收证据。
- `docs/current/release.md` 记录全量本地数据切割对升级和披露的实际影响。
- 本规格和届时生成的计划移动到 `docs/archive/2026-09/`。

## Definition of Done

- [x] 点击“下一步：审核片段”原子创建独立、可恢复的 `HighlightTask`。
- [x] 任务训练快照创建后与原训练记录完全解耦且不可修改。
- [x] 相同输入重复发起产生互不影响的任务。
- [x] 任务视频、默认时长、序数样式和片段可再次进入修改。
- [x] 视频变化只保留精确可证明安全的人工确认，其他项重置并提示。
- [x] 默认时长只重算默认片段，“重置全部”才覆盖确认片段。
- [x] 审核页不创建逐片段视频，退出时释放全部运行时媒体资源。
- [x] 长期任务和不可变生成执行职责分离，Runner 不读取可变任务。
- [x] 排队和生成期间唯一操作为停止。
- [x] 主动停止、后台化和异常退出都停止执行、保留任务且不自动恢复。
- [x] 停止/失败可在未改配置时直接重新生成，修改后必须重新审核。
- [x] 已完成任务修改后保留旧成片，新成片成功后安全替换，失败不丢旧成片。
- [x] 删除任务只清理任务拥有数据，不影响训练、Photos、HealthKit 或外部文件。
- [x] 新数据世代首次启动完整重置 iPhone 与 Watch 本地 App 数据且只执行一次。
- [x] 切割前 Watch outbox 不会把旧训练重新导入，切割后新训练正常同步。
- [x] 旧训练、旧审核和旧任务不迁移。
- [x] 新增及现有 iPhone/Watch 测试、Release 构建通过；约定验收逐项记录真实执行方式和边界，详见验证记录。
