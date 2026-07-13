# JM API Suwayomi Extension

This repository builds a small Tachiyomi/Suwayomi extension APK for your JM PHP API:

- API base URL: `http://127.0.0.1:8088`
- Package: `eu.kanade.tachiyomi.extension.zh.jmapi`
- Search input: JM ID, `JM350234`, album URL, or `?jmid=350234`
- Lists: Suwayomi Popular maps to original homepage recommendations; Suwayomi Latest maps to original weekly picks
- Title search: supported through `?search=...`

Search sorting works with or without a title keyword. An empty keyword browses the full catalog; JM ID or album URL lookup returns the exact album and does not apply sorting.

## How it works

`index.min.json` cannot call a PHP API directly. Suwayomi reads `index.min.json`, downloads an APK, and the APK calls the API. This project builds that APK and generates a complete Suwayomi extension repository:

- `apk/tachiyomi-zh.jmapi-v1.4.9.apk`
- `icon/eu.kanade.tachiyomi.extension.zh.jmapi.png`
- `index.min.json`
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
4. Open the source settings if needed and set the API base URL.
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

API prefetch is enabled by default. This means image requests do not include `prefetch=0` unless you explicitly change the extension setting. On weak hosts, or when Suwayomi preloads too aggressively, enable `Disable API prefetch` in the source settings. After that, generated API image requests include `prefetch=0`.

## Local static check

This machine does not need Android SDK for the static contract check:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\extension-contract.ps1
```

