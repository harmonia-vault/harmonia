import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// flutter build 的 --dart-define 以 Base64 逗号列表传给 Gradle。
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?).orEmpty().split(",").filter { it.isNotEmpty() }
        .map { String(Base64.getDecoder().decode(it)) }
        .mapNotNull { d -> d.indexOf('=').takeIf { it > 0 }?.let { d.substring(0, it) to d.substring(it + 1) } }
        .toMap()

android {
    namespace = "org.harmoniavault.harmonia"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.harmoniavault.harmonia"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 后台通知的 Firebase 配置（设计文档 18.4）：发布构建由 CI 从 --dart-define 传入，写成 Firebase 自动初始化读取的资源。
        // 没有传入时不初始化 Firebase，App 按“这台手机暂时收不到后台通知”处理。
        val firebaseAppId = dartDefines["FIREBASE_APP_ID"].orEmpty()
        if (firebaseAppId.isNotEmpty()) {
            resValue("string", "google_app_id", firebaseAppId)
            resValue("string", "gcm_defaultSenderId", firebaseAppId.split(":").getOrElse(1) { "" })
            resValue("string", "google_api_key", dartDefines["FIREBASE_API_KEY"].orEmpty())
            resValue("string", "project_id", dartDefines["FIREBASE_PROJECT_ID"].orEmpty())
        }
    }

    buildFeatures {
        resValues = true
    }

    // 发布签名：CI 写入 android/key.properties 与密钥库；本地没有时使用调试签名，只供自测。
    val keyProps = Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    signingConfigs {
        if (keyProps.isNotEmpty()) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keyProps.isNotEmpty()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
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
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("com.google.firebase:firebase-messaging:26.0.1")
}
