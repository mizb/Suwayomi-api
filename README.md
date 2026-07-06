# JM API Suwayomi Extension

This repository builds a small Tachiyomi/Suwayomi extension APK for your JM PHP API:

- API base URL: `http://0.0.0.0:8088`
- Package: `eu.kanade.tachiyomi.extension.zh.jmapi`
- Search input: JM ID, `JM350234`, album URL, or `?jmid=350234`

## How it works

`index.min.json` cannot call a PHP API directly. Suwayomi reads `index.min.json`, downloads an APK, and the APK calls the API. This project builds that APK and generates a complete Suwayomi extension repository:

- `apk/tachiyomi-zh.jmapi-v1.4.1.apk`
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
4. Search a JM ID, for example `350234`.

The extension asks the PHP API for metadata and chapter pages. Page images are loaded from URLs like:

```text
http://0.0.0.0:8088/?jmid=350234&chapter=350234&page=1
```

## Local static check

This machine does not need Android SDK for the static contract check:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\extension-contract.ps1
```
