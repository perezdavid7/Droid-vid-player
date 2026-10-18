#!/usr/bin/env python3
"""Configure a generated Flutter Android app for permanent private release signing.

This script runs only after GitHub Actions restores the private keystore and
android/key.properties from encrypted repository secrets. Never commit either.
"""
from pathlib import Path


gradle = Path('android/app/build.gradle.kts')
content = gradle.read_text(encoding='utf-8')

# Kotlin Gradle DSL requires the plugins {} block to precede non-import statements.
# Flutter-generated templates put android {} immediately after plugins {}.
android_anchor = '\nandroid {'
build_types_anchor = '    buildTypes {'
debug_signing = 'signingConfig = signingConfigs.getByName("debug")'
if (
    'plugins {' not in content
    or content.count(android_anchor) != 1
    or content.count(build_types_anchor) != 1
    or content.count(debug_signing) != 1
):
    raise SystemExit(
        'Unrecognized Flutter Gradle template. Stop before modifying release signing.'
    )

imports = 'import java.io.FileInputStream\nimport java.util.Properties\n\n'
properties = '''\nval releaseKeystoreProperties = Properties()
val releaseKeyPropertiesFile = rootProject.file("key.properties")
check(releaseKeyPropertiesFile.exists()) {
    "Signed release requested but android/key.properties is missing"
}
FileInputStream(releaseKeyPropertiesFile).use { stream ->
    releaseKeystoreProperties.load(stream)
}
'''
signing = '''    signingConfigs {
        create("release") {
            keyAlias = releaseKeystoreProperties.getProperty("keyAlias")
            keyPassword = releaseKeystoreProperties.getProperty("keyPassword")
            storeFile = releaseKeystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = releaseKeystoreProperties.getProperty("storePassword")
        }
    }
'''

# Insert property loading immediately before android {}, never above plugins {}.
content = imports + content.replace(android_anchor, '\n' + properties + android_anchor, 1)
content = content.replace(build_types_anchor, signing + build_types_anchor, 1)
content = content.replace(
    debug_signing,
    'signingConfig = signingConfigs.getByName("release")',
    1,
)
gradle.write_text(content, encoding='utf-8')
print('Configured Android release signing after the Gradle plugins block.')
