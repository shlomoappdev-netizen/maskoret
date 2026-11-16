import java.util.Base64
import java.util.Properties

// The permanent release key: every update must be signed with the same key, or Android won't install it.
// On the Mac it's read from android/key.properties; on GitHub from the ANDROID_KEYSTORE_* secrets.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val releaseStoreFile: String? = keyProps.getProperty("storeFile")?.let { file(it).path } ?: System.getenv("ANDROID_KEYSTORE_PATH")
val releaseStorePassword: String? = keyProps.getProperty("storePassword") ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")

// The Google Play build: built with --dart-define=STORE=play (tools/build_play_bundle.sh). Flutter hands the defines to
// Gradle as base64 in "dart-defines"; with STORE=play the manifest in src/play removes what only self-update needs.
// Every other build (the APK on the site, CI, upload_android_build.sh) is unchanged.
val playStore: Boolean = (findProperty("dart-defines") as String?)
    ?.split(",")
    ?.any { define: String -> runCatching { String(Base64.getDecoder().decode(define)) }.getOrNull() == "STORE=play" }
    ?: false

// Firebase (push notifications): the values of android/app/google-services.json become the string resources that
// Firebase reads at startup — what the google-services Gradle plugin does. The file isn't in the public repo; a build
// without it works, just without push (Firebase stays off and the app gets no token).
val firebase: Map<String, String> = run {
    val f = file("google-services.json")
    if (!f.exists()) return@run emptyMap()
    @Suppress("UNCHECKED_CAST")
    val json = groovy.json.JsonSlurper().parse(f) as Map<String, Any?>
    val project = json["project_info"] as Map<String, Any?>
    val client = (json["client"] as List<Map<String, Any?>>).first {
        ((it["client_info"] as Map<String, Any?>)["android_client_info"] as Map<String, Any?>)["package_name"] == "com.shlomodavid.maskoret"
    }
    mapOf(
        "google_app_id" to (client["client_info"] as Map<String, Any?>)["mobilesdk_app_id"] as String,
        "google_api_key" to ((client["api_key"] as List<Map<String, Any?>>).first()["current_key"] as String),
        "gcm_defaultSenderId" to project["project_number"] as String,
        "project_id" to project["project_id"] as String,
    )
}

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
        // flutter_local_notifications needs the newer Java APIs on older Android versions.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        // The Firebase values below are string resources made by this file.
        resValues = true
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
        firebase.forEach { (name, value) -> resValue("string", name, value) }
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

    if (playStore) {
        sourceSets.getByName("release").manifest.srcFile("src/play/AndroidManifest.xml")
    }

    buildTypes {
        release {
            // Without the release key (e.g. a fresh checkout) the build still works, signed with the debug key —
            // but such an APK can't update, or be updated by, the published one.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Push notifications from the assistant (the token and showing the notification; nothing else of Firebase).
    implementation("com.google.firebase:firebase-messaging:24.1.0")
}
