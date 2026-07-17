# JM API Suwayomi 扩展深化设计与交付基线

日期：2026-07-17  
状态：扩展端实现、静态/安全合同、真实构建、仓库元数据和 Suwayomi 2.3.2243 实际回归均已完成；结果汇总见 `D:\jm\jmcomic-api-main\docs\performance-delivery-report.md`。

## 1. 项目与版本

- 扩展项目：`D:\jm\jmapi-extension`
- API 项目：`D:\jm\jmcomic-api-main`
- Kotlin 主文件：`D:\jm\jmapi-extension\src\zh\jmapi\src\eu\kanade\tachiyomi\extension\zh\jmapi\JmApi.kt`
- DTO：`D:\jm\jmapi-extension\src\zh\jmapi\src\eu\kanade\tachiyomi\extension\zh\jmapi\Dto.kt`
- 当前目标版本：`1.4.13`
- 构建配置：`versionCode = 13`、`libVersion = "1.4"`
- 目标 APK：`tachiyomi-zh.jmapi-v1.4.13.apk`

扩展只访问 PHP API，不直接访问 JM 上游。API 端口保持 `8088`。

## 2. 不可破坏契约

- Popular 必须映射为 `list=promote`，展示原站首页推荐。
- Latest 必须映射为 `list=weekly`，展示原站每周精选。
- 空搜索使用 `list=popular`；标题搜索使用 `search=<query>`；JM ID/URL 使用 `jmid=<id>`。
- 筛选值固定为“最新 / 最多浏览 / 最多点赞”。空搜索映射为 `new/mv/tf`，标题搜索映射为 `mr/mv/tf`。
- JM ID/URL 分支必须只使用 `format=min&jmid=<id>`，不得附带 `page` 或 `order`；分页只属于空搜索列表和标题搜索。
- PHP API JSON、章节阅读顺序、图片 URL 契约保持兼容。
- 不在 APK 中解码或缓存图片字节，不引入文件缓存或 Redis，不直连 JM 上游。
- 没有真实 Suwayomi 请求证据时不得修改 `initialized`。

## 3. 当前实现设计

### 3.1 中文化

用户可见内容统一为中文：

- 筛选标题：“排序”
- 设置标题：“JM API 地址”“禁用 API 预取”
- DTO 文本：“浏览 / 点赞 / 评论 / 章节 / 第…章”

只翻译显示文本，不改变筛选值和请求映射。

### 3.2 Base URL 快照

运行时地址使用不可变 `ApiEndpoint`：

```kotlin
private data class ApiEndpoint(
    val rawPreference: String,
    val baseUrl: HttpUrl,
    val basePath: String,
)
```

读取规则：

1. 原始偏好和缓存一致时复用快照。
2. 偏好变化时立即重新解析、校验并替换缓存，不能永久 `lazy`。
3. 允许根路径和反向代理子路径。
4. 拒绝 userinfo、query、fragment、`0.0.0.0` 和 IPv6 未指定地址 `::`；安全检查先移除绝对 DNS 尾点，因此 `0.0.0.0.`、`00.0.0.0.` 等全零形式也必须拒绝，但普通域名尾点不受影响。
5. 所有请求和展示 URL 统一使用 `HttpUrl.Builder`，禁止字符串拼接。

同源判断必须精确比较 scheme、host、port 和规范化 path segments。`/api` 与 `/api/` 等价，但不能匹配 `/api2` 或 `/api/other`。

### 3.3 预取开关双向生效

最终状态以 `imageRequest()` 发出请求时的当前偏好为准：

- 开启“禁用 API 预取”时，对同一 API decoded-page URL 设置 `prefetch=0`。
- 关闭该设置时移除全部旧 `prefetch` 参数。
- 已经加载到内存的章节 URL 也必须随当前设置改变。
- 外部 CDN、同主机其他 base path、非 decoded-page URL 不得改写。

这解决了旧实现把 `prefetch=0` 固化在 `Page.imageUrl` 后无法重新启用预取的问题。

### 3.4 ID 与章节匹配

- 所有 JM ID 均限制为 1～20 位数字。
- `JM` 前缀正则使用尾部数字边界，21 位 ID 必须整体拒绝，不能截取前 20 位。
- 旧库 album URL 先去除尾斜杠，再提取和校验 ID。
- `pageListParse()` 必须按请求 URL 中的 chapter ID 精确选择 `photoId`；找不到时抛出包含 requested ID 的明确错误，禁止静默使用第一个章节。

### 3.5 URL 构造范围

以下路径全部从规范化 `HttpUrl` 构建：

- Popular、Latest、空搜索、标题搜索、JM ID 搜索
- 详情、章节列表、页面列表
- decoded page fallback
- `getMangaUrl()`、`getChapterUrl()`

参数通过 `addQueryParameter`、`setQueryParameter` 和 `removeAllQueryParameters` 管理，避免反代子路径、转义字符或已有 query 被字符串拼接破坏。

### 3.6 DTO 与请求次数

`JmAlbumEnvelope.toSManga()` 不再接收未使用的 Base URL 参数，避免一次无意义的偏好读取和 URL 解析。

真实 Suwayomi 请求计数已经取得：首次详情与刷新各产生 1 个 `?jmid`，10 路并发详情产生 10 个宿主动作对应的请求，章节列表产生 1 个请求。该结果没有证明 APK 元数据缓存的生命周期风险值得承担；继续由服务端短 TTL album cache 去重上游，不增加 APK 元数据缓存，也不把 `initialized` 当作盲目的性能开关。

## 4. 风险与防护

| 风险 | 防护 |
|---|---|
| 反代 `/api` URL 误改写 `/api2` | path segments 精确相等后再检查 jmid/chapter/page |
| 用户切回启用预取但旧 URL 仍含 `prefetch=0` | 在 `imageRequest()` 双向增删参数 |
| 21 位 ID 被截成 20 位 | `{1,20}` 后增加 `(?!\d)`，完整输入使用 `matchEntire` |
| API 返回其他章节 | 按 requested chapter 精确查找并失败关闭 |
| 设置修改后继续使用旧地址 | 缓存记录 raw preference，变化即失效 |
| 非法 Base URL 造成凭据泄漏或错误请求 | 拒绝 userinfo/query/fragment/未指定地址 |
| junction/符号链接绕过源树、输出树边界 | 使用 Win32 最终物理路径解析已存在祖先和未存在尾段，所有移动、swap、删除前重新校验 |
| 构建隔离改写 Keiyoushi 配置字节 | `settings.gradle.kts` 以原始字节备份并在成功、失败路径中 `WriteAllBytes` 恢复，保留 BOM、编码和换行 |
| `libVersion` 注入路径分隔或 `..` | `libVersion`、组合版本和 APK 名称使用数字点号/文件名白名单，并验证 APK 目标是 staging `apk` 的直接子项 |
| APK 重复服务端缓存逻辑 | 禁止 APK 图片缓存，album cache 优先留在 API |

## 5. 测试与构建

### 5.1 静态合同

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\jm\jmapi-extension\tests\extension-contract.ps1
```

合同必须覆盖中文化、映射、ID 边界、URL Builder、反代 path、预取双向同步、requested chapter、版本、文档、构建脚本和仓库元数据脚本。

### 5.2 Keiyoushi 构建

```powershell
Set-Location D:\jm\jmapi-extension
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-with-keiyoushi.ps1
```

脚本固定使用 `D:\jm\keiyoushi`，复制前验证目标绝对路径，只加载 `zh/jmapi`，依次运行：

```text
:src:zh:jmapi:spotlessApply
:src:zh:jmapi:assembleRelease
```

任一步非零退出都必须失败，不得沿用旧 APK 冒充新构建。

### 5.3 仓库元数据

```powershell
$apk = Get-ChildItem -Recurse -File D:\jm\keiyoushi\src\zh\jmapi\build\outputs\apk\release\*.apk | Select-Object -First 1
& .\scripts\generate-repo-metadata.ps1 -ApkPath $apk.FullName -OutputDir .\dist-local
Get-Content -Raw .\dist-local\index.min.json | ConvertFrom-Json | Out-Null
```

若当前目录是项目根目录，必须在当前 PowerShell 进程直接调用脚本。外层 PowerShell 保持项目根目录并再启动 `powershell -File` 子进程时，外层 Windows 当前目录句柄会阻止子进程取得防删除共享的稳定父目录句柄；该场景必须明确失败，不能降低路径安全门禁。

脚本必须从构建配置读取版本，从 APK 读取签名证书 SHA-256，并生成和回读验证：

- `index.min.json`
- `index.json`
- `repo.json`
- `apk/tachiyomi-zh.jmapi-v1.4.13.apk`
- `icon/eu.kanade.tachiyomi.extension.zh.jmapi.png`

两个 PowerShell 发布脚本共同加载 `scripts/path-safety.ps1`。它通过 `CreateFileW` 与 `GetFinalPathNameByHandleW` 解析 junction 的最终物理路径；对尚未存在的 stage/output 尾段，先解析最近既存祖先再拼接规范化尾段。中间 `src` junction 必须在创建 `zh` 前拒绝。内部 stage/backup 根不得是 reparse point，递归清理逐项处理且绝不跟随 reparse point；同父目录发布使用 `[IO.Directory]::Move` 的精确目标语义，move 后校验失败必须安全反向移动。元数据版本只接受无前导零歧义的数字点号语义，`[IO.Path]::GetFileName(apkName)` 必须与原名称完全相等，并用 `aapt2 dump badging` 校验真实 APK 的 package、versionCode、versionName 与 Gradle 完全一致。

## 6. 真实 Suwayomi 验收结果

已在 Suwayomi-Server 2.3.2243 安装 `v1.4.13 / versionCode 13` 并验证：

1. 筛选实际显示“排序 / 最新 / 最多浏览 / 最多点赞”，设置显示“JM API 地址 / 禁用 API 预取”及中文说明。
2. 当前 Base URL 为 `http://127.0.0.1:18088/api`，反向代理子路径正常。
3. Popular、Latest、空搜索三种排序、标题搜索、JM ID、album URL 和纯数字 ID 均产生设计规定的请求。
4. 详情、章节列表、12 页页面列表和 WebP 图片读取正常。
5. enabled → disabled → enabled 时，图片请求依次移除、添加、再次移除 `prefetch=0`。
6. 请求计数与 `initialized`/APK 元数据缓存决策已经按 3.6 节收敛。

## 7. 完成定义

只有以下条件全部满足才可称扩展交付完成：

- 静态合同新鲜通过。
- PowerShell 5.1 AST 无语法错误。
- Spotless 和 assembleRelease 新鲜通过。
- APK 名称、versionCode、README 和索引一致。
- `index.min.json/index.json/repo.json` 可解析，签名指纹非空且来自实际 APK。
- 可执行的本地验证全部完成，真实 Suwayomi 回归有实际请求证据。

当前上述条件均已满足。Docker 多 worker 验收属于 API 外部环境阻塞，不影响扩展 APK 的本机完成判定。
