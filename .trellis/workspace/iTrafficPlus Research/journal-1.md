# Journal - iTrafficPlus Research (Part 1)

> AI development session journal
> Started: 2026-09-04

---



## Session 1: iTrafficPlus m11 验证 + Trellis 脚手架初始化
<!-- trellis-session: v=2 fp=66f35431562c3ca4 -->

**Date**: 2026-09-04
**Task**: iTrafficPlus m11 验证 + Trellis 脚手架初始化
**Branch**: `main`

### Summary

里程碑11(同名进程合并 + 可配置刷新间隔)代码完成并通过逻辑验证; 安装并初始化 Trellis AI 脚手架, 建立项目记录与规范层

### Main Changes

- m11 同名合并逻辑与刷新间隔链路验证通过 (verify_merge.swift 6/6)
- 全局安装 @mindfoldhq/trellis, 项目内 trellis init --trae

### Git Commits

| Hash | Message |
|------|---------|
| `cb3a59b` | iTrafficPlus 0.3.0 changelog: add milestone 11 section |

### Testing

- [OK] verify_merge.swift: sameNameCollapses/caseInsensitive/order/idempotent/empty 全部 PASS

### Status

[OK] **Completed**

### Next Steps

- 用户 GUI 确认刷新间隔动态切换; 通过后 commit m11 收尾并前移 v0.3.0 tag


## Session 2: m12 多语本地化(zh-Hans/en/zh-Hant) + 排序/间隔 UX 修复
<!-- trellis-session: v=2 fp=2858c76d4cb92fef -->

**Date**: 2026-09-04
**Task**: m12 多语本地化(zh-Hans/en/zh-Hant) + 排序/间隔 UX 修复
**Branch**: `main`

### Summary

完成三语本地化(跟随系统+手动覆盖)并修复验证中暴露的三个时序坑; 排序选项与列对齐+立即生效; Trellis 规范沉淀

### Main Changes

- LocalizationManager + 三语 Localizable.strings + Settings Language 下拉
- 修复 @Published willSet 竞态(refreshInterval/sortMode 慢一拍): sink 改用事件值
- segmented Picker 标签不随语言刷新(.id 重建) + 静态窗口高亮延迟(@State 镜像 Binding)
- localizedString 取词改哨兵判断(英文 value==key 陷阱); 排序选项重排+表头+总量列

### Git Commits

| Hash | Message |
|------|---------|
| `079722c` | iTrafficPlus 0.3.0 milestone 12 (multi-language zh-Hans/en/zh-Hant with runtime switch; sort UX: immediate apply, column-matched order, total column) |
| `8cad6a3` | iTrafficPlus 0.3.0 milestone 11 tests: same-name merge unit tests + standalone verify script |

### Testing

- [OK] plutil -lint 三语 strings OK; xcodebuild BUILD SUCCEEDED; 用户 GUI 验证语言切换/间隔单击生效/排序立即生效

### Status

[OK] **Completed**

### Next Steps

- 实现 09-04-history-heatmap(接口历史持久化+热力图+独立窗口)


## Session 3: m13 历史窗口热力图 + 接口历史持久化 + Bytetally 覆盖补全
<!-- trellis-session: v=2 fp=f7140172c63767c1 -->

**Date**: 2026-09-05
**Task**: m13 历史窗口热力图 + 接口历史持久化 + Bytetally 覆盖补全
**Branch**: `main`

### Summary

实现独立历史窗口:interface_history 持久化+本地小时桶AVG聚合+范围/类别过滤+双方向热力图; 对照 Bytetally 官方功能清单补建 5 个 A 类任务(quota/anomaly/export/knowledge-base/menubar)

### Main Changes

- interface_history 表+写入管道(归一化单点)+heatmap 查询; HistoryWindowView/HeatmapView/Model 三新文件; popover ⤢ 入口
- Bytetally 对照:补建 quota-alerts/upload-anomaly-alerts/data-export/process-knowledge-base/menubar-display-mode; B 类(NE 依赖)维持不做

### Git Commits

| Hash | Message |
|------|---------|
| `7746205` | iTrafficPlus 0.3.0 milestone 13 (history window: hour×day heatmap, interface history persistence, range/category filters, two directions) |

### Testing

- [OK] verify_history.swift 15/15 PASS; xcodebuild BUILD SUCCEEDED; 用户 GUI 验证热力图窗口

### Status

[OK] **Completed**

### Next Steps

- 启动 09-05-process-usage-history: 分钟级预聚合管道+process_usage 表+历史窗口 Apps 标签页


## Session 4: m14 程序用量历史(分钟预聚合) + Bytetally A 类任务补全
<!-- trellis-session: v=2 fp=7af7eb251dceda03 -->

**Date**: 2026-09-06
**Task**: m14 程序用量历史(分钟预聚合) + Bytetally A 类任务补全
**Branch**: `main`

### Summary

实现 process_usage 分钟级预聚合管道与历史窗口 App usage 标签页(四时间维度+排序+总计); 完成 Bytetally 功能覆盖检查并补建 5 个 A 类任务

### Main Changes

- process_usage 表 + ProcessUsageAggregator(bytes=sumBps×interval, interval 变更前 flush, 同名合并)
- AppUsageView/ProcessUsageModel + 历史 Tab 切换(热力图|程序用量); verify_process_usage 12/12

### Git Commits

| Hash | Message |
|------|---------|
| `fe48d87` | chore(task): archive 09-05-process-usage-history |

### Testing

- [OK] verify_process_usage.swift 12/12 PASS; xcodebuild BUILD SUCCEEDED

### Status

[OK] **Completed**

### Next Steps

- 待做队列: quota-alerts → menubar-display-mode → upload-anomaly-alerts → data-export → process-knowledge-base


## Session 5: m14 修复:程序用量列表显示重复名称(pid 缓存槽冲突)
<!-- trellis-session: v=2 fp=9c2c63a8373d8a58 -->

**Date**: 2026-09-06
**Task**: m14 修复:程序用量列表显示重复名称(pid 缓存槽冲突)
**Branch**: `main`

### Summary

getAppInfo 按 pid 缓存导致聚合行全部命中 pid-0 缓存槽显示同一名字; 新增按进程名缓存的 getAggregatedAppInfo(仅借图标,显示名保持真实进程名)

### Git Commits

| Hash | Message |
|------|---------|
| `0faa8bf` | iTrafficPlus 0.3.0 fix (m14): App usage rows showed one duplicated name — getAppInfo cached by pid 0; new name-keyed getAggregatedAppInfo |

### Testing

- [OK] sqlite 验证数据层无重复(name_variants=1); 用户确认显示正常

### Status

[OK] **Completed**

### Next Steps

- quota-alerts + menubar-display-mode(共享 UsageAggregator)
