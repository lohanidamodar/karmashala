import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/app_projects/domain/apk_output_metadata.dart';
import 'package:karmashala/src/features/app_projects/domain/built_in_projects.dart';
import 'package:karmashala/src/features/app_projects/domain/established.dart';
import 'package:karmashala/src/features/app_projects/domain/gradle_project.dart';
import 'package:karmashala/src/features/app_projects/domain/project_descriptor.dart';
import 'package:karmashala/src/features/app_projects/domain/project_detection.dart';
import 'package:karmashala/src/features/app_projects/domain/project_kind.dart';

/// The probe's own settings script, which built successfully on 2026-09-09.
const String _probeSettings = '''
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.application") version "9.0.1" apply false
}

rootProject.name = "nativeprobe"

include(":app")
''';

/// The probe's own app module.
const String _probeAppModule = '''
plugins {
    id("com.android.application")
}

android {
    namespace = "com.popupbits.nativeprobe"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.popupbits.nativeprobe"
        minSdk = 24
    }
}
''';

/// What an Android Studio template writes instead: Groovy, and a version
/// catalog rather than a literal plugin id.
const String _groovySettings = '''
include ':app', ':wear'
rootProject.name = "Legacy"
''';

const String _catalogModule = '''
plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace 'com.example.legacy'
    defaultConfig {
        applicationId "com.example.legacy"
    }
}
''';

const String _catalog = '''
[versions]
agp = "8.7.0"

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
''';

/// A library module: real AGP, and nothing to install on a phone.
const String _libraryModule = '''
plugins {
    id("com.android.library")
}
''';

/// This repository's own android/settings.gradle.kts, verbatim.
const String _flutterHostSettings = r'''
pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
}

include(":app")
''';

/// And its app module, which carries every native marker there is.
const String _flutterHostModule = '''
plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.popupbits.karmashala"
    defaultConfig {
        applicationId = "com.popupbits.karmashala"
    }
}
''';

/// AGP's own record, copied from the probe's build.
const String _probeMetadata = '''
{
  "version": 3,
  "artifactType": {"type": "APK", "kind": "Directory"},
  "applicationId": "com.popupbits.nativeprobe",
  "variantName": "debug",
  "elements": [
    {"type": "SINGLE", "filters": [], "attributes": [],
     "versionCode": 1, "versionName": "1.0", "outputFile": "app-debug.apk"}
  ],
  "elementType": "File",
  "minSdkVersionForDexing": 24
}
''';

ProjectFileReader _files(Map<String, String> files) =>
    (String path) => files[path];

void main() {
  group('reading a Gradle build', () {
    test('the modules a settings script includes, both spellings', () {
      expect(gradleIncludedModules(_probeSettings), <String>[':app']);
      expect(gradleIncludedModules(_groovySettings), <String>[':app', ':wear']);
      expect(gradleRootProjectName(_probeSettings), 'nativeprobe');
      expect(gradleRootProjectName(_groovySettings), 'Legacy');
      expect(gradleRootProjectName('include(":app")'), isNull);
    });

    test('a module that applies com.android.application, by literal id', () {
      final reading = readGradleModule(_probeAppModule);
      expect(reading.appliesAndroidApplication(), isTrue);
      expect(reading.applicationId, 'com.popupbits.nativeprobe');
      expect(reading.namespace, 'com.popupbits.nativeprobe');
      expect(reading.isFlutterHostModule, isFalse);
    });

    test('and by version-catalog alias, which is what a template writes', () {
      final reading = readGradleModule(_catalogModule);
      // Without the catalog the alias means nothing and is not guessed at.
      expect(reading.appliesAndroidApplication(), isFalse);
      expect(
        reading.appliesAndroidApplication(
          catalog: gradlePluginCatalog(_catalog),
        ),
        isTrue,
      );
      // Groovy's no-equals spelling reads the same as Kotlin's.
      expect(reading.applicationId, 'com.example.legacy');
      expect(reading.namespace, 'com.example.legacy');
    });

    test(
      'the catalog maps a dashed key onto the accessor Gradle generates',
      () {
        final catalog = gradlePluginCatalog(_catalog);
        expect(catalog['android.application'], 'com.android.application');
        expect(catalog['kotlin.android'], 'org.jetbrains.kotlin.android');
        expect(gradlePluginCatalog('[versions]\nagp = "8.7.0"\n'), isEmpty);
      },
    );

    test('a library is not an application', () {
      expect(
        readGradleModule(_libraryModule).appliesAndroidApplication(),
        isFalse,
      );
    });

    test('a Flutter host settings script is recognised as one', () {
      expect(gradleSettingsIsFlutterHost(_flutterHostSettings), isTrue);
      expect(gradleSettingsIsFlutterHost(_probeSettings), isFalse);
      expect(readGradleModule(_flutterHostModule).isFlutterHostModule, isTrue);
    });
  });

  group("AGP's own output-metadata.json", () {
    test('carries the application id and the file name the build wrote', () {
      final metadata = readApkOutputMetadata(_probeMetadata)!;
      expect(metadata.applicationId, 'com.popupbits.nativeprobe');
      expect(metadata.variantName, 'debug');
      expect(metadata.outputFile, 'app-debug.apk');
    });

    test('anything it does not say is null, never an empty id', () {
      expect(readApkOutputMetadata('not json'), isNull);
      expect(readApkOutputMetadata('{}'), isNull);
      expect(
        readApkOutputMetadata('{"applicationId": "x", "elements": []}'),
        isNull,
      );
    });
  });

  group('detecting a native Android project', () {
    test('a Gradle build with an application module, named and moduled', () {
      final reading = detectProject(
        directoryName: 'checkout',
        read: _files(<String, String>{
          'settings.gradle.kts': _probeSettings,
          'app/build.gradle.kts': _probeAppModule,
        }),
      )!;
      expect(reading.kind, ProjectKind.nativeAndroid);
      expect(reading.name, 'nativeprobe');
      expect(reading.androidModule, ':app');
      expect(reading.androidModuleDirectory, 'app');
      expect(reading.evidence.join(' '), contains('com.android.application'));
    });

    test('a Groovy build behind a version catalog is found the same way', () {
      final reading = detectProject(
        directoryName: 'checkout',
        read: _files(<String, String>{
          'settings.gradle': _groovySettings,
          'gradle/libs.versions.toml': _catalog,
          'app/build.gradle': _catalogModule,
        }),
      )!;
      expect(reading.kind, ProjectKind.nativeAndroid);
      expect(reading.androidModule, ':app');
    });

    test('a settings script with only libraries in it is not a project', () {
      expect(
        detectProject(
          directoryName: 'checkout',
          read: _files(<String, String>{
            'settings.gradle.kts': _probeSettings,
            'app/build.gradle.kts': _libraryModule,
          }),
        ),
        isNull,
      );
    });

    test(
      "this repository's own android/ is a Flutter host module, and is refused "
      'by name',
      () {
        final files = <String, String>{
          'settings.gradle.kts': _flutterHostSettings,
          'app/build.gradle.kts': _flutterHostModule,
        };
        expect(
          detectProject(directoryName: 'android', read: _files(files)),
          isNull,
          reason: 'it carries every native marker and belongs to Flutter',
        );
        final note = notAProjectNote(read: _files(files))!;
        expect(note, contains('Android half of a Flutter project'));
        expect(note, contains('one directory up'));
      },
    );

    test('a pubspec above it is a second, independent signal', () {
      // A host module whose settings script has been rewritten and no longer
      // names Flutter is still not ours to build.
      final files = <String, String>{
        'settings.gradle.kts': _probeSettings,
        'app/build.gradle.kts': _probeAppModule,
        '../pubspec.yaml':
            'name: app\nflutter:\n  uses-material-design: true\n',
      };
      expect(
        detectProject(directoryName: 'android', read: _files(files)),
        isNull,
      );
      expect(notAProjectNote(read: _files(files)), isNotNull);
    });

    test('a pubspec beside it means Flutter answered first', () {
      final reading = detectProject(
        directoryName: 'checkout',
        read: _files(<String, String>{
          'pubspec.yaml': 'name: app\nflutter:\n  uses-material-design: true\n',
          'settings.gradle.kts': _probeSettings,
          'app/build.gradle.kts': _probeAppModule,
        }),
      )!;
      expect(reading.kind, ProjectKind.flutter);
    });

    test('the files detection reads are a bounded handful', () {
      expect(kProjectRootFiles, contains('settings.gradle.kts'));
      expect(kProjectRootFiles, contains('../pubspec.yaml'));
      expect(kProjectRootFiles.length, lessThan(10));
      expect(
        gradleModuleScriptPaths(<String>[':app', ':wear:mobile']),
        <String>[
          'app/build.gradle.kts',
          'app/build.gradle',
          'wear/mobile/build.gradle.kts',
          'wear/mobile/build.gradle',
        ],
      );
    });
  });

  group('the native Android descriptor', () {
    final descriptor = descriptorFor(ProjectKind.nativeAndroid)!;

    test('its build is the project wrapper and the module it detected', () {
      final android = descriptor.buildFor(ProjectTarget.android)!;
      expect(android.tool, ProjectBuildTool.gradleWrapper);
      // Two spellings of one module, and mixing them is the obvious bug: a
      // Gradle *task* path keeps the leading colon, a *directory* drops it.
      expect(android.commandFor(module: ':app'), <String>[
        ':app:assembleDebug',
      ]);
      expect(
        android.artifactFor(module: 'app')!.path,
        'app/build/outputs/apk/debug/app-debug.apk',
      );
      expect(
        android.applicationId.value,
        ApplicationIdSource.buildOutputMetadata,
      );
      expect(android.command.evidence, contains('BUILD SUCCESSFUL'));
      expect(android.applicationId.evidence, contains('aapt dump badging'));
    });

    test('its live channel is absent, not unchecked', () {
      // The difference §19 turns on: Android has none, which is a fact about
      // Android rather than a gap in what we looked at.
      expect(descriptor.liveChannel.state, EstablishedState.absent);
      expect(descriptor.liveChannel.reason, contains('logcat'));
    });

    test('it has no iOS row at all, rather than an unchecked one', () {
      expect(descriptor.buildFor(ProjectTarget.ios), isNull);
      expect(descriptor.runnableTargets, <ProjectTarget>[
        ProjectTarget.android,
      ]);
    });
  });
}
