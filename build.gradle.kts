plugins {
    base
    `maven-publish`
}

group = "com.github.piratecash"
version = System.getenv("JITPACK_VERSION")
    ?: System.getenv("VERSION")
    ?: System.getenv("VERSION_NAME")
    ?: gitVersion()

val ldkAar = layout.buildDirectory.file("outputs/aar/LDK-release.aar")
val ldkBaseVersion = "v0.2.0.0"

val buildAndroidAar by tasks.registering(Exec::class) {
    inputs.files(
        "android-build.sh",
        "genbindings.sh",
        "pom.xml",
        "libcode.version",
        "src",
        "scripts/build-android-aar-16k.sh",
        "scripts/check-android-aar-16k.sh"
    )
    inputs.property("version", project.version.toString())
    inputs.property("ldkBaseVersion", ldkBaseVersion)
    outputs.file(ldkAar)

    doFirst {
        ldkAar.get().asFile.parentFile.mkdirs()
    }

    commandLine(
        "bash",
        "-lc",
        """
            set -euo pipefail
            export LDK_GARBAGECOLLECTED_GIT_OVERRIDE="$ldkBaseVersion"
            ./scripts/build-android-aar-16k.sh
            cp LDK-release.aar "${ldkAar.get().asFile.absolutePath}"
        """.trimIndent()
    )
}

val verifyElfAlignment by tasks.registering(Exec::class) {
    dependsOn(buildAndroidAar)
    inputs.file(ldkAar)

    commandLine(
        "bash",
        "-lc",
        "./scripts/check-android-aar-16k.sh \"${ldkAar.get().asFile.absolutePath}\""
    )
}

tasks.assemble {
    dependsOn(verifyElfAlignment)
}

tasks.check {
    dependsOn(verifyElfAlignment)
}

tasks.named("publishToMavenLocal") {
    dependsOn(verifyElfAlignment)
}

publishing {
    publications {
        create<MavenPublication>("release") {
            artifact(ldkAar) {
                builtBy(buildAndroidAar)
                extension = "aar"
            }

            groupId = "com.github.piratecash"
            artifactId = "ldk-garbagecollected"
            version = project.version.toString()

            pom {
                name.set("ldk-garbagecollected")
                description.set("Android AAR packaging for LDK Java bindings with 16 KB ELF alignment")
                url.set("https://github.com/piratecash/ldk-garbagecollected")
                licenses {
                    license {
                        name.set("MIT License")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                    license {
                        name.set("Apache License 2.0")
                        url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                    }
                }
                scm {
                    connection.set("scm:git:https://github.com/piratecash/ldk-garbagecollected.git")
                    developerConnection.set("scm:git:ssh://git@github.com/piratecash/ldk-garbagecollected.git")
                    url.set("https://github.com/piratecash/ldk-garbagecollected")
                }
            }
        }
    }
}

fun gitVersion(): String {
    return try {
        val process = ProcessBuilder("git", "describe", "--tags", "--always")
            .directory(rootDir)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().readText().trim()
        if (process.waitFor() == 0 && output.isNotEmpty()) output else "local"
    } catch (_: Exception) {
        "local"
    }
}
