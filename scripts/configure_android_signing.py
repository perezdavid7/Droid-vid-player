#!/usr/bin/env python3
"""Configure Flutter's generated Android Gradle script for private release signing.

This script runs ONLY on a GitHub Actions runner after a signing keystore has
been reconstructed from encrypted GitHub Actions secrets. No private key
material is stored in the repository.
"""
from pathlib import Path

gradle = Path("android/app/build.gradle.kts")
content = gradle.read_text(encoding="utf-8")
anchor = '    buildTypes {'
debug = 'signingConfig = signingConfigs.getByName("debug")'
if anchor not in content or debug not in content:
    raise SystemExit("Unsupported Flutter Android Gradle template; inspect before changing signing.")

header = """import java.io.FileInputStream
import java.util.Properties

val releaseKeystoreProperties = Properties()
val releaseKeyPropertiesFile = rootProject.file("key.properties")
if (!releaseKeyPropertiesFile.exists()) {
    error("Signed release requested but android/key.properties is missing")
}
releaseKeystoreProperties.load(FileInputStream(releaseKeyPropertiesFile))

"""
signing = """    signingConfigs {
        create("release") {
            keyAlias = releaseKeystoreProperties.getProperty("keyAlias")
            keyPassword = releaseKeystoreProperties.getProperty("keyPassword")
            storeFile = releaseKeystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = releaseKeystoreProperties.getProperty("storePassword")
        }
    }
"""
content = header + content.replace(anchor, signing + anchor, 1)
content = content.replace(debug, 'signingConfig = signingConfigs.getByName("release")', 1)
gradle.write_text(content, encoding="utf-8")
print("Configured Android release signing from private Actions secrets.")
