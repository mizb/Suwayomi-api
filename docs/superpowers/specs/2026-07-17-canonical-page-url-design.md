# JM API 扩展规范化页面 URL 修复设计

日期：2026-07-17  
范围：`D:\jm\jmapi-extension`，API 对外 JSON 结构不变

## 1. 已确认问题

当扩展 Base URL 配置为反向代理子路径（例如 `http://127.0.0.1:18088/api`）时，API 的章节 JSON 可能返回不含该前缀的绝对图片 URL（例如 `http://127.0.0.1:18088/?jmid=...`）。页面列表仍可成功，但扩展的严格同源检查会正确判定该 URL 不属于已配置 endpoint：

- `imageRequest()` 不会添加或移除 `prefetch=0`；
- 真实反向代理可能把图片请求发送到错误的根路由；
- 本地 PHP router 同时承接根路径时会掩盖故障。

Suwayomi 2.3.2243 的实际验证已证明：开关值在图片请求前后均为 `true`，API 却连续记录 `skipped-low-memory` 而非 `disabled`。直接读取同一章节 JSON 后确认其中的图片 URL 丢失 `/api`。

## 2. 设计决策

`pageListParse()` 不再把上游 JSON 的 `JmImageDto.url` 作为页面请求地址。对 `1..pageCount` 的每一页，统一调用现有 `pageImageUrl(albumId, chapterId, pageNumber)`，从当前受校验的 `ApiEndpoint.baseUrl` 构建 URL。

保留以下行为：

- `page_count > 0` 时仍以其为准，否则使用 `images.size`；
- 章节仍按请求 URL 中的 chapter ID 精确匹配；
- DTO 字段保留，以兼容 API JSON，不改变公共载荷；
- `imageRequest()` 继续负责在最终请求前双向同步 `prefetch=0`；
- `/api` 与 `/api2`、根路径或同主机其他路径仍严格隔离。

## 3. 未采用方案

1. 仅在 API 端支持 `X-Forwarded-Prefix`：依赖部署代理正确转发，无法兼容旧服务或错误载荷。
2. 放宽扩展同源路径判断：会把同主机根路由或其他应用误判为 JM API，违反既有安全契约。
3. 只在响应 URL 为空时回退：当前故障 URL 非空，因此不能修复。

## 4. 失败与安全语义

- album/chapter ID 继续通过既有 1～20 位数字约束产生；页码只来自正整数区间。
- 配置 endpoint 无效时仍在 `apiEndpoint()` 明确失败，不尝试载荷中的备用主机。
- 该修复不会让 APK 直连 JM/CDN，也不会新增缓存、重试或磁盘状态。

## 5. 验收

1. 先扩展合同，要求 `pageListParse()` 对每页使用 `pageImageUrl(...)`，并禁止读取 `chapter.images[..].url` 作为 `Page.imageUrl`；修复前必须按预期失败。
2. 最小修改生产代码后合同通过。
3. 行为版本递增，构建新 APK 并重新生成仓库元数据。
4. 在隔离 Suwayomi 2.3.2243 中安装新 APK，Base URL 保持 `/api`：页面列表与 WebP 图片成功；禁用预取时 API 记录 `disabled`，重新启用后不再增加 `disabled`。
5. 只运行受影响的扩展合同、构建/元数据和真实宿主回归；API 大型性能矩阵不因该扩展修复重复执行。

## 6. 自审

- 无 TODO/TBD 或未决产品选择。
- 与现有 Base URL 路径隔离、预取双向同步和 APK 只访问 PHP API 的契约一致。
- 变更只触及页面 URL 选择及其版本/文档/产物，不扩展为 API 或缓存重构。
