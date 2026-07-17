# AI 自主交付指令：JM API 跨项目性能与扩展修复

本文件是后续 AI 的执行边界。提示词只需要求 AI 完整读取并自主执行本文件；主要目标、契约和验收条件都在这里。

当前检查点（2026-07-17）：`v1.4.15 / versionCode 15` 已完成真实构建、元数据和 Suwayomi 2.3.2243 升级回归；`v1.4.14 / 14` 的反代子路径页面 URL 丢失是 RED 历史基线。后续先读取 bug 排查审计、规范化页面 URL 设计与跨项目最终报告并核对哈希；不得把旧版宿主结果冒充为新 APK 结果。

## 角色与停止条件

你是自主高级开发代理。必须直接检查代码、测试先行、实现、排错、复测、构建并写交付证据，不能停在分析、建议或半成品阶段。

只有以下情况可以停止：

1. 计划内代码、测试、文档、构建、元数据和交付报告全部完成，并有新鲜证据；或
2. 已完成所有不依赖外部条件的工作，剩余仅为真实外部阻塞，并给出错误证据和可直接复制的后续命令；或
3. 发现会改变产品目标或公共契约的重大冲突，必须由用户决策。

普通测试失败、工作量大、上下文变长或工具暂时缺失，都不是停止理由。遇到失败必须定位根因、增加或修正测试、做最小修复并复测。

## 权威路径

- API：`D:\jm\jmcomic-api-main`
- 扩展：`D:\jm\jmapi-extension`
- 最终报告：`D:\jm\jmcomic-api-main\docs\performance-delivery-report.md`
- 跨项目设计：`D:\jm\jmcomic-api-main\docs\superpowers\specs\2026-07-13-cross-project-performance-design.md`
- 实施计划：`D:\jm\jmcomic-api-main\docs\superpowers\plans\2026-07-13-cross-project-performance-delivery.md`
- 扩展设计：`D:\jm\jmapi-extension\docs\apk-optimization-design.md`
- 扩展合同：`D:\jm\jmapi-extension\tests\extension-contract.ps1`

开始前完整读取上述设计、计划和当前实现。只修改 `D:\jm\jmcomic-api-main` 与 `D:\jm\jmapi-extension` 的交付源文件；`D:\jm\keiyoushi` 只作为受检构建工作树使用。保留所有用户无关改动，禁止 reset、checkout、revert 或用旧副本覆盖。

## 当前扩展交付目标

- 目标 APK：`v1.4.15`
- `versionCode 15`
- `libVersion = "1.4"`
- APK 文件：`tachiyomi-zh.jmapi-v1.4.15.apk`
- 默认 API：`http://127.0.0.1:8088`

若执行时行为版本已经高于此值，只能递增到更高且统一的新版本，不能降级。

## 不可偏离契约

1. Popular 固定为 `list=promote`；Latest 固定为 `list=weekly`。
2. 空搜索固定为 `list=popular`，排序 `new/mv/tf`；标题搜索为 `search`，排序 `mr/mv/tf`；JM ID/URL 只用 `format=min&jmid=<id>`，不得携带 `page` 或 `order`。
3. 筛选显示“排序 / 最新 / 最多浏览 / 最多点赞”，不得改变映射。
4. API JSON、章节阅读顺序和 decoded-page URL 对外结构保持兼容。
5. APK 只访问 PHP API；不得直连 JM 上游、解码图片、增加图片文件缓存或 Redis 依赖。
6. API 图片/页面缓存继续使用 APCu；Redis 不作为图片缓存。
7. 不新增 `/app/cache` 图片卷，不启用未验证的 `/comic_read` 生产路径。
8. 没有真实 Suwayomi 请求证据不得修改 `initialized`，优先使用 API album cache。
9. 客户端地址不得使用 `0.0.0.0` 或 `::`。
10. API 端口保持 `8088`。

## 扩展必须实现并审计

- 中文设置、筛选标题和 DTO 用户文本。
- `ApiEndpoint(rawPreference, baseUrl, basePath)` 快照；偏好变化立即失效。
- Base URL 允许反代子路径，拒绝 userinfo/query/fragment/未指定地址。
- Base URL 未指定主机检查必须先移除绝对 DNS 尾点，拒绝 `0.0.0.0.`、`00.0.0.0.` 等全零形式且不得误拒绝普通域名。
- 所有请求和展示 URL 使用 `HttpUrl.Builder`。
- 同源 decoded-page 判断精确比较 scheme/host/port/path segments；不得把 `/api2` 或 `/api/other` 当作 `/api`。
- 预取偏好只在 `imageRequest()` 最终双向同步：禁用时设置 `prefetch=0`，启用时移除；外部 URL 不改。
- `pageListParse()` 必须忽略 API 载荷中的绝对 `images[].url`，按当前受校验 endpoint 与 album/chapter/page 重建每页 URL；禁止用放宽 base path 同源规则掩盖反代前缀丢失。
- JM ID 统一为 1～20 位并有尾部数字边界；21 位整体拒绝。
- 单章响应按 requested chapter 精确选择，禁止使用第一个章节兜底。
- 旧 album URL 去除尾斜杠后严格解析。
- 删除 `toSManga(baseUrl: String)` 无效参数，不增加 APK 图片缓存。
- 构建和元数据脚本必须解析 junction 的最终物理路径；移动、swap、递归清理前重新校验，内部 stage/backup 不得是 reparse point，清理不得跟随链接。
- 构建隔离结束后必须按原始字节恢复 `settings.gradle.kts`，BOM、编码、换行和调用者环境变量均不得变化。
- 元数据 `libVersion`、组合版本、APK 名称必须通过数字点号与安全文件名白名单，复制目标必须是 staging `apk` 的直接子项。
- 元数据发布前必须用 `aapt2 dump badging` 核对 APK manifest 的 package、versionCode、versionName；任一项与 Gradle 不一致或工具缺失都必须在 OutputDir 写入/swap 前失败。
- 目录发布使用精确的 `[IO.Directory]::Move(source,destination)`；禁止让已出现的 destination 把 source 静默嵌套，move 后校验失败必须安全回滚并明确报告回滚失败。

## 工作方法

对每个未完成项严格执行：

1. 写或确认能证明目标行为的失败测试。
2. 运行并确认它因目标行为缺失而失败，而不是测试语法或过时断言。
3. 调查根因，只做一个最小修复。
4. 运行聚焦测试和全部相关回归。
5. 复审边界、异常路径、版本和文档一致性。
6. 保存准确输出摘要；未运行的验证不得写“通过”。

若静态合同和权威设计冲突，以权威设计为准，修正互斥或误报的合同，但不得降低行为要求。PowerShell 5.1 对无 BOM UTF-8 中文源码检查应使用 `\uXXXX` 正则或显式 `-Encoding UTF8`。

## 扩展验证命令

```powershell
Set-Location D:\jm\jmapi-extension
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\extension-contract.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-with-keiyoushi.ps1
$apk = Get-ChildItem -Recurse -File D:\jm\keiyoushi\src\zh\jmapi\build\outputs\apk\release\*.apk | Select-Object -First 1
if ($null -eq $apk) { throw 'assembleRelease APK not found under D:\jm\keiyoushi' }
& .\scripts\generate-repo-metadata.ps1 -ApkPath $apk.FullName -OutputDir .\dist-local
Get-Content -Raw .\dist-local\index.min.json | ConvertFrom-Json | Out-Null
Get-Content -Raw .\dist-local\index.json | ConvertFrom-Json | Out-Null
Get-Content -Raw .\dist-local\repo.json | ConvertFrom-Json | Out-Null
```

元数据脚本从项目根目录运行时必须用 `&` 在当前 PowerShell 进程直接调用；不得让仍锁住项目根目录的父 PowerShell 再启动子 PowerShell。外部父目录锁被安全拒绝属于 fail-closed，不得通过放宽句柄共享规则绕过。

必须确认 Spotless、assembleRelease、实际 APK、签名 SHA-256、三个 JSON、APK 名称和版本一致。不得复用旧 APK 充当新鲜构建。

## 跨项目最终验证

先比较最终报告中的源码、APK 和元数据哈希。只有哈希变化时才按影响范围重跑本机验证；哈希未变化时只处理已经具备条件的外部项：

- API、Dockerfile、compose、entrypoint、README 和合同版本统一。
- compose/README 列出全部性能开关、默认值、0 的语义、风险和回滚命令。
- 全部静态合同新鲜通过。
- 可用时执行 Docker build/runtime、fixture 故障注入、Redis 并发、CDN failover、缓存和预取回归。
- 使用相同条件生成 before/after 性能数据；样本不足不得伪报 p95/p99。
- `v1.4.15` 的 Suwayomi 回归已经完成，证据覆盖中文筛选/设置、Popular、Latest、空/标题/ID 搜索、详情、章节、阅读、反代子路径和预取双向切换。除非 APK、设置或宿主版本变化，不重复执行。
- 写入 `D:\jm\jmcomic-api-main\docs\performance-delivery-report.md`，包含文件、行为、完整测试摘要、性能数据、部署/回滚命令、未执行项和剩余风险。

当前机器 Docker 不可用，但 `v1.4.15` 的本机 Suwayomi 回归、API `.2` 当前哈希 A/B 和 after-only 深度证据均已完成。先部署并现场复验 `.2` 的 Latest 502；Docker-capable 主机到位后执行 compose 多 worker/runtime/fault 验收。历史 `.1`/`.13.2` 证据不得与 `.2` 混用；生产密钥未提供时保留为发布治理待办。

## 交付输出

最终只在全部可完成工作收敛后报告：

- 修改文件与关键行为。
- 新鲜测试、构建、运行验证及精确结果。
- APK 和仓库元数据绝对路径、版本、哈希/签名指纹。
- 性能 before/after 数据和测量条件。
- 部署、升级、回滚命令。
- 真实外部阻塞与剩余风险。

不要输出模糊的“建议下一步”。能自主执行的下一步必须继续执行。

## 给 AI 的简短启动提示词

```text
完整读取并严格执行 D:\jm\jmapi-extension\docs\ai-delivery-prompt.md；先核对规范化页面 URL 设计、bug 排查审计、最终报告和当前哈希，保持 v1.4.15/15 与 API 2026.07.17.7 一致，自主完成所有具备条件的验证和交付。失败必须根因诊断、最小修复、相关复测；不得改变固定筛选/API/章节/缓存契约，不得把 v1.4.14 的缺陷复现冒充为新 APK 通过结果，也不得伪造 Git、BEFORE 或性能百分比。
```
