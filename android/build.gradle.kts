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

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
