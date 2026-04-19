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

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}
val useGpuForLlm = localProperties.getProperty("useGpuForLlm", "false").toBoolean()

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
        buildConfigField("Boolean", "USE_GPU_FOR_LLM", useGpuForLlm.toString())
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
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-guava:1.10.2")
    implementation("com.google.protobuf:protobuf-javalite:3.25.4")
}

tasks.register("prepareKotlinBuildScriptModel") {}
