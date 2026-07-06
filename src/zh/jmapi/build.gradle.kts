plugins {
    alias(kei.plugins.extension)
}

keiyoushi {
    name = "JM API"
    versionCode = 1
    contentWarning = ContentWarning.NSFW
    libVersion = "1.4"

    source {
        name = "JM API"
        lang = "zh"
        baseUrl = "http://0.0.0.0:8088"
    }
}
