import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing. The keystore and both passwords live in
// ~/.android/n3d-release.properties, outside every repo, so nothing secret is
// ever committed. The lookup has to sit at the top level: inside the android {}
// block `java` binds to the Android DSL's own member and java.util.Properties
// stops resolving. Without that file the release build still assembles — just
// unsigned.
val releaseKeyProps = Properties()
val releaseKeyPropsFile = File(System.getProperty("user.home"), ".android/n3d-release.properties")
if (releaseKeyPropsFile.exists()) releaseKeyPropsFile.inputStream().use { releaseKeyProps.load(it) }
val hasReleaseKey = releaseKeyProps.getProperty("storeFile")?.let { path -> File(path).exists() } == true

android {
    namespace = "com.kotatko.sattracker"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.kotatko.sattracker"
        minSdk = 26          // Android 8.0 — covers ~95% of devices, needed for GnssStatus APIs
        targetSdk = 35
        // 2 / 1.1.0: the AdMob banner and the Play Billing "remove ads" purchase
        // were taken out completely. See the changelog in README.md.
        versionCode = 2
        versionName = "1.1.0"
    }

    signingConfigs {
        if (hasReleaseKey) create("release") {
            storeFile = File(releaseKeyProps.getProperty("storeFile"))
            storePassword = releaseKeyProps.getProperty("storePassword")
            keyAlias = releaseKeyProps.getProperty("keyAlias")
            keyPassword = releaseKeyProps.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    buildFeatures {
        viewBinding = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")

    // Location + GNSS
    implementation("com.google.android.gms:play-services-location:21.3.0")

    // Networking for TLE refresh
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
