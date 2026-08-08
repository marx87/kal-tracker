import com.android.build.gradle.LibraryExtension
import groovy.lang.GroovyObject
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.withGroovyBuilder

group = "dev.fluttercommunity.plus.device_info"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.0"

    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.12.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
val builtInKotlinProperty = providers.gradleProperty("android.builtInKotlin").orNull
val isBuiltInKotlinEnabled = agpMajor >= 9 &&
    (builtInKotlinProperty == null || builtInKotlinProperty.toBoolean())
val shouldApplyKotlinAndroidPlugin = agpMajor < 9 || !isBuiltInKotlinEnabled

// With AGP 9 and built-in Kotlin disabled, both Android and Kotlin must be
// applied imperatively. Applying Android in a plugins block first leaves the
// later Kotlin task detached from src/main/kotlin in this workspace.
apply(plugin = "com.android.library")
if (shouldApplyKotlinAndroidPlugin) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

fun GroovyObject.intProperty(name: String): Int {
    val value = getProperty(name)
    return when (value) {
        is Number -> value.toInt()
        is String -> value.toInt()
        else -> error("Property '$name' is not an Int-compatible value: $value")
    }
}

val flutterExtension = extensions.getByName("flutter") as GroovyObject

configure<LibraryExtension> {
    namespace = "dev.fluttercommunity.plus.device_info"
    compileSdk = flutterExtension.intProperty("compileSdkVersion")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 21
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    lint {
        disable.addAll(listOf("InvalidPackage", "MissingPermission"))
    }

    if (shouldApplyKotlinAndroidPlugin) {
        withGroovyBuilder {
            "kotlinOptions" {
                setProperty("jvmTarget", JavaVersion.VERSION_17.toString())
            }
        }
    }
}
