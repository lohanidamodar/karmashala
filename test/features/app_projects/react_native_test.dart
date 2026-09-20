import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/app_projects/domain/built_in_projects.dart';
import 'package:karmashala/src/features/app_projects/domain/established.dart';
import 'package:karmashala/src/features/app_projects/domain/package_json.dart';
import 'package:karmashala/src/features/app_projects/domain/project_descriptor.dart';
import 'package:karmashala/src/features/app_projects/domain/project_detection.dart';
import 'package:karmashala/src/features/app_projects/domain/project_kind.dart';

ProjectFileReader _files(Map<String, String> files) =>
    (String path) => files[path];

const String _rnPackage = '''
{
  "name": "AwesomeProject",
  "dependencies": {"react": "19.0.0", "react-native": "0.79.2"},
  "devDependencies": {"jest": "29.7.0"}
}
''';

const String _expoPackage = '''
{"name": "managed", "dependencies": {"expo": "~52.0.0", "react-native": "0.76.5"}}
''';

const String _plainPackage = '''
{"name": "landing", "devDependencies": {"vite": "6.0.0", "svelte": "5.0.0"}}
''';

void main() {
  group('reading a package.json', () {
    test('react-native and expo are separate evidence, not one boolean', () {
      final bare = readPackageJson(_rnPackage);
      expect(bare.name, 'AwesomeProject');
      expect(bare.isReactNative, isTrue);
      expect(bare.evidence, contains(ReactNativeEvidence.reactNative));
      expect(bare.evidence, isNot(contains(ReactNativeEvidence.expo)));

      final managed = readPackageJson(_expoPackage);
      expect(managed.evidence, contains(ReactNativeEvidence.expo));
    });

    test('a SvelteKit landing site is not React Native', () {
      // The shape of every package.json actually on this machine.
      expect(readPackageJson(_plainPackage).isReactNative, isFalse);
    });

    test('a file it cannot parse is not a project, never a half-read one', () {
      expect(readPackageJson('not json').isReactNative, isFalse);
      expect(readPackageJson('[]').name, isNull);
    });
  });

  group('detecting React Native', () {
    test('it is asked before native Android, which it would answer to', () {
      final reading = detectProject(
        directoryName: 'checkout',
        read: _files(<String, String>{
          'package.json': _rnPackage,
          // A React Native project carries exactly this.
          'settings.gradle': "include ':app'\n",
          'app/build.gradle': "plugins { id 'com.android.application' }\n",
        }),
      )!;
      expect(reading.kind, ProjectKind.reactNative);
      expect(reading.name, 'AwesomeProject');
      expect(reading.evidence.join(' '), contains('reactNative'));
    });
  });

  group('the React Native descriptor', () {
    final descriptor = descriptorFor(ProjectKind.reactNative)!;

    test('every field refuses, with the count that was actually taken', () {
      expect(descriptor.canBuild, isFalse);
      final android = descriptor.buildFor(ProjectTarget.android)!;
      expect(android.command.state, EstablishedState.unchecked);
      expect(
        android.refusal,
        contains(
          'no React Native or Expo project on '
          'this machine',
        ),
      );
      expect(android.refusal, contains('six package.json files'));
      expect(android.command.sketch, contains('expo run:android'));
    });

    test('its live channel is unchecked, not absent — Metro exists', () {
      // The difference §19 turns on, the other way round from native Android:
      // there IS a live channel here and nobody has spoken it.
      expect(descriptor.liveChannel.state, EstablishedState.unchecked);
      expect(descriptor.liveChannel.reason, contains('Hermes'));
    });
  });
}
