# 小说趋势追踪系统

这是一个无外部依赖的本地全栈应用：PowerShell 后端提供 API、评分计算和快照导入，前端用原生 HTML/CSS/JS 展示每日推荐、近期活跃榜和长篇留存榜。

## 启动

```powershell
.\start.ps1 -Port 5177
```

打开：

```text
http://localhost:5177
```

运行检查：

```powershell
.\tests\run.ps1
```

## 评分方案

近期活跃榜用于判断近一周到三个月内作品对读者的吸引力：

- 月票动能 30%：按近 30 天增量计算，检测到月度重置时按当期新增处理。
- 推荐票增长 22%：按累计互动增量计算，若快照回退则降低该段可信度。
- 章节讨论活跃 20%：评论增量和新增章节评论密度共同计入。
- 评分脉冲 16%：裸评分经过评分人数贝叶斯收缩，再结合近 30 天评分变化。
- 更新稳定 12%：近 7 日更新字数越稳定，近期推荐权重越高。

长篇留存榜用于完本或 200 万字以上作品：

- 贝叶斯评分 30%：避免少量高分带来的误判。
- 留存指数 20%：近期互动日均与历史日均比较，衰减指数越低越好。
- 评论密度 18%：章节评论数除以章节数。
- 推荐密度 17%：推荐票除以百万字数。
- 评分稳定 15%：近 90 天评分波动越小越好。

## 数据接入

当前仓库内置的是可运行的示例快照，字段在 `data/snapshots.json`：

```json
{
  "bookId": "sample-001",
  "capturedAt": "2026-04-30",
  "monthTickets": 2890,
  "recommendTickets": 43800,
  "rating": 8.48,
  "ratingCount": 2410,
  "chapterComments": 18300,
  "chapterCount": 214,
  "updatedWords7d": 52000,
  "source": "qidian-import"
}
```

生产追踪建议用“发现书籍 -> 每日快照 -> 排名计算”的管线：

- 发现书籍：从起点书库、分类页、排行榜或许可数据源发现 `bookId`。
- 每日快照：保存月票、推荐票、评分、评分人数、章节评论数、章节数、近 7 日更新字数。
- 导入方式：把快照 JSON 放到 `data/inbox/qidian-snapshot.json` 后调用刷新接口，或直接 POST `/api/import/snapshots`。
- 自动化：后端运行时，使用 `scripts/daily-refresh.ps1` 调用刷新；需要系统定时任务时运行 `scripts/register-daily-task.ps1`。

匿名请求起点页面可能返回风控探针页。这个项目不会读取或窃取浏览器登录 Cookie；如果你有合规授权的数据源，可以通过 `QIDIAN_COOKIE` 或导入文件接入采集器。

## 半自动追踪

页面里新增了“半自动追踪”工作台。推荐流程：

1. 在你已登录的浏览器里打开页面里的建议追踪范围，比如月票榜、推荐榜、完本页或分类页。
2. 复制页面源码、保存后的 HTML 内容，或选中页面可见文本后复制。
3. 粘贴到“页面 HTML 或可见文本”，填写页面地址和快照日期。
4. 点击“导入快照”。

系统会从页面内容中发现起点书籍链接，并尽力解析：

- `bookId`
- 书名、作者、分类、状态、字数
- 月票、推荐票、评分、评分人数
- 章节评论数、章节数

如果页面只包含书籍链接但没有可解析指标，系统会先把书加入追踪队列，不写入评分快照。

## API

- `GET /api/health`
- `GET /api/books`
- `GET /api/targets`
- `GET /api/recommendations?mode=daily|active|retention`
- `GET /api/books/{id}/history`
- `POST /api/track/refresh`
- `POST /api/import/snapshots`
- `POST /api/import/qidian-html`
- `GET /api/scheme`
- `GET /api/collector/status`
