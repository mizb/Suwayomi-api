# JM API Suwayomi Extension

This repository builds a small Tachiyomi/Suwayomi extension APK for your JM PHP API:

- API base URL: `http://127.0.0.1:8088`
- Package: `eu.kanade.tachiyomi.extension.zh.jmapi`
- Search input: JM ID, `JM350234`, album URL, or `?jmid=350234`
- Lists: Suwayomi Popular maps to original homepage recommendations (`list=promote`); Suwayomi Latest maps to original weekly picks (`list=weekly`)
- Title search: supported through `?search=...`

Search sorting works with or without a title keyword. An empty keyword browses the full catalog; JM ID or album URL lookup returns the exact album and does not apply pagination or sorting (`page`/`order` are omitted).

## How it works

`index.min.json` cannot call a PHP API directly. Suwayomi reads `index.min.json`, downloads an APK, and the APK calls the API. This project builds that APK and generates a complete Suwayomi extension repository:

- `apk/tachiyomi-zh.jmapi-v1.4.15.apk`
- `icon/eu.kanade.tachiyomi.extension.zh.jmapi.png`
- `index.min.json`
- `index.json`
- `repo.json`

## Upload to GitHub

Upload the contents of this folder to a new GitHub repository. The repository root should contain:

- `.github/workflows/build-extension.yml`
- `src/zh/jmapi/`
- `scripts/`
- `README.md`

## Stable signing

For testing, the workflow can build without signing secrets. For real use, set stable GitHub Actions secrets first, or Android may reject future APK updates because the signing certificate changed.

If you have JDK 17 locally:

```powershell
.\scripts\generate-signing-key.ps1
```

On Linux, macOS, or GitHub Codespaces:

```bash
bash scripts/generate-signing-key.sh
```

Then add these repository secrets in GitHub:

- `SIGNING_KEYSTORE_BASE64`
- `ALIAS`
- `KEY_STORE_PASSWORD`
- `KEY_PASSWORD`

## Build and deploy

1. In GitHub, open `Settings` -> `Pages`.
2. Set `Build and deployment` -> `Source` to `GitHub Actions`.
3. Open `Actions` -> `Build JM API extension`.
4. Run the workflow.
5. After it passes, use this Suwayomi repo URL:

```text
https://<your-github-username>.github.io/<your-repo-name>/index.min.json
```

The workflow also uploads a `suwayomi-repo` artifact containing the generated repository files.

It also publishes the same generated files to the `repo` branch. If GitHub Pages is slow or not enabled, use this raw URL instead:

```text
https://raw.githubusercontent.com/<your-github-username>/<your-repo-name>/repo/index.min.json
```

## Use in Suwayomi

1. Add the repo URL above to Suwayomi's extension repositories.
2. Install `Tachiyomi: JM API`.
3. Open the source `JM API`.
4. 按需打开源设置，在“JM API 地址”中填写 API Base URL。
5. Browse Popular for 首页推荐, Latest for 每周必看, or search a JM ID/title, for example `350234` or `董卓`.

The extension asks the PHP API for metadata and chapter pages. Page images are loaded from URLs like:

```text
http://127.0.0.1:8088/?jmid=350234&chapter=350234&page=1
```

The PHP API returns chapters in reading order, but the extension gives Suwayomi chapters newest-first as Tachiyomi/Suwayomi sources expect. Chapter numbers are generated from the stable reading order instead of trusting duplicate upstream `sort` values. This keeps new books starting from the first chronological chapter, lets Suwayomi resume from its saved page, and preserves the next-chapter chain.

The default API base URL is:

```text
http://127.0.0.1:8088
```

If Suwayomi runs in Docker with the API service, set the extension API base URL to:

```text
http://jmcomic-api:8088
```

If Suwayomi runs on another device, use the API host LAN address, for example:

```text
http://192.168.1.20:8088
```

`0.0.0.0` is only a server listen address. Do not use it as the Suwayomi client address.

API 预取默认启用，因此图片请求默认不含 `prefetch=0`。弱性能主机或 Suwayomi 预加载过多时，可在源设置中开启“禁用 API 预取”；扩展会在实际 `imageRequest()` 时为同一 API、同一反代路径的 decoded-page URL 设置 `prefetch=0`。重新关闭“禁用 API 预取”后，即使章节已经加载，后续图片请求也会移除旧的 `prefetch` 参数。外部 CDN URL 和同主机的其他应用路径不会被改写。

“JM API 地址”支持根路径和反向代理子路径，例如 `https://example.com/jm-api`。地址不得包含用户名、密码、query 或 fragment，也不得使用 `0.0.0.0`、`::` 及 `0`、`00`、`0.0.0.00`、`0.0.0.0.`、`00.0.0.0.` 等全零数字 IPv4 等价形式；普通绝对 DNS 名（如 `api.example.com.`）仍可使用。修改设置后，扩展会立即重新校验并使用新地址，不需要重装 APK。`127.0.0.1` 只适用于 Suwayomi 进程与 API 位于同一网络命名空间；若 Suwayomi 在独立 Docker 容器内，应填写可从该容器访问的 API 服务名、`host.docker.internal`（平台支持时）或局域网地址。

当前扩展版本为 `1.4.15`（`versionCode = 15`）。筛选标题和设置说明已中文化；筛选值仍固定为“最新 / 最多浏览 / 最多点赞”，其请求映射保持不变。页面图片 URL 始终从当前受校验的 API 地址重建，不再让响应中的绝对 URL 丢失反代子路径或绕过预取开关。

配套 API 交付版本为 `2026.07.17.7`。升级 APK 不要求改变 API JSON，但建议同时重建 API 容器以取得每周推荐字母型 type ID、数字型章节/album/列表 ID 兼容、非法布尔/浮点 ID 拒绝、严格列表总数、失败传播、请求预算、单图内预取字节硬边界、瞬态网络故障每域三次有界恢复、列表/album 缓存、CDN failover 和可信代理修复：

```powershell
Set-Location D:\jm\jmcomic-api-main
docker compose build --no-cache
docker compose up -d --force-recreate
curl.exe "http://127.0.0.1:8088/?health=1"
```

服务端性能策略可按 API README 将 `JM_LIST_CACHE_TTL`、`JM_ALBUM_CACHE_TTL`、`JM_DOMAIN_REFRESH_DEFERRED` 或 `JM_PREFETCH_PAGES` 设为 `0` 后重建容器回滚；扩展 URL/章节正确性修复和 API Redis/CDN schema 只能通过版本回退，不能用这些环境变量恢复旧行为。

## Local static check

This machine does not need Android SDK for the static contract check:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\extension-contract.ps1
```

## 本地完整构建与仓库元数据

使用与 GitHub Actions 相同的 Keiyoushi 路径执行格式化和 release 构建：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-with-keiyoushi.ps1
```

构建成功后生成 `index.min.json`、`index.json`、`repo.json`、APK 和图标目录：

```powershell
$apk = Get-ChildItem -Recurse -File D:\jm\keiyoushi\src\zh\jmapi\build\outputs\apk\release\*.apk | Select-Object -First 1
& .\scripts\generate-repo-metadata.ps1 -ApkPath $apk.FullName -OutputDir .\dist-local
Get-Content -Raw .\dist-local\index.min.json | ConvertFrom-Json | Out-Null
```

从项目根目录执行时应在当前 PowerShell 进程用 `&` 直接调用元数据脚本。不要让另一个仍以项目根目录为当前目录的父 PowerShell 再启动 `powershell -File` 子进程；父进程的 Windows 目录锁会与防目录替换的安全句柄冲突，脚本会按设计 fail-closed。

