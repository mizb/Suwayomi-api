package eu.kanade.tachiyomi.extension.zh.jmapi

import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

private const val UNKNOWN_DATE = 0L

val SManga.jmId: String
    get() = url.substringAfterLast("/")

val SChapter.jmIds: Pair<String, String>
    get() {
        val parts = url.trim('/').split('/')
        return parts[1] to parts[2]
    }

@Serializable
data class JmApiResponse<T>(
    val code: Int = 0,
    val success: Boolean = false,
    val data: T? = null,
    val error: String? = null,
)

@Serializable
data class JmAlbumEnvelope(
    val album: JmAlbumDto,
    val chapters: List<JmChapterHeaderDto> = emptyList(),
    @SerialName("chapters_total") val chaptersTotal: Int = 0,
)

@Serializable
data class JmChapterEnvelope(
    val album: JmAlbumDto,
    val chapters: List<JmChapterDto> = emptyList(),
    @SerialName("chapters_total") val chaptersTotal: Int = 0,
    @SerialName("chapters_fetched") val chaptersFetched: Int = 0,
)

@Serializable
data class JmAlbumDto(
    @SerialName("album_id") val albumId: String,
    val name: String = "",
    val author: List<String> = emptyList(),
    val description: String = "",
    @SerialName("total_views") val totalViews: String = "0",
    val likes: String = "0",
    val comments: String = "0",
    val tags: List<String> = emptyList(),
    val works: List<String> = emptyList(),
    val actors: List<String> = emptyList(),
    val chapters: Int = 0,
)

@Serializable
data class JmChapterHeaderDto(
    @SerialName("photo_id") val photoId: String,
    val title: String = "",
    val sort: String = "1",
)

@Serializable
data class JmChapterDto(
    @SerialName("photo_id") val photoId: String,
    val title: String = "",
    val sort: String = "1",
    @SerialName("page_count") val pageCount: Int = 0,
    val images: List<JmImageDto> = emptyList(),
)

@Serializable
data class JmImageDto(
    val index: Int = 0,
    val filename: String = "",
    val url: String = "",
    @SerialName("decode_segments") val decodeSegments: Int = 0,
)

fun JmAlbumEnvelope.toSManga(baseUrl: String): SManga = album.toSManga(baseUrl, chapters.firstOrNull()?.photoId)

fun JmAlbumDto.toSManga(baseUrl: String, firstChapterId: String?): SManga {
    val cleanAuthors = author.filter { it.isNotBlank() && it != "N/A" }
    val allGenres = (tags + works + actors).map { it.trim() }.filter { it.isNotEmpty() }.distinct()

    return SManga.create().apply {
        url = "/album/$albumId"
        title = name.ifBlank { "JM $albumId" }
        author = cleanAuthors.joinToString()
        genre = allGenres.joinToString()
        status = SManga.UNKNOWN
        thumbnail_url = firstChapterId?.let { "$baseUrl/?jmid=$albumId&chapter=$it&page=1" }
        description = buildDescription()
        initialized = true
    }
}

fun JmChapterHeaderDto.toSChapter(albumId: String, albumTitle: String): SChapter = SChapter.create().apply {
    url = "/chapter/$albumId/$photoId"
    name = chapterName(albumTitle)
    chapter_number = sort.toFloatOrNull() ?: -1f
    date_upload = UNKNOWN_DATE
}

private fun JmAlbumDto.buildDescription(): String = buildList {
    if (description.isNotBlank()) add(description)
    add("Views: $totalViews")
    add("Likes: $likes")
    add("Comments: $comments")
    if (chapters > 0) add("Chapters: $chapters")
}.joinToString("\n")

private fun JmChapterHeaderDto.chapterName(albumTitle: String): String {
    if (title.isNotBlank()) return title
    if (sort == "1" && albumTitle.isNotBlank()) return albumTitle
    return "Chapter $sort"
}
