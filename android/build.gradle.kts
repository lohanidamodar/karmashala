allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

// A Flutter plugin's Gradle project is named after the package — `:mobile_scanner`
// — but its sources live in the pub cache under a *versioned* directory,
// `<cache>/mobile_scanner-7.4.2/android`. Naming the build directory after the
// project alone therefore hands a freshly upgraded plugin the previous version's
// build directory, and with it that version's Kotlin incremental-compilation
// caches, which are keyed to the old version's absolute source paths. Kotlin then
// resolves no dirty sources, compiles nothing, and writes back an empty
// `tmp/kotlin-classes/<variant>`; Gradle records that empty output as the task's
// up-to-date state, so every later build skips the compile. The plugin's
// classes.jar ends up holding only `R.class`, and `:app:compileReleaseJavaWithJavac`
// fails with "cannot find symbol" on the classes GeneratedPluginRegistrant names.
//
// Seen 2026-09-21 on Gradle 9.1.0 / AGP 9.0.1 / KGP 2.3.20, for exactly the three
// plugins upgraded that day — device_info_plus 12.4.0 -> 13.2.0, package_info_plus
// 9.0.1 -> 10.2.1, mobile_scanner 7.4.0 -> 7.4.2 — while every plugin whose
// version was unchanged built fine.
//
// Qualifying the directory with the pub-cache folder name gives each version its
// own build state, so an upgrade can never inherit a stale one. Only subprojects
// that actually sit in a `<name>-<version>/android` layout are renamed: `:app`,
// path plugins under `packages/`, and the SDK's own plugins keep their plain name.
subprojects {
    val pubCacheDirName = project.projectDir.parentFile?.name
    val subprojectDirName =
        if (pubCacheDirName != null && pubCacheDirName.startsWith("${project.name}-")) {
            pubCacheDirName
        } else {
            project.name
        }
    val newSubprojectBuildDir: Directory = newBuildDir.dir(subprojectDirName)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
