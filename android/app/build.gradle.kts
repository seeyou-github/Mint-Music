plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 版本号：固定 20261111 ──────────────────────────────────────────────────
//
// 以前 versionCode / versionName 取「构建时间（北京时间）」，本地编译和
// GitHub Actions 打出来的包每次都不一样。现在两条流水线共用同一组固定值：
// 同一个版本号就是同一个包，覆盖安装、比对版本都不再受编译时刻影响。
//
// versionCode 是整数 id（20261111，远小于 Android 的 21 亿上限）；
// versionName 是显示值，运行时由 MainActivity 通过 `com.mintmusic/app_info`
// 通道读回，「我的」页面显示它。CI 用 --split-per-abi 打包时 Flutter 会在
// versionCode 上加 ABI 偏移（arm64 → 20263111），同样是固定值、不随编译
// 时间变化；只含 arm64-v8a 也由分 ABI 打包保证。
//
// 发新版想改号时，直接改下面这两个值即可。
val appVersionCode = 20261111
val appVersionName = "20261111"

android {
    namespace = "com.kingmc.mintmusic.mintmusic"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.kingmc.mintmusic.mintmusic"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = appVersionCode
        versionName = appVersionName
    }

    packaging {
        resources {
            excludes += setOf(
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/DEPENDENCIES",
            )
        }
    }

    signingConfigs {
        create("mintmusic") {
            storeFile = rootProject.file("app/Test.jks")
            storePassword = "123456"
            keyAlias = "Test"
            keyPassword = "123456"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("mintmusic")
        }
        release {
            signingConfig = signingConfigs.getByName("mintmusic")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    implementation(files("libs/jaudiotagger-android.jar"))
}

flutter {
    source = "../.."
}
