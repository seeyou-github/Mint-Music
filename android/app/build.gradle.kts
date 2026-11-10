import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 版本号：APK 的 versionName / versionCode = 构建时间（北京时间） ──────────
//
// 与 Windows 的文件版本规则一致（见 tool/win_build_stamp.dart）：本地构建和
// GitHub Actions 都通过 Gradle 取当前时间，产物一眼能看出是哪次构建，不再
// 永远是 pubspec 里的 2.0.0+1。时间固定按 UTC+8 计算，与构建机时区无关。
//
// versionName 是显示值（例：2026.1110.0106），运行时由 MainActivity 通过
// `com.mintmusic/app_info` 通道读回，「我的」页面显示它。
// versionCode 用「1970 年起的第几天 * 10000 + 时分」，每次构建都单调递增，
// 同一天多次构建也能直接覆盖安装（远小于 Android 的 21 亿上限）。
val buildTime = Calendar.getInstance(TimeZone.getTimeZone("Asia/Shanghai"))
val buildVersionName = String.format(
    Locale.US,
    "%04d.%02d%02d.%02d%02d",
    buildTime.get(Calendar.YEAR),
    buildTime.get(Calendar.MONTH) + 1,
    buildTime.get(Calendar.DAY_OF_MONTH),
    buildTime.get(Calendar.HOUR_OF_DAY),
    buildTime.get(Calendar.MINUTE),
)
val buildVersionCode = (buildTime.timeInMillis / 86_400_000L).toInt() * 10000 +
    buildTime.get(Calendar.HOUR_OF_DAY) * 100 +
    buildTime.get(Calendar.MINUTE)

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
        versionCode = buildVersionCode
        versionName = buildVersionName
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
