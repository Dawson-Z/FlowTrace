# Process knowledge base（程序知识库）

## Goal

内置常见系统进程的知识库：解释进程作用、标注"限制/断网是否安全"——对应 Bytetally 的知识库功能，让用户看懂 `nsurlsessiond`、`cloudd`、`mds_stores` 这类名字。

## Scope

- 静态知识库文件（Bundle 内 JSON）：每条 `{ name 匹配规则(前缀/精确), 显示名, 说明(三语), 限制风险: safe|caution|risk, 类别: system|app|daemon }`。
- 首批覆盖 macOS 常见 30–50 个：`nsurlsessiond`、`cloudd`、`mds/mds_stores`、`bird`、`photoanalysisd`、`mediaanalysisd`、`backupd`、`softwareupdated`、`kernel_task`、`WindowServer`、`spotify/webkit helper` 模式等。
- 匹配逻辑为纯函数（大小写不敏感、最长匹配优先），可 standalone 验证。
- UI 入口两处：
  - popover 进程行右键/悬停提示（浅实现：tooltip 显示一句话说明）
  - 程序用量 Tab（process-usage-history 后）行详情：完整说明 + 风险标签
- 未知进程显示"未收录"（不猜测）。
- 三语；说明文案为静态内容，无网络请求（符合"零网络请求"铁律）。

## Out-of-scope

- 在线知识库更新。
- 限速建议执行（B 类）。

## Acceptance Criteria

- [ ] 已收录进程在 popover 悬停可见一句话说明；用量页可见完整卡片。
- [ ] 匹配规则 standalone 全通过（精确/前缀/大小写/最长优先）。
- [ ] 未收录进程无错误 UI。
- [ ] 三语完整；零网络请求。
