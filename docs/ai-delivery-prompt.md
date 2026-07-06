# AI Delivery Prompt: JM API Suwayomi APK Optimization

Use this prompt for a future autonomous coding agent.

```text
You are an autonomous senior coding agent working on the same Windows machine as the user.

Goal:
Fully implement and verify the APK-side JM API / Suwayomi extension optimizations. Do not stop at analysis. Read the code, update tests first, implement, verify, update docs, and provide deployment instructions. Continue until complete unless required external tools are missing.

Project paths:
- Extension project: D:\jm\jmapi-extension
- API project for reference only: D:\jm\jm-boom-master\jmcomic-api-main
- Extension source:
  - D:\jm\jmapi-extension\src\zh\jmapi\src\eu\kanade\tachiyomi\extension\zh\jmapi\JmApi.kt
  - D:\jm\jmapi-extension\src\zh\jmapi\src\eu\kanade\tachiyomi\extension\zh\jmapi\Dto.kt
- Build config:
  - D:\jm\jmapi-extension\src\zh\jmapi\build.gradle.kts
- Contract test:
  - D:\jm\jmapi-extension\tests\extension-contract.ps1
- Design document:
  - D:\jm\jmapi-extension\docs\apk-optimization-design.md

Must read first:
1. D:\jm\jmapi-extension\docs\apk-optimization-design.md
2. D:\jm\jmapi-extension\src\zh\jmapi\src\eu\kanade\tachiyomi\extension\zh\jmapi\JmApi.kt
3. D:\jm\jmapi-extension\src\zh\jmapi\src\eu\kanade\tachiyomi\extension\zh\jmapi\Dto.kt
4. D:\jm\jmapi-extension\src\zh\jmapi\build.gradle.kts
5. D:\jm\jmapi-extension\tests\extension-contract.ps1
6. D:\jm\jmapi-extension\.github\workflows\build-extension.yml
7. D:\jm\jmapi-extension\README.md

Hard constraints:
- Do not decode JM images inside the APK.
- Do not add image file cache.
- Do not add Redis or depend on Redis.
- Do not call JM upstream directly from the APK; the APK talks to the PHP API only.
- Do not change the PHP API JSON contract unless you update API and extension tests together.
- API port remains 8088.
- Never recommend 0.0.0.0 as a client access URL. It is only a server bind address.
- Do not change Docker/API behavior unless strictly required for APK integration.
- If Kotlin extension source changes, bump versionCode from the current value and update extension tests and README artifact example. Current released target is v1.4.5 / versionCode 5.
- If only docs/tests change and Kotlin source does not change, do not bump versionCode.
- Do not reset, revert, or overwrite unrelated user changes.
- Do not claim completion unless tests/builds were run or you clearly state which tools are missing.
- When adding source settings, implement ConfigurableSource and use keiyoushi.utils.getPreferences() following current Keiyoushi extension examples.

Required implementation:
1. Runtime API base URL setting:
   - Add a source preference allowing users to set API base URL.
   - Default remains http://127.0.0.1:8088.
   - Normalize by trimming and removing trailing slashes.
   - Require http or https.
   - Reject or refuse to use 0.0.0.0 as a client host.
   - All requests must use the runtime configured base URL, not only the compile-time metadata baseUrl.
   - Keep generated index metadata baseUrl as the default value unless the build workflow explicitly supports a different configured default.

2. API prefetch control:
   - Add a setting to disable API-side prefetch.
   - Default must preserve current behavior: API prefetch enabled.
   - When disabled, generated decoded image URLs must include prefetch=0.
   - If API-provided image URLs are already decoded API URLs, append prefetch=0 safely without corrupting other URLs.

3. Search sort filters:
   - Implement getFilterList() and read FilterList in searchMangaRequest.
   - For title search, send order=<code>.
   - Supported codes: mr, mv, mp, tf, new.
   - Default code: mr.
   - If query is a JM ID or album URL, keep current jmid lookup behavior and ignore sort.

4. Safe chapter URL parsing:
   - Replace unchecked parts[1] to parts[2] parsing.
   - Require /chapter/<albumId>/<photoId> with numeric IDs of 1 to 20 digits.
   - Throw clear IOException or equivalent when invalid.

5. Error messages:
   - Improve user-facing errors for invalid API response, missing chapter, no pages, invalid internal URL, and missing image URL.
   - Keep messages concise and do not leak large response bodies.

6. Optional metadata cache:
   - Only implement if clean with current HttpSource framework.
   - Max 20 album entries, TTL 60 seconds, memory only.
   - Do not cache image bytes.
   - If it is invasive or uncertain, skip and document why.

Important framework instruction:
- Before implementing source preferences, inspect current Keiyoushi/Tachiyomi extension examples from the checked-out build system or official source used by the workflow. Do not blindly use stale preference API names if the current libVersion expects a different pattern.

Test-driven workflow:
1. Update D:\jm\jmapi-extension\tests\extension-contract.ps1 first.
2. Add checks for:
   - current versionCode after Kotlin source changes.
   - ConfigurableSource is implemented and getPreferences() is used for source settings.
   - runtime base URL preference.
   - prefetch disable preference and prefetch=0 URL behavior.
   - search filter and all order codes: mr, mv, mp, tf, new.
   - safe chapter URL parser.
   - absence of unchecked parts[1] to parts[2].
   - README current APK artifact example.
   - chapterListParse returns chapters newest-first for Suwayomi even though the PHP API returns chronological reading order.
   - no recommendation to use 0.0.0.0 as client URL.
3. Run the test and verify it fails for the expected missing behavior.
4. Implement minimal code to pass.
5. Re-run all tests.

Required static test:
powershell -ExecutionPolicy Bypass -File D:\jm\jmapi-extension\tests\extension-contract.ps1

If Gradle/Android SDK is available:
cd D:\jm\jmapi-extension
Run the same build path used by GitHub Actions or checkout Keiyoushi as needed and run:
./gradlew :src:zh:jmapi:assembleRelease --stacktrace

If Docker/API is available for runtime verification:
- Confirm API health:
  curl "http://127.0.0.1:8088/?health=1"
- Confirm diagnostics.app_version exists.
- In Suwayomi, install the new APK, set base URL, test popular, latest, title search, ID search, details, chapters, and images.
- Toggle "Disable API prefetch" and confirm image requests include prefetch=0.

Documentation updates:
- Update D:\jm\jmapi-extension\README.md with:
  - How to change API base URL in extension settings.
  - Correct Docker service URL example: http://jmcomic-api:8088.
  - Correct LAN example.
  - Warning that 0.0.0.0 is not a client URL.
  - New APK artifact example if versionCode changes.

Delivery output must include:
- Files changed.
- What was implemented.
- Tests run and exact pass/fail status.
- Build/runtime verification status.
- How to rebuild and publish the APK/GitHub Pages repo.
- Whether Docker API must be redeployed.
- Remaining risks.

Do not end with a vague proposal. Implement and verify end to end within available tools.
```
