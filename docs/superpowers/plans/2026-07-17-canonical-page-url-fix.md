# Canonical Page URL Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every chapter page use the configured JM API endpoint so reverse-proxy prefixes and the live prefetch preference cannot be bypassed by an absolute URL in API JSON.

**Architecture:** Keep the public DTO and API response unchanged. Change only `pageListParse()` so `Page.imageUrl` is deterministically rebuilt by the existing `pageImageUrl()` helper; keep final `prefetch=0` synchronization in `imageRequest()`.

**Tech Stack:** Kotlin, OkHttp `HttpUrl`, PowerShell 5.1 contracts, Keiyoushi Gradle build, Suwayomi-Server 2.3.2243 GraphQL/runtime verification.

---

### Task 1: Lock and fix canonical page URL behavior

**Files:**
- Modify: `D:\jm\jmapi-extension\tests\extension-contract.ps1`
- Modify: `D:\jm\jmapi-extension\src\zh\jmapi\src\eu\kanade\tachiyomi\extension\zh\jmapi\JmApi.kt`

- [ ] **Step 1: Write the failing contract**

After the existing requested-chapter checks, require the extracted `pageListParse` body to contain:

```powershell
if ($pageParseBody -notmatch 'imageUrl\s*=\s*pageImageUrl\(data\.album\.albumId,\s*chapter\.photoId,\s*pageNumber\)') {
    throw 'pageListParse must rebuild every image URL from the configured API endpoint'
}
if ($pageParseBody -match 'chapter\.images\.getOrNull\([^)]*\)\?\.url') {
    throw 'pageListParse must not trust an absolute image URL from the API payload'
}
```

- [ ] **Step 2: Run the contract and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\jm\jmapi-extension\tests\extension-contract.ps1
```

Expected: exit nonzero with `pageListParse must rebuild every image URL from the configured API endpoint`.

- [ ] **Step 3: Implement the minimal production change**

Replace the payload URL selection inside the page loop with:

```kotlin
return (1..pageCount).map { pageNumber ->
    Page(
        index = pageNumber - 1,
        imageUrl = pageImageUrl(data.album.albumId, chapter.photoId, pageNumber),
    )
}
```

- [ ] **Step 4: Run the contract and verify GREEN**

Run the same PowerShell command. Expected: extension contract exits 0.

- [ ] **Step 5: Record repository limitation**

Do not run a commit command: `D:\jm\jmapi-extension` has no `.git`; report the changed files without inventing a commit.

### Task 2: Publish a new behavior version

**Files:**
- Modify: `D:\jm\jmapi-extension\tests\extension-contract.ps1`
- Modify: `D:\jm\jmapi-extension\src\zh\jmapi\build.gradle.kts`
- Modify: `D:\jm\jmapi-extension\README.md`
- Modify: `D:\jm\jmapi-extension\docs\apk-optimization-design.md`
- Modify: `D:\jm\jmapi-extension\docs\ai-delivery-prompt.md`
- Modify: `D:\jm\jmcomic-api-main\docs\performance-delivery-report.md`
- Modify: `D:\jm\jmcomic-api-main\docs\bug-hunt-2026-07-17.md`

- [ ] **Step 1: Move the version contract to 15 and verify RED**

Change contract expectations from `versionCode 14` / `v1.4.14` to `versionCode 15` / `v1.4.15`, then run the extension contract. Expected: failure at `build.gradle.kts` because production still declares 14.

- [ ] **Step 2: Update production version and documentation**

Set:

```kotlin
versionCode = 15
```

Update current-delivery references to `1.4.15 / 15`; retain explicitly historical `1.4.13` and `1.4.14` evidence labels. Document why payload image URLs are ignored and why `127.0.0.1` is only valid when Suwayomi can reach the API in the same network namespace.

- [ ] **Step 3: Verify GREEN**

Run the extension contract. Expected: exit 0 with no stale-current-version failure.

### Task 3: Build, publish metadata, and verify in Suwayomi

**Files:**
- Generate: `D:\jm\jmapi-extension\dist-local\apk\tachiyomi-zh.jmapi-v1.4.15.apk`
- Generate: `D:\jm\jmapi-extension\dist-local\index.min.json`
- Generate: `D:\jm\jmapi-extension\dist-local\index.json`
- Generate: `D:\jm\jmapi-extension\dist-local\repo.json`

- [ ] **Step 1: Build the extension**

Run:

```powershell
Set-Location D:\jm\jmapi-extension
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-with-keiyoushi.ps1
```

Expected: Spotless and `assembleRelease` both report `BUILD SUCCESSFUL`.

- [ ] **Step 2: Regenerate repository metadata**

Run the metadata generator against the actual v1.4.15 release APK, then parse all three JSON files. Expected: package, versionCode 15, versionName 1.4.15, APK filename, APK hash, and signing fingerprint agree.

- [ ] **Step 3: Upgrade the isolated Suwayomi instance**

Install the newly generated APK through `installExternalExtension`; expected GraphQL state is `versionName=1.4.15`, `versionCodeLong=15`, `isInstalled=true`, `hasUpdate=false`.

- [ ] **Step 4: Verify the original runtime failure is fixed**

Keep Base URL `http://127.0.0.1:18088/api`, set `disable_api_prefetch=true`, fetch a fresh chapter and one uncached page, and inspect API health. Expected: image HTTP 200/WebP and `prefetch.skip_counts.disabled` increases by one. Set the preference back to false, clear page cache, fetch again, and verify `disabled` does not increase.

- [ ] **Step 5: Run proportional final verification**

Re-run the extension contract, manifest/signature/metadata checks, Kotlin build result check, and affected documentation/version searches. Do not repeat the full API performance A/B or unrelated fault matrix because no API behavior changed.
