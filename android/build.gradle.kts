import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    if (project.name == "app") {
        val newSubprojectBuildDir = newBuildDir.dir(project.name)
        project.layout.buildDirectory.value(newSubprojectBuildDir)
    }
}

// Compatibility shims for Flutter plugins that haven't caught up with AGP 8.
// Must be registered before any subproject is evaluated (i.e. before the
// `evaluationDependsOn(":app")` block below), otherwise calling afterEvaluate
// on an already-evaluated project fails.
subprojects {
    if (state.executed) return@subprojects

    // Align the Kotlin bytecode target across all modules. For plugins that set
    // nothing, AGP defaults Java to 1.8 while Kotlin follows the toolchain JDK
    // (17), which AGP 8 rejects with
    // "Inconsistent JVM-target compatibility detected for tasks ...".
    tasks.withType<KotlinCompile>().configureEach {
        kotlinOptions.jvmTarget = JavaVersion.VERSION_17.toString()
    }

    afterEvaluate {
        val androidExtension = extensions.findByName("android") ?: return@afterEvaluate

        // 1) Fill a missing `namespace` (required by AGP 8+) from the plugin's
        //    AndroidManifest `package`, falling back to the project group.
        //    e.g. on_audio_query_android 1.1.0.
        val getNamespace = androidExtension.javaClass.methods
            .firstOrNull { it.name == "getNamespace" } ?: return@afterEvaluate
        val currentNamespace = getNamespace.invoke(androidExtension) as? String
        if (currentNamespace.isNullOrBlank()) {
            val manifestPackage = file("src/main/AndroidManifest.xml")
                .takeIf { it.exists() }
                ?.readText()
                ?.let { Regex("package=\"([^\"]+)\"").find(it)?.groupValues?.getOrNull(1) }

            val namespace = manifestPackage?.takeIf { it.isNotBlank() }
                ?: project.group.toString().takeIf { it.isNotBlank() }
            if (namespace != null) {
                androidExtension.javaClass.methods
                    .firstOrNull { it.name == "setNamespace" && it.parameterTypes.size == 1 }
                    ?.invoke(androidExtension, namespace)
            }
        }

        // 2) Force the Java bytecode target to 17 so it matches Kotlin.
        val compileOptions = androidExtension.javaClass.methods
            .firstOrNull { it.name == "getCompileOptions" }
            ?.invoke(androidExtension)
        if (compileOptions != null) {
            listOf("setSourceCompatibility", "setTargetCompatibility").forEach { setter ->
                compileOptions.javaClass.methods
                    .firstOrNull { it.name == setter && it.parameterTypes.size == 1 }
                    ?.invoke(compileOptions, JavaVersion.VERSION_17)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// audio_service：通知渠道配置不再写 shared_prefs + 通知栏改成自定义卡片
//
// 插件每次 configure 都会把通知渠道配置写进
// `shared_prefs/audio_service_preferences.xml`（AudioServiceConfig.save()）。本项目
// 的设置统一存在 `files/settings.json`，那份 XML 只是同样内容的副本，唯一的用处是
// 「服务比 Dart 下发配置更早启动」时给 AudioService.onCreate 读回默认值。
//
// 这里在配置阶段把插件的 Java 源码复制到 build 目录，改好 `AudioServiceConfig.java`
// 之后再把该模块的 Java 源码目录指过去：
//   1) save() 直接 return，不再写任何文件；
//   2) 构造函数读不到配置时，用本项目实际下发的通知配置兜底（取值见
//      lib/core/services/audio_service_init.dart，两边要一起改）；
//   3) buildNotification() 改成先试自定义卡片（MintNotification，源码在
//      `android/mintmusic-patch/`，只对 Android 生效），失败退回原 MediaStyle 通知；
//      并额外暴露 refreshNotification()，供 Dart 侧改收藏状态后立即重绘。
//
// 只改 build 目录里的副本，pub 缓存中的插件源码保持原样；任何一步失败（插件升级
// 后锚点对不上、目录不可写等）都只打印警告并保留原始源码，不会让构建失败。
// ---------------------------------------------------------------------------
subprojects {
    if (project.name != "audio_service") return@subprojects

    afterEvaluate {
        runCatching {
            val sourceDir = layout.projectDirectory.dir("src/main/java").asFile
            val relativePath = "com/ryanheise/audioservice/AudioServiceConfig.java"
            val original = File(sourceDir, relativePath)
            require(original.isFile) { "找不到 $relativePath" }

            var text = original.readText()

            val saveMarker = "    public void save() {"
            require(text.contains(saveMarker)) { "AudioServiceConfig.save() 的结构变了" }
            text = text.replace(
                saveMarker,
                saveMarker +
                    "\n        // patched by MintMusic: config lives in settings.json, " +
                    "never write shared_prefs\n        if (true) return;",
            )

            val constructorMarker =
                "        browsableRootExtras = preferences.getString(KEY_BROWSABLE_ROOT_EXTRAS, null);"
            require(text.contains(constructorMarker)) { "AudioServiceConfig 构造函数的结构变了" }
            text = text.replace(
                constructorMarker,
                constructorMarker +
                    "\n        // patched by MintMusic: nothing is persisted, fall back to the " +
                    "values this app passes in\n        // (lib/core/services/audio_service_init.dart)\n" +
                    "        if (androidNotificationChannelId == null) {\n" +
                    "            androidNotificationChannelId = \"com.mintmusic.channel.audio\";\n" +
                    "            androidNotificationChannelName = \"\\u97f3\\u4e50\\u64ad\\u653e\";\n" +
                    "            androidNotificationIcon = \"mipmap/logo\";\n" +
                    "            androidNotificationOngoing = true;\n" +
                    "            androidNotificationShowBadge = false;\n" +
                    "            notificationColor = 0xFF1DB954;\n" +
                    "        }",
            )

            val patchedDir = layout.buildDirectory.dir("mintmusic-patched-java").get().asFile
            // 每次重新铺一份，避免插件升级后残留已经删掉的源码（内容不变时
            // Gradle 会按内容哈希判定增量编译，不会因此全量重编）。
            patchedDir.deleteRecursively()
            sourceDir.copyRecursively(patchedDir, overwrite = true)
            File(patchedDir, relativePath).writeText(text)

            // --- AudioService：通知栏换成自定义卡片 ---
            //
            // 原方法改名为 buildNotificationMedia()（MediaStyle 那套逻辑原样保留），
            // 新增的 buildNotification() 先问 MintNotification 要自定义通知，拿不到
            // （资源缺失 / 布局异常）就退回原实现。
            val servicePath = "com/ryanheise/audioservice/AudioService.java"
            val serviceFile = File(sourceDir, servicePath)
            require(serviceFile.isFile) { "找不到 $servicePath" }
            var serviceText = serviceFile.readText()

            val buildMarker = "    private Notification buildNotification() {"
            require(serviceText.contains(buildMarker)) { "AudioService.buildNotification() 的结构变了" }
            serviceText = serviceText.replace(
                buildMarker,
                """    private Notification buildNotification() {
        // patched by MintMusic: 自定义通知卡片，失败时退回下面的 MediaStyle 通知
        final Notification custom = MintNotification.build(
                this,
                getNotificationBuilder(),
                mediaMetadata == null ? null : mediaMetadata.getDescription(),
                artBitmap,
                playing,
                config.androidNotificationOngoing,
                config.androidNotificationClickStartsActivity
                        ? mediaSession.getController().getSessionActivity() : null,
                config.androidNotificationOngoing
                        ? buildMediaButtonPendingIntent(PlaybackStateCompat.ACTION_STOP) : null);
        if (custom != null) return custom;
        return buildNotificationMedia();
    }

    /** patched by MintMusic: 收藏等状态变化后立即重绘通知（不改播放状态）。 */
    public static void refreshNotification() {
        if (instance != null) instance.updateNotification();
    }

    private Notification buildNotificationMedia() {""",
            )

            File(patchedDir, servicePath).writeText(serviceText)

            // 自定义通知的实现类：只需要 Java 代码，布局 / 图标都在 app 模块的 res 里。
            // 源码放在 android/mintmusic-patch/，所以要从 rootProject 取（这里是子项目上下文）。
            val extraSource =
                rootProject.file("mintmusic-patch/com/ryanheise/audioservice/MintNotification.java")
            require(extraSource.isFile) { "找不到 MintNotification.java" }
            val extraTarget = File(patchedDir, "com/ryanheise/audioservice/MintNotification.java")
            extraTarget.parentFile?.mkdirs()
            extraTarget.writeText(extraSource.readText())

            val androidExtension = extensions.findByName("android")
                ?: error("没有 android 扩展")
            val sourceSets = androidExtension.javaClass
                .getMethod("getSourceSets")
                .invoke(androidExtension)
            val mainSourceSet = sourceSets.javaClass
                .getMethod("getByName", String::class.java)
                .invoke(sourceSets, "main")
            val javaSourceDirs = mainSourceSet.javaClass
                .getMethod("getJava")
                .invoke(mainSourceSet)
            javaSourceDirs.javaClass
                .getMethod("setSrcDirs", Iterable::class.java)
                .invoke(javaSourceDirs, listOf(patchedDir))

            logger.lifecycle("[audio_service] 已应用「不写 shared_prefs + 自定义通知栏」补丁")
        }.onFailure { error ->
            logger.warn("[audio_service] 未打补丁，继续使用原始源码：${error.message}")
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
