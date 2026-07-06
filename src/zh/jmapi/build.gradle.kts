plugins {
    alias(kei.plugins.extension)
}

keiyoushi {
    name = "JM API"
    versionCode = 6
    contentWarning = ContentWarning.NSFW
    libVersion = "1.4"

    source {
        name = "JM API"
        lang = "zh"
        baseUrl = "http://127.0.0.1:8088"
    }
}
