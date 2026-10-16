import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: the Quibase key lives outside the repo (~/.quibase, backed
// up by the owner). QUIBASE_KEY_PROPERTIES overrides the path. Without it
// (CI, a fresh machine) release builds fall back to the debug key — such a
// build can't update a tablet that has the real one installed.
val quibaseKeyFile = file(System.getenv("QUIBASE_KEY_PROPERTIES") ?: (System.getProperty("user.home") + "/.quibase/key.properties"))
val quibaseKey = Properties().apply { if (quibaseKeyFile.exists()) load(FileInputStream(quibaseKeyFile)) }

android {
    namespace = "com.quiccpos.quibase"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.quiccpos.quibase"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (quibaseKeyFile.exists()) {
                storeFile = file(quibaseKey["storeFile"] as String)
                storePassword = quibaseKey["storePassword"] as String
                keyAlias = quibaseKey["keyAlias"] as String
                keyPassword = quibaseKey["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (quibaseKeyFile.exists()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1") // FileProvider for the self-update installer
}

flutter {
    source = "../.."
}
