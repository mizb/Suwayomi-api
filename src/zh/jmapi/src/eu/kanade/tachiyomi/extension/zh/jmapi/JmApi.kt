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
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import okhttp3.Response
import java.io.IOException

@Source
abstract class JmApi :
    HttpSource(),
    ConfigurableSource {

    override val supportsLatest = true

    private val preferences: SharedPreferences = getPreferences()

    override fun headersBuilder(): Headers.Builder = Headers.Builder()
        .add("User-Agent", System.getProperty("http.agent") ?: DEFAULT_USER_AGENT)
        .add("Accept", "application/json,image/avif,image/webp,image/apng,image/*,*/*;q=0.8")

    override fun setupPreferenceScreen(screen: PreferenceScreen) {
        EditTextPreference(screen.context).apply {
            key = API_BASE_URL_PREF
            title = "API base URL"
            summary = "Default: $DEFAULT_API_BASE_URL"
            dialogTitle = "JM API base URL"
            setDefaultValue(DEFAULT_API_BASE_URL)
            setOnPreferenceChangeListener { _, newValue ->
                try {
                    normalizeApiBaseUrl(newValue as? String ?: "")
                    true
                } catch (e: IOException) {
                    Toast.makeText(screen.context, e.message ?: "Invalid JM API base URL", Toast.LENGTH_LONG).show()
                    false
                }
            }
        }.also(screen::addPreference)

        SwitchPreferenceCompat(screen.context).apply {
            key = DISABLE_API_PREFETCH_PREF
            title = "Disable API prefetch"
            summary = "Default is off, so API prefetch stays enabled. Turn this on only on weak hosts or when Suwayomi preloads too aggressively; image URLs then include prefetch=0."
            setDefaultValue(DEFAULT_DISABLE_API_PREFETCH)
        }.also(screen::addPreference)
    }

    override fun getFilterList(): FilterList = FilterList(SortFilter())

    override fun popularMangaRequest(page: Int): Request {
        val url = apiBaseUrl().toHttpUrl().newBuilder()
            .addQueryParameter("list", "popular")
            .addQueryParameter("page", page.toString())
            .addQueryParameter("format", "min")
            .build()
        return GET(url, headers)
    }

    override fun popularMangaParse(response: Response): MangasPage = response.parseList()

    override fun latestUpdatesRequest(page: Int): Request {
        val url = apiBaseUrl().toHttpUrl().newBuilder()
            .addQueryParameter("list", "latest")
            .addQueryParameter("page", page.toString())
            .addQueryParameter("format", "min")
            .build()
        return GET(url, headers)
    }

    override fun latestUpdatesParse(response: Response): MangasPage = response.parseList()

    override fun searchMangaRequest(page: Int, query: String, filters: FilterList): Request {
        val trimmedQuery = query.trim()
        if (trimmedQuery.isEmpty()) throw IOException("Enter a JM ID, album URL, or title")

        val builder = apiBaseUrl().toHttpUrl().newBuilder()
            .addQueryParameter("format", "min")
            .addQueryParameter("page", page.toString())

        val jmId = parseJmId(trimmedQuery)
        val order = filters.filterIsInstance<SortFilter>().firstOrNull()?.selectedOrder() ?: DEFAULT_SEARCH_ORDER
        val url = if (jmId != null) {
            builder.addQueryParameter("jmid", jmId).build()
        } else {
            builder
                .addQueryParameter("search", trimmedQuery)
                .addQueryParameter("order", order)
                .build()
        }
        return GET(url, headers)
    }

    override fun searchMangaParse(response: Response): MangasPage {
        if (response.request.url.queryParameter("search") != null) {
            return response.parseList()
        }

        val data = response.parseData<JmAlbumEnvelope>()
        return MangasPage(listOf(data.toSManga(apiBaseUrl())), false)
    }

    override fun mangaDetailsRequest(manga: SManga): Request {
        val url = apiBaseUrl().toHttpUrl().newBuilder()
            .addQueryParameter("jmid", manga.jmId)
            .build()
        return GET(url, headers)
    }

    override fun mangaDetailsParse(response: Response): SManga = response.parseData<JmAlbumEnvelope>().toSManga(apiBaseUrl())

    override fun chapterListRequest(manga: SManga): Request {
        val url = apiBaseUrl().toHttpUrl().newBuilder()
            .addQueryParameter("jmid", manga.jmId)
            .build()
        return GET(url, headers)
    }

    override fun chapterListParse(response: Response): List<SChapter> {
        val data = response.parseData<JmAlbumEnvelope>()
        return data.chapters
            .sortedByDescending { it.sort.toFloatOrNull() ?: -1f }
            .map { chapter ->
                chapter.toSChapter(data.album.albumId, data.album.name)
            }
    }

    override fun pageListRequest(chapter: SChapter): Request {
        val (albumId, chapterId) = chapter.jmIds
        val url = apiBaseUrl().toHttpUrl().newBuilder()
            .addQueryParameter("jmid", albumId)
            .addQueryParameter("chapter", chapterId)
            .addQueryParameter("format", "min")
            .build()
        return GET(url, headers)
    }

    override fun pageListParse(response: Response): List<Page> {
        val data = response.parseData<JmChapterEnvelope>()
        val requestedChapter = response.request.url.queryParameter("chapter") ?: "unknown"
        val chapter = data.chapters.firstOrNull()
            ?: throw IOException("Chapter not found from JM API for chapter=$requestedChapter at ${response.request.url}")
        val pageCount = chapter.pageCount.takeIf { it > 0 } ?: chapter.images.size
        if (pageCount <= 0) throw IOException("No pages found for JM chapter ${chapter.photoId}")

        return (1..pageCount).map { pageNumber ->
            val imageUrl = chapter.images.getOrNull(pageNumber - 1)?.url
            Page(
                index = pageNumber - 1,
                imageUrl = imageUrl?.takeIf { it.isNotBlank() }?.let(::maybeDisableApiPrefetch)
                    ?: pageImageUrl(data.album.albumId, chapter.photoId, pageNumber),
            )
        }
    }

    override fun imageUrlParse(response: Response): String = throw UnsupportedOperationException()

    override fun imageRequest(page: Page): Request {
        val imageUrl = page.imageUrl?.let(::maybeDisableApiPrefetch)
            ?: throw IOException("Missing image URL for JM page ${page.index + 1}")
        return GET(imageUrl, headers)
    }

    override fun getMangaUrl(manga: SManga): String = "${apiBaseUrl()}/?jmid=${manga.jmId}"

    override fun getChapterUrl(chapter: SChapter): String {
        val (albumId, chapterId) = chapter.jmIds
        return "${apiBaseUrl()}/?jmid=$albumId&chapter=$chapterId"
    }

    private fun pageImageUrl(albumId: String, chapterId: String, pageNumber: Int): String {
        val builder = apiBaseUrl().toHttpUrl().newBuilder()
            .addQueryParameter("jmid", albumId)
            .addQueryParameter("chapter", chapterId)
            .addQueryParameter("page", pageNumber.toString())

        if (isApiPrefetchDisabled()) {
            builder.addQueryParameter("prefetch", "0")
        }

        return builder.build().toString()
    }

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

    private fun apiBaseUrl(): String {
        val raw = preferences.getString(API_BASE_URL_PREF, DEFAULT_API_BASE_URL) ?: DEFAULT_API_BASE_URL
        return normalizeApiBaseUrl(raw)
    }

    private fun normalizeApiBaseUrl(raw: String): String {
        val candidate = raw.trim().ifBlank { DEFAULT_API_BASE_URL }.trimEnd('/')
        val parsed = candidate.toHttpUrlOrNull()
            ?: throw IOException("Invalid JM API base URL. Use http://host:8088 or https://host.")

        if (parsed.host == "0.0.0.0") {
            throw IOException("0.0.0.0 is only a listen address. Use 127.0.0.1, a LAN IP, or a Docker service name.")
        }

        if (parsed.scheme != "http" && parsed.scheme != "https") {
            throw IOException("JM API base URL must use http or https.")
        }

        return candidate
    }

    private fun isApiPrefetchDisabled(): Boolean =
        preferences.getBoolean(DISABLE_API_PREFETCH_PREF, DEFAULT_DISABLE_API_PREFETCH)

    private fun maybeDisableApiPrefetch(imageUrl: String): String {
        if (!isApiPrefetchDisabled()) return imageUrl

        val parsed = imageUrl.toHttpUrlOrNull() ?: return imageUrl
        if (
            parsed.queryParameter("jmid") == null ||
            parsed.queryParameter("chapter") == null ||
            parsed.queryParameter("page") == null
        ) {
            return imageUrl
        }

        return parsed.newBuilder()
            .setQueryParameter("prefetch", "0")
            .build()
            .toString()
    }

    companion object {
        private const val API_BASE_URL_PREF = "api_base_url"
        private const val DISABLE_API_PREFETCH_PREF = "disable_api_prefetch"
        private const val DEFAULT_API_BASE_URL = "http://127.0.0.1:8088"
        private const val DEFAULT_DISABLE_API_PREFETCH = false
        private const val DEFAULT_SEARCH_ORDER = "mr"
        private const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36"

        private val JM_PREFIX_REGEX = Regex("""(?i)JM(\d+)""")
        private val PURE_ID_REGEX = Regex("""(\d{1,20})""")
        private val QUERY_ID_REGEX = Regex("""[?&](?:jmid|id)=(\d{1,20})""")
        private val PATH_ID_REGEX = Regex("""/(?:(?:album|photo)s?)/(\d{1,20})""", RegexOption.IGNORE_CASE)

        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}

private val SEARCH_SORT_LABELS = arrayOf(
    "Default",
    "Most views",
    "Most images",
    "Highest likes",
    "New",
)

private val SEARCH_SORT_CODES = arrayOf("mr", "mv", "mp", "tf", "new")

private class SortFilter : Filter.Select<String>("Sort", SEARCH_SORT_LABELS) {
    fun selectedOrder(): String = SEARCH_SORT_CODES.getOrElse(state) { "mr" }
}
