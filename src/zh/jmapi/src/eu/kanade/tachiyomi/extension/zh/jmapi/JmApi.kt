package eu.kanade.tachiyomi.extension.zh.jmapi

import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import keiyoushi.annotation.Source
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import okhttp3.Response
import java.io.IOException

@Source
abstract class JmApi : HttpSource() {

    override val supportsLatest = false

    override fun headersBuilder(): Headers.Builder {
        return Headers.Builder()
            .add("User-Agent", System.getProperty("http.agent") ?: DEFAULT_USER_AGENT)
            .add("Accept", "application/json,image/avif,image/webp,image/apng,image/*,*/*;q=0.8")
    }

    override fun popularMangaRequest(page: Int): Request {
        return GET("$baseUrl/?health=1", headers)
    }

    override fun popularMangaParse(response: Response): MangasPage {
        return MangasPage(emptyList(), false)
    }

    override fun latestUpdatesRequest(page: Int): Request {
        throw UnsupportedOperationException()
    }

    override fun latestUpdatesParse(response: Response): MangasPage {
        throw UnsupportedOperationException()
    }

    override fun searchMangaRequest(page: Int, query: String, filters: FilterList): Request {
        val jmId = parseJmId(query) ?: throw IOException("Enter a JM ID or album URL")
        val url = baseUrl.toHttpUrl().newBuilder()
            .addQueryParameter("jmid", jmId)
            .build()
        return GET(url, headers)
    }

    override fun searchMangaParse(response: Response): MangasPage {
        val data = response.parseData<JmAlbumEnvelope>()
        return MangasPage(listOf(data.toSManga(baseUrl)), false)
    }

    override fun mangaDetailsRequest(manga: SManga): Request {
        val url = baseUrl.toHttpUrl().newBuilder()
            .addQueryParameter("jmid", manga.jmId)
            .build()
        return GET(url, headers)
    }

    override fun mangaDetailsParse(response: Response): SManga {
        return response.parseData<JmAlbumEnvelope>().toSManga(baseUrl)
    }

    override fun chapterListRequest(manga: SManga): Request {
        val url = baseUrl.toHttpUrl().newBuilder()
            .addQueryParameter("jmid", manga.jmId)
            .build()
        return GET(url, headers)
    }

    override fun chapterListParse(response: Response): List<SChapter> {
        val data = response.parseData<JmAlbumEnvelope>()
        return data.chapters.map { chapter ->
            chapter.toSChapter(data.album.albumId, data.album.name)
        }
    }

    override fun pageListRequest(chapter: SChapter): Request {
        val (albumId, chapterId) = chapter.jmIds
        val url = baseUrl.toHttpUrl().newBuilder()
            .addQueryParameter("jmid", albumId)
            .addQueryParameter("chapter", chapterId)
            .addQueryParameter("format", "min")
            .build()
        return GET(url, headers)
    }

    override fun pageListParse(response: Response): List<Page> {
        val data = response.parseData<JmChapterEnvelope>()
        val chapter = data.chapters.firstOrNull() ?: throw IOException("Chapter not found")
        val pageCount = chapter.pageCount.takeIf { it > 0 } ?: chapter.images.size
        if (pageCount <= 0) throw IOException("No pages found")

        return (1..pageCount).map { pageNumber ->
            Page(
                index = pageNumber - 1,
                imageUrl = pageImageUrl(data.album.albumId, chapter.photoId, pageNumber),
            )
        }
    }

    override fun imageUrlParse(response: Response): String {
        throw UnsupportedOperationException()
    }

    override fun imageRequest(page: Page): Request {
        val imageUrl = page.imageUrl ?: throw IOException("Missing image URL")
        return GET(imageUrl, headers)
    }

    override fun getMangaUrl(manga: SManga): String {
        return "$baseUrl/?jmid=${manga.jmId}"
    }

    override fun getChapterUrl(chapter: SChapter): String {
        val (albumId, chapterId) = chapter.jmIds
        return "$baseUrl/?jmid=$albumId&chapter=$chapterId"
    }

    private fun pageImageUrl(albumId: String, chapterId: String, pageNumber: Int): String {
        return baseUrl.toHttpUrl().newBuilder()
            .addQueryParameter("jmid", albumId)
            .addQueryParameter("chapter", chapterId)
            .addQueryParameter("page", pageNumber.toString())
            .build()
            .toString()
    }

    private inline fun <reified T> Response.parseData(): T {
        val payloadText = body.string()
        val payload = try {
            json.decodeFromString<JmApiResponse<T>>(payloadText)
        } catch (e: SerializationException) {
            throw IOException("Invalid JM API response", e)
        }

        if (!payload.success || payload.code != 200 || payload.data == null) {
            throw IOException(payload.error ?: "JM API returned code ${payload.code}")
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

    companion object {
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
