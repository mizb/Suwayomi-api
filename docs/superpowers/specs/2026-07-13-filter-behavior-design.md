# JM API Filter Fix Delivery Specification

> **Authority:** This file is the single functional baseline for the filter fix across `D:/jm/jmapi-extension` and `D:/jm/jmcomic-api-main`. Current source code is the starting point, not the desired behavior. Reference projects provide evidence, not extra scope.

> **Critical invariant:** An empty search query with a selected sort returns a catalog list. It must never throw the old “Enter a JM ID...” error, ignore the selected sort, or parse the response as an album.

## 1. Goal

Make the Suwayomi source filter work without a search keyword while preserving title search, JM ID/URL lookup, existing browse tabs, pagination, and API compatibility.

## 2. Scope

### In scope

- Kotlin request routing and response dispatch in `JmApi.kt`.
- One consistent three-choice sort selector with separate catalog/search mappings.
- PHP `list=popular` order input, normalization, forwarding, and documentation.
- Regression contracts, build/syntax checks, and required version synchronization.

### Non-goals

- Do not rewrite either project in Go or another language.
- Do not change Popular (`list=promote`) or Latest (`list=weekly`) browse-tab semantics.
- Do not add categories, time ranges, ranking periods, or an `mp` catalog option.
- Do not change pagination algorithms, item mapping, authentication, reader, image, cache, Docker topology, or endpoint discovery.
- Do not upgrade dependencies, reformat unrelated files, publish artifacts, or modify sibling projects.

## 3. Current defects and logic audit

1. `getFilterList()` exposes a filter that appears general, but `searchMangaRequest()` rejects an empty query before using it, so no API request is sent.
2. One raw order string cannot model both upstream operations: title search uses `mr` for Latest, while the established catalog path uses `new`.
3. `searchMangaParse()` treats only a URL containing `search` as a list. A new `list=popular` response would otherwise be decoded incorrectly as `JmAlbumEnvelope`.
4. JM ID/URL lookup correctly resolves one album and must stay outside sorting.
5. PHP `fetchPopularList()` hard-codes `o=new`, so an extension-only change would still ignore the filter.
6. Reusing `normalizeSearchOrder()` for catalog input would create the wrong default and admit values outside the approved catalog contract.
7. `order` and compatibility alias `o` lack an explicit precedence contract.
8. Existing static tests encode the broken behavior by forbidding `list=popular`, expecting `mp`, and matching the old `fetchPopularList(int $page)` signature.
9. Kotlin behavior changes require an APK version bump. PHP behavior changes require synchronized API/Docker version metadata.
10. PowerShell contracts inspect source structure; they do not prove Kotlin compilation or PHP syntax validity.
11. `JmListItemDto.toSManga()` currently sets `initialized=true`, which may cause a host to treat list metadata as complete and skip detail refresh. This is a valid associated lifecycle concern, but it predates the filter defect and is explicitly deferred to a separate change so the filter delivery remains isolated.

## 4. Confirmed user behavior

Expose exactly three choices:

- Latest
- Most views
- Highest likes

The mapping is deliberately context-specific:

| User choice | Empty query catalog order | Title-search order |
| --- | --- | --- |
| Latest | `new` | `mr` |
| Most views | `mv` | `mv` |
| Highest likes | `tf` | `tf` |

The empty-query catalog request always uses category `latest`. `Most images` is excluded as an approved conservative scope choice: the Python reference can forward `mp`, but the current PHP service and desktop client do not expose or behavior-test that combination. The ambiguous `Default` label is replaced by explicit `Latest`.

## 5. Extension state machine

File: `D:/jm/jmapi-extension/src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt`

Execute request branches in this exact order:

1. Trim the query and resolve the selected logical sort option.
2. Empty query: send `list=popular`, `page`, `order=<catalogOrder>`, and `format=min`.
3. Non-empty query recognized by `parseJmId()`: send `jmid`, `page`, and `format=min`; do not send an order.
4. Other non-empty query: send `search`, `page`, `order=<searchOrder>`, and `format=min`.

Dispatch parsing from the request URL:

- `search` present: `parseList()`.
- `list` present: `parseList()`.
- `jmid` present: parse `JmAlbumEnvelope`, return one item, `hasNextPage=false`.
- none present: throw an explicit `IOException` instead of guessing the response schema.

The extension must never attach an empty `search` parameter to an empty-query catalog request. PHP intentionally gives a present `search` parameter precedence over `list`, and `search=` is rejected as a missing keyword.

Use one option object carrying both order values:

```kotlin
private data class SortOption(
    val label: String,
    val catalogOrder: String,
    val searchOrder: String,
)
```

`SortFilter` must select a `SortOption`, not coordinate parallel label/code arrays. Out-of-range state falls back to the first option, Latest.

Leave `popularMangaRequest()` and `latestUpdatesRequest()` unchanged because Suwayomi does not pass search filters to those callbacks.

## 6. API state machine

File: `D:/jm/jmcomic-api-main/index.php`

- Change `fetchPopularList(int $page)` to `fetchPopularList(int $page, string $order = 'new')`.
- Re-normalize `$order` at the start of `fetchPopularList()` as defense in depth, then forward it as upstream `/categories/filter` parameter `o`, retaining `c=latest` and existing page-window logic.
- Add `normalizeCatalogOrder(mixed $value): string`.
- Valid catalog values are exactly `new`, `mv`, and `tf`.
- Scalar valid values are trimmed and lower-cased.
- Missing, empty, unsupported, array, object, and other non-scalar values always fall back to `new`.
- For normalized popular aliases, read `order` first and `o` second. If both exist, `order` wins.
- Do not pass this catalog order into `latest`, `promote`, or `weekly` calls.
- Keep `normalizeSearchOrder()` separate for title-search semantics.

Do not narrow the existing public search-order API whitelist. `normalizeSearchOrder()` continues accepting its current `mr`, `mv`, `mp`, `tf`, and `new` values with default `mr`; the three-choice restriction applies to the extension UI and the new catalog normalizer only.

The router normalizes the selected raw query value before the typed service call, and `fetchPopularList()` normalizes its string argument again so future internal callers cannot forward an unsupported string. Arbitrary client or internal input must never reach the upstream API.

## 7. Compatibility and edge cases

- `list=popular` without order remains `new`, preserving existing callers.
- Existing `search=<title>&order=...` remains a title search.
- Existing `jmid=...`, `list=promote`, and `list=weekly` behavior remains unchanged.
- `order` has precedence over `o` when both are supplied.
- Precedence means “present and non-null”, not “first non-empty”: `order=&o=mv` and `order[]=x&o=mv` both resolve to catalog default `new` rather than falling through to `o`.
- Mixed-case valid catalog values normalize to lowercase.
- Pagination continues using the existing 20-item local and 80-item source window.
- No new retry, caching, or empty-result masking is introduced.
- If catalog caching is added in a future task, its key must include endpoint, category, normalized order, and source page. Do not implement that cache here.
- Malformed upstream envelopes continue through existing parse errors; the fix must not hide them.
- Page 2 must retain the same selected order as page 1 because Suwayomi supplies the filter state on each search-page request.
- Changing a filter selection must restart at client page 1. Validate that `new`, `mv`, and `tf` each continue through the unchanged 20-local/80-source page window without mixing pages from another order.

## 8. Version and documentation contract

### Extension target: v1.4.9

- Bump `src/zh/jmapi/build.gradle.kts` `versionCode` from `8` to `9`.
- Keep `libVersion = "1.4"`.
- Update current-target references in:
  - `tests/extension-contract.ps1`
  - `README.md`
  - `docs/apk-optimization-design.md`
  - `docs/ai-delivery-prompt.md`
- Artifact example becomes `tachiyomi-zh.jmapi-v1.4.9.apk`.
- Historical statements may remain historical; current release claims must not remain v1.4.8.

### API target: 2026.07.13.1

- Bump `JmConfig::APP_VERSION` from `2026.07.07.7` to `2026.07.13.1`.
- Synchronize current-version values in Dockerfile, entrypoint, compose, GHCR workflow, tests, README, and documents that explicitly claim the current target.
- Do not change release topology or publish anything.
- Do not upgrade the PHP base image or supported PHP language version; application version synchronization is not a runtime-upgrade task.

## 9. Required documentation behavior

Extension README must state that Search filters work with or without a keyword and that JM ID lookup ignores sorting.

API README must document:

```text
GET /?list=popular&page=1&order=new|mv|tf&format=min
```

- `o` is a compatibility alias.
- `order` wins when both are present.
- Missing or invalid catalog order falls back to `new`.
- Search order and catalog order are separate contracts.
- Existing title-search order remains `mr`, `mv`, `mp`, `tf`, or `new`; this task does not narrow it.

## 10. TDD and regression design

### Extension RED phase

Update `D:/jm/jmapi-extension/tests/extension-contract.ps1` before production code.

The new contract must fail on current code because it requires:

- `list=popular` to exist in the empty-query branch.
- the old empty-query exception text to be absent.
- a three-option model containing Latest, Most views, and Highest likes only.
- Latest to carry `catalogOrder=new` and `searchOrder=mr`.
- `searchMangaParse()` to parse URLs containing either `search` or `list` as lists.
- the extension version to be 9/v1.4.9.

Remove or replace stale assertions that forbid `list=popular`, require `mp`, or require current v1.4.8.

### API RED phase

Update `D:/jm/jmcomic-api-main/tests/list-endpoint-contract.ps1` before `index.php`.

The new contract must fail on current code because it requires:

- `fetchPopularList(int $page, string $order = 'new')`.
- upstream `'o' => $order`, not a hard-coded literal.
- `normalizeCatalogOrder()` and its exact whitelist.
- router precedence `order` then `o`.
- normalized order passed only to popular list handling.
- API version `2026.07.13.1` through the existing runtime-version contracts.

Add focused assertions for `new`, `mv`, `tf`, uppercase input, missing/empty/invalid/non-scalar input, and alias precedence. Prefer function-body isolation over repository-wide string presence.

When isolating `fetchPopularList`, terminate the regular expression at the next method, `fetchPromoteList`, rather than spanning later methods. Also preserve page validation behavior (`page=0` normalizes to 1 and values beyond five digits are rejected) without changing the page-window implementation.

Preserve and assert the existing router conflict rule: if both `search` and `list` are present, `search` wins. The extension prevents this conflict by omitting `search` entirely for empty-query catalog requests.

### Test limitation

PowerShell contracts are structural regression tests. They must be supplemented by Kotlin compilation and PHP lint whenever those runtimes are available. Code inspection is not a substitute.

If the execution environment can run PHP scripts without starting production routing, add a small table-driven helper test for `normalizeCatalogOrder()` covering `null`, empty string, whitespace, uppercase valid values, arrays, and invalid strings. If the monolithic `index.php` structure prevents safe function-only loading, do not refactor the application solely for this test; document the structural-test limitation and rely on lint plus an available HTTP smoke test.

## 11. Behavioral acceptance matrix

| Query | Sort | Extension request | Upstream operation | Parser |
| --- | --- | --- | --- | --- |
| empty | Latest | `list=popular&order=new` | `categories/filter?c=latest&o=new` | list |
| empty | Most views | `list=popular&order=mv` | `categories/filter?c=latest&o=mv` | list |
| empty | Highest likes | `list=popular&order=tf` | `categories/filter?c=latest&o=tf` | list |
| title | Latest | `search=<title>&order=mr` | `/search?...&o=mr` | list |
| title | Most views | `search=<title>&order=mv` | `/search?...&o=mv` | list |
| title | Highest likes | `search=<title>&order=tf` | `/search?...&o=tf` | list |
| JM ID/URL | any | `jmid=<id>` | album detail | album |

## 12. Verification matrix

Mandatory local contracts:

```powershell
Set-Location D:\jm\jmapi-extension
.\tests\extension-contract.ps1

Set-Location D:\jm\jmcomic-api-main
.\tests\list-endpoint-contract.ps1
.\tests\adoption-hardening-contract.ps1
.\tests\page-endpoint-contract.ps1
.\tests\docker-runtime-contract.ps1
```

When PHP is available:

```powershell
php -l D:\jm\jmcomic-api-main\index.php
$php = (Get-Command php -ErrorAction Stop).Source
D:\jm\jmcomic-api-main\tests\catalog-order-runtime.ps1 -PhpPath $php
```

For Kotlin, use the workflow-compatible Keiyoushi checkout/build environment and run `:src:zh:jmapi:assembleRelease`. If unavailable locally, report the limitation and do not claim compilation passed.

Where a runnable API endpoint is available, smoke-check `list=popular` for `new`, `mv`, and `tf`, confirm HTTP success, list-shaped JSON, and that page/order are preserved across requests. Do not require different result ordering because upstream data can coincide. Verify invalid fallback through a stub, captured upstream request, or deterministic helper test when possible. Do not make live upstream access a prerequisite when credentials/network are unavailable.

## 13. Autonomous execution protocol

An implementation AI must continue through this state machine:

1. Read this file completely; inspect both repositories; preserve unrelated user changes.
2. Record baseline tests/build availability and current version strings.
3. Add the smallest failing extension and API contracts.
4. Run them and prove they fail for the missing target behavior, not syntax, path, environment, or pre-existing failures.
5. Implement the minimal Kotlin and PHP changes that turn those same tests green.
6. Run all repository contracts plus available compilation/lint/runtime checks.
7. Update versions and documentation.
8. Re-run the full verification matrix after all version/doc edits.
9. Audit the final diff or changed-file list for scope drift, stale versions, debug code, and accidental formatting.
10. Deliver a report listing changed files, RED/GREEN evidence, every verification command and exit status, and unavailable checks with exact reasons.

### Anti-drift rules

- Re-read this file after context compaction, resumption, or uncertainty; never continue from memory.
- At each phase boundary, re-check Goal, Scope, Non-goals, acceptance matrix, and completion definition.
- Do not treat reference-project features as requirements.
- Do not bundle cleanup, refactors, dependency upgrades, Go rewrites, or extra filters.
- Do not fix the deferred `JmListItemDto.initialized` lifecycle concern in this change.
- Do not overwrite, revert, or reformat unrelated user changes.
- Do not claim success from code inspection, agent summaries, or partial tests.

### Blocking policy

Warnings, first failures, missing optional tools, and repairable environment problems are not blockers. Diagnose, retry, and use repository-supported alternatives. Stop only for missing authority/credentials, unavailable required external state, or an ambiguity that materially changes behavior. A blocked report must state completed work, evidence, attempted alternatives, and the smallest user action needed.

## 14. Completion definition

Completion requires every item below:

- Three logical choices and dual mappings match this file.
- Empty query, title search, and JM ID/URL request branches match the state machine.
- List/album parsing dispatch is explicit and correct.
- PHP whitelist, default, alias precedence, and forwarding match the API contract.
- Extension is v1.4.9/versionCode 9 and API is 2026.07.13.1 everywhere required.
- New tests were observed failing before implementation and passing afterward.
- All existing PowerShell contracts pass.
- Kotlin build and PHP lint were run where supported; unavailable checks are reported, never marked passed.
- Documentation matches delivered behavior and has no stale current-target versions.
- Final change audit contains no unrelated modifications.

“Code written but not fully verified” is incomplete.

## 15. Short AI entry prompt

```text
Use this file as the single task baseline. Read it completely, then autonomously implement the filter fix across D:\jm\jmapi-extension and D:\jm\jmcomic-api-main using its TDD state machine, scope limits, version rules, verification matrix, and completion definition. Continue through implementation, docs/version synchronization, full verification, and final change audit; do not stop at analysis, do not expand scope, and do not claim completion without command evidence.
```

> **Final reminder:** Empty query plus a selected sort must produce a correctly sorted catalog list, while title search and JM ID lookup retain distinct request and parsing semantics.
