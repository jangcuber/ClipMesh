plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "dev.clipmesh.android"
    compileSdk = 35
    defaultConfig {
        applicationId = "dev.clipmesh.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 6
        versionName = "0.3.0"
        testInstrumentationRunner = "android.test.InstrumentationTestRunner"
    }
    packaging { jniLibs { useLegacyPackaging = true } }
    buildTypes { release { isMinifyEnabled = false } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.zxing:core:3.5.3")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    compileOnly("de.robv.android.xposed:api:82")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

// A normal APK must include its P2P executable. Explicit relay-only host builds
// may opt out, but CI and distribution builds never set this property.
val verifyNativeTransport by tasks.registering {
    doLast {
        val native = file("src/main/jniLibs/arm64-v8a/libclipmesh_transport.so")
        if (providers.gradleProperty("clipmesh.relayOnly").orNull != "true") {
            check(native.isFile && native.length() > 0) {
                "Missing bundled P2P transport. Run bash platforms/android/build-native.sh from the repository root first."
            }
        }
    }
}
tasks.named("preBuild") { dependsOn(verifyNativeTransport) }
