import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Assinatura de release (Play Store). As senhas e o caminho da chave ficam em
// android/key.properties — FORA do git (.gitignore). Sem esse arquivo, o build
// de release cai na chave de debug: serve para testar no aparelho, nunca para
// enviar à loja. Passo a passo em docs/PUBLICACAO.md.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.celiware.ihm"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Identificador na Play Store. Muda livremente ATÉ o primeiro envio;
        // depois é permanente (outro ID = outro app na loja).
        applicationId = "com.celiware.ihm"
        minSdk = flutter.minSdkVersion
        // FIXO em 36, de propósito. `flutter.targetSdkVersion` sobe sozinho a cada
        // `flutter upgrade`; com alvo 37 o Android exige a permissão
        // ACCESS_LOCAL_NETWORK (pedida em tempo de execução) e, sem ela, TODA
        // conexão com CLP falha em tempo esgotado. Subir para 37 só numa versão
        // que já peça essa permissão (docs/REQUISITOS-ETAPA4.md §2).
        targetSdk = 36
        // Vêm do pubspec.yaml (version: nome+código).
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
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
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
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
    // Cabo USB-OTG (PortaSerialUsb.kt): drivers CH340/CH341, CP210x, FTDI,
    // PL2303 e CDC (Arduino) em Java puro — nada de biblioteca nativa no APK.
    // MIT. Só publicada na JitPack (repositório em android/build.gradle.kts).
    implementation("com.github.mik3y:usb-serial-for-android:3.11.0")
}
