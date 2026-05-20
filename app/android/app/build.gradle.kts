import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val useGpuForLlm = project.findProperty("useGpuForLlm")?.toString()?.toBoolean() ?: false
// Speculative decoding (MTP) — off by default. Smoke-tested 2026-05-14 on OPPO Snapdragon 8 Elite + GPU:
// ~10–20% decode slowdown, 3/3 samples, vs. plain GPU. Drafter acceptance is likely poor for our
// long retrieved-context prompts + constrained medical prose. Re-test before re-enabling.
val useMtpForLlm = project.findProperty("useMtpForLlm")?.toString()?.toBoolean() ?: false

// Used in both the dependency declaration below and the BuildConfig field so the About page
// can surface what's actually linked at build time. Update in lockstep with the dependency.
val litertlmVersion = "0.12.0"

// Capture the current git commit SHA at build time so benchmark JSONs (and any other
// runtime-emitted metadata) can record which code state produced the data. Falls back to
// "unknown" outside a git checkout. Uses --short for compactness; reviewers can `git show`
// the prefix to disambiguate.
fun gitShortSha(): String {
    return try {
        val proc = ProcessBuilder("git", "rev-parse", "--short", "HEAD")
            .directory(rootDir.parentFile?.parentFile ?: rootDir)
            .redirectErrorStream(true)
            .start()
        val out = proc.inputStream.bufferedReader().readText().trim()
        proc.waitFor()
        if (out.isNotEmpty() && proc.exitValue() == 0) out else "unknown"
    } catch (e: Exception) {
        "unknown"
    }
}
val gitSha = gitShortSha()

fun propOrEnv(envName: String, propertyName: String): String? =
    System.getenv(envName)?.takeIf { it.isNotBlank() }
        ?: (keystoreProperties.getProperty(propertyName)?.takeIf { it.isNotBlank() })

android {
    namespace = "com.example.app"
    compileSdk = flutter.compileSdkVersion
    val releaseStoreFile = propOrEnv("ANDROID_KEYSTORE_PATH", "storeFile")
    val releaseStorePassword = propOrEnv("ANDROID_KEYSTORE_PASSWORD", "storePassword")
    val releaseKeyAlias = propOrEnv("ANDROID_KEY_ALIAS", "keyAlias")
    val releaseKeyPassword = propOrEnv("ANDROID_KEY_PASSWORD", "keyPassword")
    val hasCustomReleaseSigning = listOf(
        releaseStoreFile,
        releaseStorePassword,
        releaseKeyAlias,
        releaseKeyPassword,
    ).all { !it.isNullOrBlank() }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "USE_GPU_FOR_LLM", useGpuForLlm.toString())
        buildConfigField("boolean", "USE_MTP_FOR_LLM", useMtpForLlm.toString())
        buildConfigField("String", "LITERTLM_VERSION", "\"$litertlmVersion\"")
        buildConfigField("String", "GIT_SHA", "\"$gitSha\"")
    }

    sourceSets {
        getByName("main") {
            assets.srcDirs("src/main/assets", "../../../config")
        }
    }

    signingConfigs {
        create("release") {
            if (hasCustomReleaseSigning) {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false

            isShrinkResources = false

            // Real releases use the configured keystore; local/CI validation
            // falls back to the debug keystore when no release secrets exist.
            signingConfig = if (hasCustomReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}
dependencies {
    implementation("com.google.ai.edge.localagents:localagents-rag:0.2.0")
    implementation("com.google.ai.edge.litertlm:litertlm-android:$litertlmVersion")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-guava:1.10.2")
    implementation("com.google.protobuf:protobuf-javalite:3.25.4")
}

tasks.register("prepareKotlinBuildScriptModel") {}
