import java.util.Properties

// The permanent release key: every update must be signed with the same key, or Android won't install it.
// On the Mac it's read from android/key.properties; on GitHub from the ANDROID_KEYSTORE_* secrets.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val releaseStoreFile: String? = keyProps.getProperty("storeFile")?.let { file(it).path } ?: System.getenv("ANDROID_KEYSTORE_PATH")
val releaseStorePassword: String? = keyProps.getProperty("storePassword") ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.shlomodavid.maskoret"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.shlomodavid.maskoret"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStoreFile != null && releaseStorePassword != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = releaseStorePassword
                keyAlias = keyProps.getProperty("keyAlias") ?: "maskoret"
                keyPassword = releaseStorePassword
            }
        }
    }

    buildTypes {
        release {
            // Without the release key (e.g. a fresh checkout) the build still works, signed with the debug key —
            // but such an APK can't update, or be updated by, the published one.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // FileProvider, for handing a downloaded update to the system installer.
    implementation("androidx.core:core-ktx:1.13.1")
}
