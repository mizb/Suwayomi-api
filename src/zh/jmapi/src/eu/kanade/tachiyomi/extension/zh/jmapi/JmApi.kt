package eu.kanade.tachiyomi.extension.zh.jmapi

import android.content.SharedPreferences
import android.widget.Toast
import androidx.preference.EditTextPreference
import androidx.preference.PreferenceScreen
import androidx.preference.SwitchPreferenceCompat
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import keiyoushi.annotation.Source
import keiyoushi.utils.getPreferences
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.net.URI
import java.net.URISyntaxException

private data class ApiEndpoint(
    val rawPreference: String,
    val baseUrl: HttpUrl,
    val basePath: String,
)

@Source
abstract class JmApi :
    HttpSource(),
    ConfigurableSource {

    override val supportsLatest = true

    private val preferences: SharedPreferences = getPreferences()
    private val apiEndpointLock = Any()

    @Volatile
    private var cachedApiEndpoint: ApiEndpoint? = null

    override fun headersBuilder(): Headers.Builder = Headers.Builder()
        .add("User-Agent", System.getProperty("http.agent") ?: DEFAULT_USER_AGENT)
        .add("Accept", "application/json,image/avif,image/webp,image/apng,image/*,*/*;q=0.8")

    override fun setupPreferenceScreen(screen: PreferenceScreen) {
        EditTextPreference(screen.context).apply {
            key = API_BASE_URL_PREF
            title = "JM API 地址"
            summary = "默认：$DEFAULT_API_BASE_URL。支持根路径或反向代理子路径。"
            dialogTitle = "JM API 地址"
            setDefaultValue(DEFAULT_API_BASE_URL)
            setOnPreferenceChangeListener { _, newValue ->
                try {
                    normalizeApiBaseUrl(newValue as? String ?: "")
                    true
                } catch (e: IOException) {
                    Toast.makeText(screen.context, e.message ?: "无效的 JM API 地址", Toast.LENGTH_LONG).show()
                    false
                }
            }
        }.also(screen::addPreference)

        SwitchPreferenceCompat(screen.context).apply {
            key = DISABLE_API_PREFETCH_PREF
            title = "禁用 API 预取"
            summary = "默认关闭，API 预取保持启用。弱性能主机或 Suwayomi 预加载过多时可开启。"
            setDefaultValue(DEFAULT_DISABLE_API_PREFETCH)
        }.also(screen::addPreference)
    }

    override fun getFilterList(): FilterList = FilterList(SortFilter())

    override fun popularMangaRequest(page: Int): Request {
        val url = apiEndpoint().baseUrl.newBuilder()
            .addQueryParameter("list", "promote")
            .addQueryParameter("page", page.toString())
            .addQueryParameter("format", "min")
            .build()
        return GET(url, headers)
    }

    override fun popularMangaParse(response: Response): MangasPage = response.parseList()

    override fun latestUpdatesRequest(page: Int): Request {
        val url = apiEndpoint().baseUrl.newBuilder()
            .addQueryParameter("list", "weekly")
            .addQueryParameter("page", page.toString())
            .addQueryParameter("format", "min")
            .build()
        return GET(url, headers)
    }

    override fun latestUpdatesParse(response: Response): MangasPage = response.parseList()

    override fun searchMangaRequest(page: Int, query: String, filters: FilterList): Request {
        val trimmedQuery = query.trim()
        val selectedSort = filters.filterIsInstance<SortFilter>()
            .firstOrNull()
            ?.selectedOption()
            ?: SORT_OPTIONS.first()

        val builder = apiEndpoint().baseUrl.newBuilder()
            .addQueryParameter("format", "min")

        val jmId = parseJmId(trimmedQuery)
        val url = when {
            trimmedQuery.isEmpty() ->
                builder
                    .addQueryParameter("page", page.toString())
                    .addQueryParameter("list", "popular")
                    .addQueryParameter("order", selectedSort.catalogOrder)
                    .build()
            jmId != null ->
                builder
                    .addQueryParameter("jmid", jmId)
                    .build()
            else ->
                builder
                    .addQueryParameter("page", page.toString())
                    .addQueryParameter("search", trimmedQuery)
                    .addQueryParameter("order", selectedSort.searchOrder)
                    .build()
        }
        return GET(url, headers)
    }

    override fun searchMangaParse(response: Response): MangasPage = when {
        response.request.url.queryParameter("search") != null -> response.parseList()
        response.request.url.queryParameter("list") != null -> response.parseList()
        response.request.url.queryParameter("jmid") != null -> {
            val data = response.parseData<JmAlbumEnvelope>()
            MangasPage(listOf(data.toSManga()), false)
        }
        else -> throw IOException("Unsupported JM API search response")
    }

    override fun mangaDetailsRequest(manga: SManga): Request {
        val url = apiEndpoint().baseUrl.newBuilder()
            .addQueryParameter("jmid", manga.jmId)
            .build()
        return GET(url, headers)
    }

    override fun mangaDetailsParse(response: Response): SManga = response.parseData<JmAlbumEnvelope>().toSManga()

    override fun chapterListRequest(manga: SManga): Request {
        val url = apiEndpoint().baseUrl.newBuilder()
            .addQueryParameter("jmid", manga.jmId)
            .build()
        return GET(url, headers)
    }

    override fun chapterListParse(response: Response): List<SChapter> {
        val data = response.parseData<JmAlbumEnvelope>()
        val readingOrder = chapterReadingOrder(data.chapters)
        return readingOrder
            .asReversed()
            .mapIndexed { index, chapter ->
                chapter.toSChapter(
                    data.album.albumId,
                    data.album.name,
                    (readingOrder.size - index).toFloat(),
                )
            }
    }

    override fun pageListRequest(chapter: SChapter): Request {
        val (albumId, chapterId) = chapter.jmIds
        val url = apiEndpoint().baseUrl.newBuilder()
            .addQueryParameter("jmid", albumId)
            .addQueryParameter("chapter", chapterId)
            .addQueryParameter("format", "min")
            .build()
        return GET(url, headers)
    }

    override fun pageListParse(response: Response): List<Page> {
        val data = response.parseData<JmChapterEnvelope>()
        val requestedChapter = response.request.url.queryParameter("chapter")
            ?.takeIf(ID_VALUE_REGEX::matches)
            ?: throw IOException("JM 章节请求缺少有效 chapter 参数：${response.request.url}")
        val chapter = data.chapters.firstOrNull { it.photoId == requestedChapter }
            ?: throw IOException("JM API 响应中找不到请求章节 $requestedChapter：${response.request.url}")
        val pageCount = chapter.pageCount.takeIf { it > 0 } ?: chapter.images.size
        if (pageCount <= 0) throw IOException("No pages found for JM chapter ${chapter.photoId}")

        return (1..pageCount).map { pageNumber ->
            val imageUrl = chapter.images.getOrNull(pageNumber - 1)?.url
            Page(
                index = pageNumber - 1,
                imageUrl = imageUrl?.takeIf { it.isNotBlank() }
                    ?: pageImageUrl(data.album.albumId, chapter.photoId, pageNumber),
            )
        }
    }

    override fun imageUrlParse(response: Response): String = throw UnsupportedOperationException()

    override fun imageRequest(page: Page): Request {
        val imageUrl = page.imageUrl?.let(::applyApiPrefetchPreference)
            ?: throw IOException("Missing image URL for JM page ${page.index + 1}")
        return GET(imageUrl, headers)
    }

    override fun getMangaUrl(manga: SManga): String = apiEndpoint().baseUrl.newBuilder()
        .addQueryParameter("jmid", manga.jmId)
        .build()
        .toString()

    override fun getChapterUrl(chapter: SChapter): String {
        val (albumId, chapterId) = chapter.jmIds
        return apiEndpoint().baseUrl.newBuilder()
            .addQueryParameter("jmid", albumId)
            .addQueryParameter("chapter", chapterId)
            .build()
            .toString()
    }

    private fun pageImageUrl(albumId: String, chapterId: String, pageNumber: Int): String = apiEndpoint().baseUrl.newBuilder()
        .addQueryParameter("jmid", albumId)
        .addQueryParameter("chapter", chapterId)
        .addQueryParameter("page", pageNumber.toString())
        .build()
        .toString()

    private fun Response.parseList(): MangasPage {
        val data = parseData<JmListEnvelope>()
        return MangasPage(
            data.items.map { it.toSManga() },
            data.hasNextPage,
        )
    }

    private inline fun <reified T> Response.parseData(): T {
        val payloadText = body.string()
        val payload = try {
            json.decodeFromString<JmApiResponse<T>>(payloadText)
        } catch (e: SerializationException) {
            throw IOException("Invalid JM API response from ${request.url}", e)
        }

        if (!payload.success || payload.code != 200 || payload.data == null) {
            throw IOException(payload.error ?: "JM API ${request.url} returned code ${payload.code}")
        }

        return payload.data
    }

    private fun parseJmId(raw: String): String? {
        val query = raw.trim()
        if (query.isEmpty()) return null

        JM_PREFIX_REGEX.matchEntire(query)?.let { return it.groupValues[1] }
        PURE_ID_REGEX.matchEntire(query)?.let { return it.groupValues[1] }
        QUERY_ID_REGEX.find(query)?.let { return it.groupValues[1] }
        PATH_ID_REGEX.find(query)?.let { return it.groupValues[1] }

        return null
    }

    private fun apiEndpoint(): ApiEndpoint {
        val raw = preferences.getString(API_BASE_URL_PREF, DEFAULT_API_BASE_URL) ?: DEFAULT_API_BASE_URL
        cachedApiEndpoint?.takeIf { it.rawPreference == raw }?.let { return it }

        return synchronized(apiEndpointLock) {
            cachedApiEndpoint?.takeIf { it.rawPreference == raw }
                ?: normalizeApiBaseUrl(raw).also { cachedApiEndpoint = it }
        }
    }

    private fun normalizeApiBaseUrl(raw: String): ApiEndpoint {
        val candidate = raw.trim().ifBlank { DEFAULT_API_BASE_URL }
        val rawUri = try {
            URI(candidate)
        } catch (e: URISyntaxException) {
            throw IOException("无效的 JM API 地址，请使用 http://host:8088 或 https://host。", e)
        }
        if (rawUri.rawUserInfo != null) {
            throw IOException("JM API 地址不能包含用户名或密码。")
        }
        val parsed = candidate.toHttpUrlOrNull()
            ?: throw IOException("无效的 JM API 地址，请使用 http://host:8088 或 https://host。")

        if (parsed.scheme != "http" && parsed.scheme != "https") {
            throw IOException("JM API 地址必须使用 http 或 https。")
        }
        if (parsed.username.isNotEmpty() || parsed.password.isNotEmpty()) {
            throw IOException("JM API 地址不能包含用户名或密码。")
        }
        if (parsed.query != null) {
            throw IOException("JM API 地址不能包含查询参数。")
        }
        if (parsed.fragment != null) {
            throw IOException("JM API 地址不能包含片段。")
        }
        val hostForSafetyCheck = parsed.host.trimEnd('.')
        if (hostForSafetyCheck in UNSPECIFIED_HOSTS || UNSPECIFIED_IPV4_REGEX.matches(hostForSafetyCheck)) {
            throw IOException("0.0.0.0 和 :: 仅用于监听，请填写可访问的客户端地址。")
        }

        return ApiEndpoint(
            rawPreference = raw,
            baseUrl = parsed,
            basePath = parsed.encodedPath.trimEnd('/').ifEmpty { "/" },
        )
    }

    private fun isApiPrefetchDisabled(): Boolean = preferences.getBoolean(DISABLE_API_PREFETCH_PREF, DEFAULT_DISABLE_API_PREFETCH)

    private fun applyApiPrefetchPreference(imageUrl: String): String {
        val parsed = imageUrl.toHttpUrlOrNull() ?: return imageUrl
        if (!isSameApiEndpoint(parsed)) return imageUrl
        if (!isDecodedPageUrl(parsed)) return imageUrl

        return parsed.newBuilder().apply {
            if (isApiPrefetchDisabled()) {
                setQueryParameter("prefetch", "0")
            } else {
                removeAllQueryParameters("prefetch")
            }
        }.build().toString()
    }

    private fun isSameApiEndpoint(url: HttpUrl): Boolean {
        val endpoint = apiEndpoint()
        return url.scheme == endpoint.baseUrl.scheme &&
            url.host == endpoint.baseUrl.host &&
            url.port == endpoint.baseUrl.port &&
            normalizedPathSegments(url) == normalizedPathSegments(endpoint.baseUrl)
    }

    private fun normalizedPathSegments(url: HttpUrl): List<String> = url.pathSegments.dropLastWhile(String::isEmpty)

    private fun isDecodedPageUrl(url: HttpUrl): Boolean {
        val albumId = url.queryParameter("jmid")
        val chapterId = url.queryParameter("chapter")
        val page = url.queryParameter("page")?.toIntOrNull()
        return albumId?.matches(ID_VALUE_REGEX) == true &&
            chapterId?.matches(ID_VALUE_REGEX) == true &&
            page != null && page > 0
    }

    companion object {
        private const val API_BASE_URL_PREF = "api_base_url"
        private const val DISABLE_API_PREFETCH_PREF = "disable_api_prefetch"
        private const val DEFAULT_API_BASE_URL = "http://127.0.0.1:8088"
        private const val DEFAULT_DISABLE_API_PREFETCH = false
        private const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36"

        private val JM_PREFIX_REGEX = Regex("""(?i)JM(\d{1,20})(?!\d)""")
        private val PURE_ID_REGEX = Regex("""(\d{1,20})""")
        private val QUERY_ID_REGEX = Regex("""[?&](?:jmid|id)=(\d{1,20})(?=[&#]|$)""")
        private val PATH_ID_REGEX = Regex("""/(?:(?:album|photo)s?)/(\d{1,20})(?!\d)(?:/|$)""", RegexOption.IGNORE_CASE)
        private val ID_VALUE_REGEX = Regex("""\d{1,20}""")
        private val UNSPECIFIED_HOSTS = setOf("0.0.0.0", "::")
        private val UNSPECIFIED_IPV4_REGEX = Regex("""0+(?:\.0+){0,3}""")

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}

private data class SortOption(
    val label: String,
    val catalogOrder: String,
    val searchOrder: String,
)

private val SORT_OPTIONS = arrayOf(
    SortOption("最新", "new", "mr"),
    SortOption("最多浏览", "mv", "mv"),
    SortOption("最多点赞", "tf", "tf"),
)

private class SortFilter :
    Filter.Select<String>(
        "排序",
        SORT_OPTIONS.map(SortOption::label).toTypedArray(),
    ) {
    fun selectedOption(): SortOption = SORT_OPTIONS.getOrElse(state) { SORT_OPTIONS.first() }
}

private fun chapterReadingOrder(chapters: List<JmChapterHeaderDto>): List<JmChapterHeaderDto> = chapters.sortedWith(
    compareBy<JmChapterHeaderDto> { it.sort.toFloatOrNull() ?: Float.MAX_VALUE }
        .thenBy { it.photoId.toLongOrNull() ?: Long.MAX_VALUE }
        .thenBy { it.photoId },
)
