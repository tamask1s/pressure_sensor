import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val signingFile = rootProject.file("key.properties")
val signing = Properties().apply { if (signingFile.exists()) signingFile.inputStream().use { load(it) } }
android {
    namespace = "hu.helti.pressure_field"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_11.toString() }
    defaultConfig {
        applicationId = "hu.helti.pressure_field"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    if (signingFile.exists()) signingConfigs.create("production") {
        keyAlias = signing["keyAlias"] as String
        keyPassword = signing["keyPassword"] as String
        storeFile = file(signing["storeFile"] as String)
        storePassword = signing["storePassword"] as String
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (signingFile.exists()) "production" else "debug")
        }
    }
}
flutter { source = "../.." }
