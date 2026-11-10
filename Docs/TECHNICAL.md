# Claude Monitor 技术说明

本文档描述各模块的实现方式、数据来源、公式、调度与性能取舍。面向需要继续维护或审阅工程的读者。

## 1. 总体架构

```text
AppDelegate
  ├─ AppSettings (@MainActor, UserDefaults)
  ├─ MonitorEngine (@MainActor, 2s / 1s timer)
  │    ├─ CPUSampler
  │    ├─ MemorySampler
  │    ├─ DiskSampler
  │    ├─ GPUSampler
  │    ├─ PowerSampler → SMCReader / AppleSmartBattery / IOPowerSources
  │    └─ ProcessSampler (按需)
  ├─ StorageAnomalyMonitor (每日 + 手动)
  │    ├─ CStorageScanner (fts)
  │    └─ SnapshotStore
  ├─ IndexMonitor (启动/6h + 手动)
  │    └─ IndexScanner
  ├─ NotificationManager (UNUserNotificationCenter)
  ├─ PanelState (可见性 / 路由)
  ├─ PanelController (自定义 NSPanel)
  └─ MenuBarController (NSStatusItem)
```

UI 层通过 `@ObservedObject` 订阅 `MonitorEngine`、`StorageAnomalyMonitor`、`IndexMonitor`、`AppSettings` 与 `PanelState`。后台采集只把不可变值对象发布回主线程，不在主线程做文件遍历或 IOKit 读取。

## 2. 采集模块

### 2.1 CPU

`host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, ...)` 返回每个核心的 user/system/idle/nice tick。采样器保存上一组 tick，计算：

```text
coreUsage = (busyDelta / totalDelta) × 100
overallUsage = (Σ busyDelta / Σ totalDelta) × 100
```

采样器在初始化时先取一次基线，避免启动后第一个可见采样固定为 0%。所有调用在串行采样队列上执行。

文件：[`CPUSampler.swift`](../Sources/ClaudeMonitor/Collectors/SystemSamplers.swift)

### 2.2 内存

`host_statistics64(HOST_VM_INFO64)`：

```text
used  = active + wired + compressed
cached = inactive + speculative + purgeable
total = physical memory
```

swap 通过 `sysctlbyname("vm.swapusage")` 读取。该口径与 Activity Monitor 的「Memory Used」接近，inactive 被保留为可回收缓存。

### 2.3 磁盘

根宗卷 `URL(fileURLWithPath: "/")` 的 `volumeTotalCapacity` 与 `volumeAvailableCapacity`。没有使用 `volumeAvailableCapacityForImportantUsage` 作为主数值，因为它把可清除空间也算进可用容量，会低估占用。

### 2.4 GPU

```swift
IOServiceMatching("IOAccelerator")
IORegistryEntryCreateCFProperties
  → PerformanceStatistics
  → "Device Utilization %"
```

先尝试 `IOAccelerator`，找不到再尝试 `IOGPU`。若 `Device Utilization %` 缺失，依次尝试 `Renderer Utilization %`、`Tiler Utilization %`；显存读取 `In use system memory` 或 `Alloc system memory`。部分 Intel 驱动和未来系统可能不提供，UI 显示 N/A。

没有使用 Metal 性能计数器或 IOReport 私有接口，原因是前者需要额外授权/root，后者的字段和 ABI 不稳定。

### 2.5 功耗与充电

#### 数据层

1. **AppleSmartBattery / PowerTelemetryData**

   在 Apple Silicon 上通常可读取：

   | 键 | 含义 | 单位 |
   | --- | --- | --- |
   | `SystemPowerIn` | 适配器侧输入功率 | mW |
   | `SystemLoad` | 系统负载功率 | mW |
   | `BatteryPower` | 电池功率（符号依系统版本） | mW |
   | `AdapterEfficiencyLoss` | 适配器损耗 | mW |
   | `SystemVoltageIn` | 输入电压 | mV |
   | `SystemCurrentIn` | 输入电流 | mA |

2. **AppleSMC 只读键**

   `SMCReader` 使用固定 80 字节的 `SMCKeyData` 结构，通过 `IOConnectCallStructMethod` 的 `kSMCGetKeyInfo`（selector 9）和 `kSMCReadKey`（selector 5）读取：

   | 键 | 含义 |
   | --- | --- |
   | `PSTR` | 系统总功耗（float，小端） |
   | `PDTR` | DC-in 输入功率 |
   | `PPBR` | 电池功率 |
   | `B0AV` / `B0AC` | 电池电压 / 电流 |
   | `TB0T` | 电池温度 |

   结构体布局通过 `MemoryLayout<SMCKeyData>.stride == 80` 保证。键值解析覆盖 `flt `、`sp78`、`sp87`、`fp88`、`ui8/ui16/ui32`、`si8/si16/si32`、`flag`。

3. **IOPowerSources**

   作为最终回退：`IOPSCopyPowerSourcesInfo`、`IOPSGetPowerSourceDescription`、`IOPSCopyExternalPowerAdapterDetails`。提供电源状态、当前/最大电量、充放电时间、适配器额定功率。

4. **AppleSmartBattery 基础字段**

   `Voltage`、`Amperage`/`InstantAmperage`、`CurrentCapacity`、`MaxCapacity`、`BatteryData`、`DesignCapacity`、`NominalChargeCapacity`、`CycleCount`、`Temperature`、`AvgTimeToEmpty`、`AvgTimeToFull`、`AdapterDetails`。

#### 分流公式

```text
V = Voltage / 1000
I = Amperage / 1000
measuredChargeW = |V × I|               （IsCharging 时）

inputW   = PDTR 或 SystemPowerIn/1000 或 适配器额定功率（最后回退）
chargeW  = IsCharging ? measuredChargeW : 0
supplyW  = max(0, inputW − chargeW)
systemW  = supplyW                       （接入电源且充电）
systemW  = inputW                        （接入电源、未充电/已充满）
systemW  = |V × I| 或 BatteryPower       （电池供电）
```

充满/涓流时 `chargeW = 0`，充电支路不绘制流动粒子，只保留浅浅的虚线路径说明「已充满」。

`isSplitEstimated` 在输入功率或充电功率缺少直接测量时为 true，UI 显示「估算」。`dataSource` 保存芯片与具体数据源，悬停能量卡可看到。

#### Intel / Apple Silicon 差异

| 能力 | Apple Silicon | Intel Mac |
| --- | --- | --- |
| `PowerTelemetryData` | 通常有，数值细 | 通常没有 |
| SMC `PSTR` / `PDTR` | 可用（本机验证） | 多数可用，机型相关 |
| `AppleSmartBattery` 电压/电流 | 可用 | 可用 |
| 适配器额定功率 | 可用 | 可用 |
| 电池健康 / 循环 / 温度 | 可用 | 可用 |
| 分流精度 | 较高 | 可能为估算 |

SMC 与 `PowerTelemetryData` 是未公开接口，不同 macOS/机型可能变化。应用以「可用则用，否则回退，再否则明确标注」为原则，不把缺失数据伪造为 0。

### 2.6 进程详情

不再启动 `/bin/ps`，而是使用 libproc：

- `proc_listallpids` 枚举进程；
- `proc_pid_rusage(pid, RUSAGE_INFO_V2, ...)` 读取累计 CPU 时间与 `ri_phys_footprint`；
- `proc_name` 取短名称；
- `proc_pidinfo(PROC_PIDTBSDINFO)` 取启动时间。

首次展开时，先采一次，等待 0.32 秒再采一次，用两次 CPU 时间的差值除以真实经过时间得到当前 CPU 百分比；后续调用沿用上一组样本。这样可以避免显示进程生命周期平均值。进程详情只在指标卡展开时按需读取，不参与后台 2 秒轮询。

### 2.7 采样调度

```text
timer interval = min(refreshInterval, powerRefreshInterval)
  refreshInterval ∈ {1s, 2s}
  powerRefreshInterval ∈ {2s, 5s, 10s}
```

- 每 tick 判断是否到达指标采样 / 功耗采样阈值；
- 采集在 `com.claudemonitor.sampling` 串行队列执行；
- 主线程只接收快照并更新 `@Published` 状态；
- 历史序列按真实时间裁剪到最近 60 秒，容量 120 点以兼容 1 秒刷新。

## 3. 系统索引扫描

`IndexScanner` 的目标：

```text
/System/Volumes/Data/.Spotlight-V100
/private/var/db/Spotlight
/System/Volumes/Data/.fseventsd
/System/Volumes/Data/.DocumentRevisions-V100
~/Library/Metadata/CoreSpotlight
```

### 3.1 直接读取

对每个目标先做一次顶层 `contentsOfDirectory` 访问探测（比 `isReadableFile`/`access(2)` 更接近真实 TCC 行为），再使用 `FileManager.enumerator` 遍历，累加 `totalFileAllocatedSize`（回退 `fileSize`）。统计文件数与大小，失败时记录 `permissionLimited` 并保留部分结果。

### 3.2 macOS 26/27 的 Spotlight 特殊保护

macOS 26/27 对 `/System/Volumes/Data/.Spotlight-V100` 做了额外系统保护：

- **即使 App 有完全磁盘访问，第三方进程也不能直接读取该目录**；
- 用于列出索引内容的 `mdutil -L` 本身要求 **root**；
- 旧版本把「该目录不可读」误判为「FDA 未授予」。

因此 `IndexScanner` 分两条路径：

1. **FDA 状态检测**改用真正由 TCC 保护的用户路径：
   `~/Library/Safari/History.db`、`~/Library/Messages/chat.db`、`~/Library/Mail`、
   `/Library/Application Support/com.apple.TCC/TCC.db`。任意一个可读即认为 FDA 生效，不再使用 `.Spotlight-V100` 作为探针。
2. **Spotlight 管理员读取**：
   - 只在用户点击「管理员读取」时执行，不在 6 小时自动扫描中弹窗；
   - 通过 `osascript` 的 `do shell script ... with administrator privileges` 调用
     `/usr/bin/mdutil -L /System/Volumes/Data`；
   - macOS 负责管理员密码弹窗，App 不接收、不保存密码；
   - 输出是 `ls -l` 风格列表，取第 5 个空白分隔字段（文件长度）求和，并统计以 `-` 开头的常规文件行；
   - 该数值是文件长度合计，不含 Spotlight 的 `Cache` 目录，因此与 `du` 的分配块大小可能有差异；
   - 授权被取消或输出无法解析时，保留不可读状态并显示错误，不会伪造数字。

### 3.3 缓存与合并

- 启动时若缓存结果超过 6 小时会自动扫描；
- 手动「重新扫描」立即执行；
- 结果与完成时间写入 `index-result.json`，下次启动先显示缓存；
- 普通扫描若发现 Spotlight 仍不可读，但缓存里已有上次管理员读取值，则保留该值并标记「上次管理员读取」，避免 6 小时自动刷新把可用数据覆盖成 0；
- 显示「数值 + 占磁盘百分比」；
- 展开可查看每个分类的大小、路径与权限状态。

文件：[`IndexScanner.swift`](../Sources/ClaudeMonitor/Storage/IndexScanner.swift)

> 如果只需要 Spotlight 大小，管理员读取不依赖 FDA；FDA 仍然影响 FSEvents、受保护用户目录与异常快照的完整性。

## 4. 每日存储异常检测

### 4.1 扫描器

C 层 [`CStorageScanner.c`](../Sources/CStorageScanner/CStorageScanner.c) 使用 `fts_open`：

- `FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV`
- 不跟随符号链接，不跨挂载点；
- 跳过缓存、容器、iCloud、回收站、`.Spotlight-V100`、`.fseventsd` 等；
- 文件大小使用 `st_blocks × 512`，更贴近磁盘实际占用；
- 单文件记录下限 10 MB，目录聚合下限 20 MB，目录深度仅 1–2 层；
- 进度回调每约 90 ms 一次；
- 权限错误不中断整体扫描，只标记 `permission_limited`。

默认根：

```text
~
/Applications
/Library
/private/var/db
/private/var/log
```

### 4.2 快照与对比

`StorageBaseline` 序列化为 JSON：

```json
{
  "createdAt": "...",
  "files": { "/path": { "size": 123, "modifiedAt": "..." } },
  "directories": { "/path": 456 },
  "totalBytes": 0,
  "scannedFiles": 0,
  "permissionLimited": false
}
```

对比规则：

- 文件前后差 ≥ 阈值 → 文件级异常；
- 目录前后差 ≥ 阈值 → 目录级异常；
- 已在文件级解释 ≥ 68% 的目录变化不重复列出；
- 父子目录同时变化时优先保留更具体、解释度足够高的条目；
- 最多保留 40 条，按绝对变化量排序。

对于新增文件，变化时间取文件修改时间；删除、目录变化取本次扫描时间。

### 4.3 调度

- 首次运行：建立基线，不发通知；
- 每日在设置的本地时间运行；
- 若到点前退出，下次启动时补跑；
- 若距离上次扫描超过 26 小时，也会补跑；
- 用户点击「立即检测」时立即对比当前基线与当前状态；
- 完成后更新基线，并持久化最新报告；
- 有异常时调用 `NotificationManager.notifyStorage`，同时通知面板定位到异常区。

### 4.4 性能

本机（M2 / 8 GB / 约 80 万文件）实测：

- C 扫描器在普通终端基准：**805,787 文件 / 22.45 秒**；
- 应用内 utility QoS + UI 同时运行：约 **50 秒**；
- 基线 JSON：约 **176 KB**；
- 记录文件：1,045 个；目录聚合：167 个。

每日一次的后台扫描不会常驻占用 CPU；扫描器不创建每文件子进程。

## 5. 状态栏与面板

### 5.1 为什么不用 `MenuBarExtra`

`MenuBarExtra` 从 macOS 13 才可用，而需求要求支持 macOS 12。应用改用：

- `NSStatusItem` + 自绘 `NSImage` 状态图标；
- 自定义 `NSPanel`（`.borderless` + `.nonactivatingPanel`，但 `canBecomeKey = true`）；
- `NSHostingView` 承载 SwiftUI 面板。

这样同时得到菜单栏集成、键盘焦点、圆角透明窗口与自定义阴影。

### 5.2 状态图标

`StatusIconRenderer` 用 AppKit 画六瓣陶土色小花：

```text
load < 60     珊瑚 #C96442
60 ≤ load < 85 蜂蜜 #DCA84F
load ≥ 85     警示红 #B84C3C + 0.62s 透明度闪烁
```

负载取 CPU、GPU、内存三者最高值；磁盘容量是长期状态，不参与图标颜色，避免常年 67% 占用的磁盘让图标一直发黄。悬停时重新绘制略大的图标（1.06×），并更新 tooltip。

### 5.3 面板行为

- 点击状态栏：toggle；
- 打开：淡入 + 由下向上 9 pt 位移动画（0.24s）；
- 关闭：淡出 + 向下 7 pt（0.18s）；
- 全局鼠标 monitor：点击应用外关闭；
- `NSApplication.didResignActiveNotification`：应用失去焦点也关闭；
- 本地 key monitor：Esc / ↑ / ↓ / Enter；Esc 在设置页先返回概览，再关闭面板；
- ↑ / ↓ 按固定顺序移动焦点：能量 → CPU → GPU → 内存 → 磁盘 → 存储 → 异常 → 立即检测 → 刷新 → 设置；
- 焦点变化自动滚动到对应区块；Enter 对焦点执行当前动作；
- 面板宽度 382 pt，可见卡片 354 pt；最大高度 830 pt 或屏幕可见高度 −22 pt，内容滚动。

### 5.4 键盘导航测试

在应用内通过 `NSApp.postEvent` 注入真实 keyDown 事件，验证：

- `keyCode 125`（↓）→ 焦点移动到 CPU；
- `keyCode 36`（Return）→ 展开 CPU 详情；
- `keyCode 53`（Esc）→ 面板关闭；
- 结果：`visibleAfterEscape=false`。

## 6. 能量分流动画

`PowerFlowDiagram` 由 SwiftUI `Canvas` 绘制：

- 输入端节点 → 分流节点 → 供能 / 充电支路；
- 支路宽度：`1.5 + share × 5.2`；
- 粒子数量：`max(7, 6 + share × 14)`；
- 粒子速度：`0.14 + share × 0.46` 周期/秒；
- 三次贝塞尔曲线采样粒子位置；
- 粒子以奶油色小光点 + 彩色 glow 绘制，叠加在陶土/蜂蜜色能量带上；
- 供能支路珊瑚色，充电支路蜂蜜色，电池供电鼠尾草色；
- 充满时充电支路只画浅色虚线，不画粒子；
- 悬停支路标签：提亮支路、放大数值、显示底色；
- 点击画布或模式按钮：功率 → 占比 → 电池详情。

`FlowAnimator` 是一个约 60 fps 的 `Timer`，使用指数缓动：

```text
next += (target − current) × 0.11
```

因此功率跳变不会生硬地改变条带宽度。ticker 只在面板可见、`powerFlowAnimationEnabled == true` 且 `reduceMotion == false` 时运行；面板收起或关闭动画后立刻停止。

## 7. 小 Claude 宠物

### 7.1 造型

[`PetMascotView.swift`](../Sources/ClaudeMonitor/UI/PetMascotView.swift) 纯 SwiftUI 绘制：

- 六片圆角胶囊花瓣，陶土色纵向渐变，绕中心每 60° 旋转；
- 奶油色圆脸、轻微高光、柔光阴影；
- 眼睛、腮红、嘴巴根据 `PetMood` 切换；
- 顶部小 `!` / `?` 提示气泡；
- 不使用 Lottie、图片或第三方动画库。

### 7.2 状态

| 状态 | 触发 | 表情 |
| --- | --- | --- |
| calm | 负载正常 | 微笑 |
| curious | 负载偏高 | 歪头 + `?` |
| concerned | 负载过载或功耗提醒 | 关切眉 + 平嘴 |
| surprised | 存储异常 / 有异常报告 | 睁大眼 + `!` |
| working | 扫描 / 检测中 | 月牙眼 + 工作闪光 |
| happy | 用户点击 | 开心月牙眼 + 微笑 |

### 7.3 动画

- 呼吸：2.8 秒往复，scale 0.985 ↔ 1.035，轻微上下浮动；
- 眨眼：2.8–5.8 秒随机间隔，0.08 秒闭合；
- 点击：spring 压缩后回弹，并显示一句状态文案；
- 工作状态：右上角 sparkle 旋转；
- 面板隐藏或关闭宠物动画时停止眨眼与呼吸；
- 减少动态效果时全部静态化。

导出图：[`Docs/images/pet-expressions.png`](images/pet-expressions.png)

## 8. 通知

`NotificationManager` 封装 `UNUserNotificationCenter`：

- 注册 `CM_STORAGE_ANOMALY`、`CM_POWER_ALERT` 分类，带「查看详情」动作；
- 存储通知正文由 `AnomalyReport.notificationSummary` 生成；
- 点击通知或动作 → `PanelDestination.anomaly` / `.energy` → `PanelController.show(destination:)`；
- 通知声音受设置控制；
- 高功耗提醒会在持续条件满足 3 分钟后发出，且限频 1 小时；
- 应用未获得通知权限时静默失败，面板内报告不受影响。

## 9. 设置与持久化

`AppSettings` 是 `@MainActor ObservableObject`，每个属性在 `didSet` 中写入 `UserDefaults`：

- `cm.refreshInterval`：1 / 2；
- `cm.powerRefreshInterval`：2 / 5 / 10；
- `cm.powerUnit`：watt / btu；
- `cm.anomalyThresholdMB`：100–5000；
- `cm.dailyHour` / `cm.dailyMinute`；
- `cm.notificationsEnabled` / `cm.notificationSoundEnabled`；
- `cm.petAnimationsEnabled` / `cm.reduceMotion` / `cm.powerFlowAnimationEnabled`。

快照与报告不在 UserDefaults 中，而是位于：

```text
~/Library/Application Support/ClaudeMonitor/
├── storage-baseline.json
├── anomaly-report.json
└── index-result.json
```

## 10. 主题与可访问性

- 纸面色 `#F5EFE4`，卡片 `#FFFBF5`，墨色 `#39342A`；
- 珊瑚 `#C96442`、蜂蜜 `#DCA84F`、鼠尾草 `#7F9270`、警示 `#B84C3C`；
- 标题 New York / serif，数值 SF Rounded，信息文字 SF；
- 圆角：面板 24，能量卡 22，指标卡/设置卡 16；
- 所有可点击图标提供 `.help` 与语义；
- 卡片与按钮支持悬停反馈，键盘焦点用珊瑚描边标识。

## 11. 构建与运行

```bash
./scripts/build-app.sh
open build/ClaudeMonitor.app
```

脚本行为：

1. 用 `clang` 编译 `Sources/CStorageScanner/CStorageScanner.c`；
2. 用 `swiftc` 或 `swift build -c release` 编译 SwiftUI App；
3. 生成 `Contents/Info.plist`、拷贝 `AppIcon.icns`；
4. 使用 ad-hoc 签名。

部署目标 `macOS 12.0`。本机使用 Swift 6.0.3 + macOS 15.2 SDK 以 `arm64-apple-macosx12.0` 进行构建验证；全部工程源码（约 8,000 行，含 C 扫描器与测试）通过编译，零错误。

## 12. 测试

```bash
./scripts/smoke-test.sh
```

当前结果：

```text
StorageScannerSmoke: PASS
 - file changes: 2
 - directory changes: 1
 - scanned files: 14
IndexScannerSmoke: PASS
 - bytes: 2097152
 - files: 4
 - mdutil rows: 2
```

测试目录使用工作区内的隔离临时路径，结束后自动清理。

## 13. 已知限制与后续改进

- GPU 指标依赖 `IOAccelerator`，某些驱动不公开；可考虑在用户明确授权下增加 IOReport 选项。
- 功耗分流是推导值；若需要严格的电源路径测量，需要更多 SMC 键或外接功率计。
- 存储扫描为控制成本跳过部分目录；可在设置中增加自定义扫描根与排除规则。
- 通知与完全磁盘访问受 TCC 影响；正式分发需 Developer ID + 公证。
- macOS 26/27 的 Spotlight 索引必须由用户主动触发一次管理员授权；管理员密码弹窗由 `osascript`/macOS 呈现，不能自动静默完成。
- ad-hoc 签名会把 TCC 授权绑定到 cdhash；每次重新构建后，需要在「完全磁盘访问」中移除并重新添加 App。正式发行请使用 Developer ID 或稳定的本地签名证书。
- 可进一步把日期格式、字符串与关于信息本地化为英文/多语言。
