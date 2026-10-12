plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.liana.ime"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.liana.ime"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.2.0"
    }

    // 原生库是预构建好的（platforms/android/build_native.sh 产物），无需 NDK 构建
    sourceSets {
        getByName("main") {
            jniLibs.srcDir("src/main/jniLibs")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

// 零 androidx：IME 服务与键盘 UI 全部用 framework API，保持 APK 最小
dependencies {
}