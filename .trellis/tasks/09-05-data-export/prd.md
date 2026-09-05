# CSV/JSON data export（数据导出）

## Goal

把本机数据导出为 CSV 或 JSON——对应 Bytetally #10 的导出侧。

## Scope

- 历史窗口工具栏加"导出"按钮 → `NSSavePanel`（选 CSV / JSON、选路径）。
- 导出维度跟随当前 Tab 与范围：
  - 热力图 Tab → 小时桶（`timestamp, in_bytes, out_bytes`）
  - 程序用量 Tab（process-usage-history 之后）→ `(date, name, in_bytes, out_bytes)` 分钟/小时粒度
  - 接口历史 → `(timestamp, category, in_bytes, out_bytes)`
- CSV：首行表头、UTF‑8（BOM 兼容 Excel）、RFC 4180 转义。
- JSON：对象数组，字段名稳定英文（程序化消费友好）。
- 导出在 db 队列分批读取（30 天数据流式写盘，不整体驻留内存），主线程只等完成回调。
- 文件名含维度与范围（如 `itrafficplus-heatmap-2026-09-04_2026-09-05.csv`）。
- 三语（按钮/成功/失败提示）。

## Out-of-scope

- 定时自动导出、iCloud 同步。

## Acceptance Criteria

- [ ] 三种维度导出的 CSV 用 Numbers/Excel 打开列正确、中文不乱码。
- [ ] JSON 可被 `jq` 解析、字段稳定。
- [ ] 30 天数据导出 < 3 s、内存无峰值（流式）。
- [ ] 取消保存面板无副作用。
