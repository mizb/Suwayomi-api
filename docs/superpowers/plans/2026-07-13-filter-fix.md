# JM API Filter Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Suwayomi sorting work with an empty query while preserving title search and JM ID lookup across the Kotlin extension and PHP API.

**Architecture:** The extension owns query intent and maps one logical sort option to separate catalog/search order codes. Empty-query requests use the PHP `list=popular` wrapper, which validates a catalog-only order and forwards it to `/categories/filter`. The existing title-search and direct-album paths remain separate.

**Tech Stack:** Kotlin/Tachiyomi `HttpSource`, OkHttp, kotlinx.serialization, PHP 8, PowerShell contract tests, Docker metadata.

**Authoritative spec:** `D:/jm/jmapi-extension/docs/superpowers/specs/2026-07-13-filter-behavior-design.md`

**Repository note:** These directories currently have no `.git` metadata and the local shell has no usable Git command. Do not fabricate commits; record changed files instead. If Git becomes available in the execution environment, make one focused commit per completed task.

---

### Task 1: Establish baselines and create the extension RED test

**Files:**
- Modify: `D:/jm/jmapi-extension/tests/extension-contract.ps1`
- Read: `D:/jm/jmapi-extension/src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt`

- [ ] **Step 1: Run the current extension contract**

Run:

```powershell
Set-Location D:\jm\jmapi-extension
.\tests\extension-contract.ps1
```

Expected baseline: PASS before test changes.

- [ ] **Step 2: Replace stale filter/version assertions**

Remove the assertion forbidding `list=popular`, the requirement for `mp`, and v1.4.8/versionCode 8 current-target assertions. Add focused assertions equivalent to:

```powershell
Assert-Contains "src/zh/jmapi/build.gradle.kts" 'versionCode\s*=\s*9'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("list",\s*"popular"\)'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'Enter a JM ID, album URL, or title'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'data class\s+SortOption'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortOption\("Latest",\s*"new",\s*"mr"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortOption\("Most views",\s*"mv",\s*"mv"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortOption\("Highest likes",\s*"tf",\s*"tf"\)'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'Most images'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'queryParameter\("list"\)'
```

Use the existing relative source path variable/style rather than introducing a second assertion framework.

- [ ] **Step 3: Run the changed contract and confirm RED**

Run the same command.

Expected: FAIL because `list=popular`, `SortOption`, dual mappings, parser dispatch, and versionCode 9 do not exist. A syntax or missing-file error is not an acceptable RED result.

---

### Task 2: Implement extension request and parser behavior

**Files:**
- Modify: `D:/jm/jmapi-extension/src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt`
- Test: `D:/jm/jmapi-extension/tests/extension-contract.ps1`

- [ ] **Step 1: Replace parallel sort arrays with an option model**

Use this behavior-equivalent structure:

```kotlin
private data class SortOption(
    val label: String,
    val catalogOrder: String,
    val searchOrder: String,
)

private val SORT_OPTIONS = arrayOf(
    SortOption("Latest", "new", "mr"),
    SortOption("Most views", "mv", "mv"),
    SortOption("Highest likes", "tf", "tf"),
)

private class SortFilter : Filter.Select<String>(
    "Sort",
    SORT_OPTIONS.map(SortOption::label).toTypedArray(),
) {
    fun selectedOption(): SortOption = SORT_OPTIONS.getOrElse(state) { SORT_OPTIONS.first() }
}
```

Remove `SEARCH_SORT_LABELS`, `SEARCH_SORT_CODES`, and `DEFAULT_SEARCH_ORDER` if no longer used.

- [ ] **Step 2: Implement the exact request branch order**

Refactor `searchMangaRequest` to this behavior:

```kotlin
override fun searchMangaRequest(page: Int, query: String, filters: FilterList): Request {
    val trimmedQuery = query.trim()
    val selectedSort = filters.filterIsInstance<SortFilter>()
        .firstOrNull()
        ?.selectedOption()
        ?: SORT_OPTIONS.first()

    val builder = apiBaseUrl().toHttpUrl().newBuilder()
        .addQueryParameter("format", "min")
        .addQueryParameter("page", page.toString())

    val url = when {
        trimmedQuery.isEmpty() -> builder
            .addQueryParameter("list", "popular")
            .addQueryParameter("order", selectedSort.catalogOrder)
            .build()

        parseJmId(trimmedQuery) != null -> builder
            .addQueryParameter("jmid", requireNotNull(parseJmId(trimmedQuery)))
            .build()

        else -> builder
            .addQueryParameter("search", trimmedQuery)
            .addQueryParameter("order", selectedSort.searchOrder)
            .build()
    }

    return GET(url, headers)
}
```

Refactor the ID branch to evaluate `parseJmId` once before the `when` if required by formatting/lint; do not call it twice in final code.

- [ ] **Step 3: Make response dispatch explicit**

Implement:

```kotlin
override fun searchMangaParse(response: Response): MangasPage = when {
    response.request.url.queryParameter("search") != null -> response.parseList()
    response.request.url.queryParameter("list") != null -> response.parseList()
    response.request.url.queryParameter("jmid") != null -> {
        val data = response.parseData<JmAlbumEnvelope>()
        MangasPage(listOf(data.toSManga(apiBaseUrl())), false)
    }
    else -> throw IOException("Unsupported JM API search response")
}
```

- [ ] **Step 4: Run the extension contract**

Expected: only version/document assertions may remain failing; request/filter/parser assertions pass.

---

### Task 3: Synchronize extension version and documentation

**Files:**
- Modify: `D:/jm/jmapi-extension/src/zh/jmapi/build.gradle.kts`
- Modify: `D:/jm/jmapi-extension/tests/extension-contract.ps1`
- Modify: `D:/jm/jmapi-extension/README.md`
- Modify: `D:/jm/jmapi-extension/docs/apk-optimization-design.md`
- Modify: `D:/jm/jmapi-extension/docs/ai-delivery-prompt.md`

- [ ] **Step 1: Bump the APK version**

Change only:

```kotlin
versionCode = 9
libVersion = "1.4"
```

- [ ] **Step 2: Update current-target documentation**

Replace current release/artifact references with v1.4.9/versionCode 9. Add concise README behavior:

```markdown
Search sorting works with or without a title keyword. An empty keyword browses the full catalog; JM ID/album URL lookup returns the exact album and does not apply sorting.
```

Do not rewrite historical release descriptions that are explicitly historical.

- [ ] **Step 3: Run the extension contract**

Expected: PASS.

---

### Task 4: Create the API RED test

**Files:**
- Modify: `D:/jm/jmcomic-api-main/tests/list-endpoint-contract.ps1`
- Modify: `D:/jm/jmcomic-api-main/tests/docker-runtime-contract.ps1`

- [ ] **Step 1: Run current API contracts**

```powershell
Set-Location D:\jm\jmcomic-api-main
.\tests\list-endpoint-contract.ps1
.\tests\docker-runtime-contract.ps1
```

Expected baseline: PASS.

- [ ] **Step 2: Replace the old popular-function extraction and hard-coded-order assertions**

Require the new signature and behavior:

```powershell
Assert-Matches 'function\s+normalizeCatalogOrder\(mixed\s+\$value\):\s*string' 'catalog order has a separate normalizer'
Assert-Matches "in_array\(\$order,\s*\['new',\s*'mv',\s*'tf'\],\s*true\)" 'catalog order whitelist is exact'
Assert-Matches "public function fetchPopularList\(int \$page, string \$order = 'new'\)" 'popular list accepts normalized order'
Assert-Matches 'fetchPopularList[\s\S]*?normalizeCatalogOrder\(\$order\)' 'popular service revalidates internal order'
Assert-Matches "'o'\s*=>\s*\$order" 'popular list forwards selected order'
Assert-NotMatches "'o'\s*=>\s*'new'" 'popular list no longer hard-codes new'
Assert-Matches "\$_GET\['order'\].*\$_GET\['o'\]" 'order parameter has alias precedence'
```

Update the expected API version to `2026.07.13.1` in the existing version contract.

Update the `fetchPopularList` body extraction regex so it ends at the immediately following `fetchPromoteList` method. Add assertions for these exact semantics:

```text
null, empty, whitespace, mp, array -> new
" MV " -> mv
"TF" -> tf
order=&o=mv -> new
order[]=x&o=mv -> new
order=TF&o=mv -> tf
search=x&list=popular -> search branch
search=&list=popular -> missing-keyword error
```

- [ ] **Step 3: Run changed tests and confirm RED**

Expected: FAIL because the signature, normalizer, forwarding, router wiring, and new version are absent.

---

### Task 5: Implement catalog order validation and forwarding

**Files:**
- Modify: `D:/jm/jmcomic-api-main/index.php`
- Test: `D:/jm/jmcomic-api-main/tests/list-endpoint-contract.ps1`

- [ ] **Step 1: Add the separate normalizer**

Place near `normalizeSearchOrder`:

```php
function normalizeCatalogOrder(mixed $value): string
{
    $order = strtolower(trim(is_scalar($value) ? (string) $value : 'new'));
    return in_array($order, ['new', 'mv', 'tf'], true) ? $order : 'new';
}
```

- [ ] **Step 2: Parameterize `fetchPopularList`**

Change the signature and one query value only:

```php
public function fetchPopularList(int $page, string $order = 'new'): JmListResult
```

Add defense in depth before building upstream parameters:

```php
$order = normalizeCatalogOrder($order);
```

```php
'o' => $order,
```

Keep `c=latest`, source-page calculation, result mapping, and pagination untouched.

Do not change `normalizeSearchOrder()` or remove its existing `mp`/`new` compatibility values; this task adds a catalog-only normalizer.
Do not assert that different orders must return different content. Assert the forwarded order, list response shape, and stable order across pagination instead.

- [ ] **Step 3: Wire normalization into only the popular branch**

Use `order` before `o`:

```php
default => $service->fetchPopularList(
    $page,
    normalizeCatalogOrder($_GET['order'] ?? $_GET['o'] ?? 'new'),
),
```

Preserve the exact null-coalescing semantics: `order=&o=mv` and `order[]=x&o=mv` normalize to `new`; they do not fall through to `o`.

- [ ] **Step 4: Run list and hardening contracts**

```powershell
.\tests\list-endpoint-contract.ps1
.\tests\adoption-hardening-contract.ps1
```

Expected: behavior contracts pass; version contract may still fail until Task 6.

---

### Task 6: Synchronize API version and documentation

**Files:**
- Modify: `D:/jm/jmcomic-api-main/index.php`
- Modify: `D:/jm/jmcomic-api-main/Dockerfile`
- Modify: `D:/jm/jmcomic-api-main/docker-entrypoint.sh`
- Modify: `D:/jm/jmcomic-api-main/docker-compose.yml`
- Modify: `D:/jm/jmcomic-api-main/.github/workflows/docker-build.yml`
- Modify: `D:/jm/jmcomic-api-main/tests/docker-runtime-contract.ps1`
- Modify: `D:/jm/jmcomic-api-main/README.md`
- Modify only when they make a current-target claim: `D:/jm/jmcomic-api-main/docs/ai-delivery-prompt.md`
- Review but preserve historical version narratives: `D:/jm/jmcomic-api-main/docs/advanced-reader-optimization-design.md`
- Review but preserve historical version narratives: `D:/jm/jmcomic-api-main/docs/advanced-reader-optimization-ai-prompt.md`

- [ ] **Step 1: Change current API version to `2026.07.13.1`**

Use `rg -n "2026\.07\.07\.7"` to enumerate every occurrence. Classify each as current-target or historical before editing. Update all current-target occurrences and preserve explicitly historical baselines.

Do not change the PHP base image or supported PHP language version.

- [ ] **Step 2: Document the popular order contract**

Add the request example and rules from the specification: `new|mv|tf`, `o` alias, `order` precedence, invalid fallback to `new`, and separation from title-search order.

- [ ] **Step 3: Run all API contracts**

```powershell
.\tests\list-endpoint-contract.ps1
.\tests\adoption-hardening-contract.ps1
.\tests\page-endpoint-contract.ps1
.\tests\docker-runtime-contract.ps1
```

Expected: all PASS.

Also confirm that the existing `search`-before-`list` router behavior remains unchanged and that the extension's empty-query URL contains no `search` parameter.

---

### Task 7: Build, lint, smoke-test, and audit delivery

**Files:**
- Verify all modified files from Tasks 1-6

- [ ] **Step 1: Run PHP lint when available**

```powershell
php -l D:\jm\jmcomic-api-main\index.php
$php = (Get-Command php -ErrorAction Stop).Source
D:\jm\jmcomic-api-main\tests\catalog-order-runtime.ps1 -PhpPath $php
```

Expected: `No syntax errors detected`. If PHP is unavailable, record `Get-Command php` evidence and do not claim lint passed.

- [ ] **Step 2: Compile the extension when the workflow-compatible build tree is available**

Run `:src:zh:jmapi:assembleRelease` in the Keiyoushi extension build environment. Expected: BUILD SUCCESSFUL and v1.4.9 artifact. If unavailable, document the exact missing environment/dependency.

- [ ] **Step 3: Run the full PowerShell matrix again**

Run every command from the specification after all source, version, and documentation edits. Expected: all exit code 0.

- [ ] **Step 4: Perform changed-file and stale-string audits**

```powershell
rg -n "v1\.4\.8|versionCode\s*=\s*8" D:\jm\jmapi-extension
rg -n "2026\.07\.07\.7" D:\jm\jmcomic-api-main
rg -n "Most images|Enter a JM ID, album URL, or title" D:\jm\jmapi-extension
```

Review every match and keep only explicitly historical references. Confirm no files outside the two target repositories changed.
Confirm `Dto.kt` was not changed; its existing list-item `initialized` lifecycle concern is documented but deferred.

- [ ] **Step 5: Produce the delivery report**

Report:

- changed files grouped by repository;
- the original root cause and implemented data flow;
- RED commands and expected failure evidence;
- GREEN/full-verification commands and exit codes;
- Kotlin build/PHP lint/runtime smoke status;
- unavailable checks and exact reasons;
- confirmation that no unrelated changes were introduced.

Do not call the task complete unless the specification's completion definition is satisfied.
