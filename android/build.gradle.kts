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

subprojects {
    project.evaluationDependsOn(":app")
}

// Workaround for Flutter plugins that still don't declare a `namespace`
// (required by AGP 8+). Fill it from the plugin's AndroidManifest `package`,
// falling back to the project group. e.g. on_audio_query_android 1.1.0.
subprojects {
    afterEvaluate {
        val androidExtension = extensions.findByName("android") ?: return@afterEvaluate
        val getNamespace = androidExtension.javaClass.methods
            .firstOrNull { it.name == "getNamespace" } ?: return@afterEvaluate
        val currentNamespace = getNamespace.invoke(androidExtension) as? String
        if (!currentNamespace.isNullOrBlank()) return@afterEvaluate

        val manifestPackage = file("src/main/AndroidManifest.xml")
            .takeIf { it.exists() }
            ?.readText()
            ?.let { Regex("package=\"([^\"]+)\"").find(it)?.groupValues?.getOrNull(1) }

        val namespace = manifestPackage?.takeIf { it.isNotBlank() }
            ?: project.group.toString().takeIf { it.isNotBlank() }
            ?: return@afterEvaluate

        androidExtension.javaClass.methods
            .firstOrNull { it.name == "setNamespace" && it.parameterTypes.size == 1 }
            ?.invoke(androidExtension, namespace)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
