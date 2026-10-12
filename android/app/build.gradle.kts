import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Assinatura de release (Play Store). As senhas e o caminho da chave ficam em
// android/key.properties — FORA do git (.gitignore; modelo em
// android/key.properties.exemplo). Sem esse arquivo, o APK de release cai na
// chave de debug: serve para testar no aparelho, nunca para enviar à loja.
// Passo a passo em docs/PUBLICACAO.md.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) keystorePropertiesFile.inputStream().use { load(it) }
}
val hasReleaseKey = keystorePropertiesFile.exists()

// Portão do build de release. O pacote da loja (.aab) só sai com a chave de
// upload: a Play recusa pacote assinado com a de debug. E um key.properties
// pela metade não pode virar assinatura de debug calada, nem no APK. O build
// de debug não passa por aqui.
val tarefas = gradle.startParameter.taskNames.map { it.substringAfterLast(':') }
if (tarefas.any { it.endsWith("Release") }) {
    val publicacao = "Passo a passo em docs/PUBLICACAO.md."
    // Sem o registro dos plugins o app compila, instala e trava na abertura
    // ("No JNI instance is available"). Aconteceu em 12/10: build com --no-pub
    // depois de um `flutter pub get` que parou no meio (Windows sem o Modo de
    // Desenvolvedor). Quem gera o arquivo é o `flutter pub get`.
    if (!file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java").isFile) {
        throw GradleException("Plugins sem registro (GeneratedPluginRegistrant.java): rode `flutter pub get` antes do build. $publicacao")
    }
    if (!hasReleaseKey && "bundleRelease" in tarefas) {
        throw GradleException("Sem android/key.properties: o .aab da loja precisa da chave de upload. $publicacao")
    }
    if (hasReleaseKey) {
        val faltam = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .filter { keystoreProperties.getProperty(it).isNullOrBlank() }
        if (faltam.isNotEmpty()) {
            throw GradleException("android/key.properties sem ${faltam.joinToString()}. Modelo em android/key.properties.exemplo.")
        }
        val chave = file(keystoreProperties.getProperty("storeFile"))
        if (!chave.isFile) {
            throw GradleException("Chave de upload não encontrada em $chave (storeFile de android/key.properties). $publicacao")
        }
    }
}

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
                // Vazio só chega aqui no build de debug, que não usa esta chave.
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Sem a chave de upload, só o APK de teste (o .aab para acima).
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
