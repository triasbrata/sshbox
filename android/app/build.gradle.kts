import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key, from android/key.properties (git-ignored, never committed):
// storeFile, storePassword, keyAlias, keyPassword. How to make one:
// https://docs.flutter.dev/deployment/android#sign-the-app
val keystoreProperties = Properties().apply {
    rootProject.file("key.properties").takeIf { it.exists() }?.reader()?.use(::load)
}

android {
    namespace = "dev.triasbrata.sshbox"
    // flutter_secure_storage 11 compiles against SDK 37, so we cannot stay on
    // 36. But `flutter.compileSdkVersion` asks for the hash string
    // "android-37", and Google now ships only the minor-versioned platforms
    // (android-37.0 / .1 / .2) — no plain android-37 exists to resolve.
    // AGP 9's compileSdkMinor names the installed platform explicitly.
    compileSdk = 37
    compileSdkMinor = 0
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications schedules against java.time, which needs
        // desugaring to run on the older API levels in minSdk.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Must match package_name in android/app/google-services.json, or the
        // google-services plugin fails the build.
        applicationId = "cloud.brata.terminal"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!keystoreProperties.isEmpty) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Without key.properties, the debug key: enough for
            // `flutter run --release`, and no build to publish or hand out.
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // NativeCrashesTest: the native crash scrub, on the JVM.
    testImplementation("junit:junit:4.13.2")
}
