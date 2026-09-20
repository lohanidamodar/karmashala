import 'package:test/test.dart';
import 'package:karmashala_flutter_apps/projects.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

/// A pubspec that reads as a runnable Flutter app.
const String _appPubspec = '''
name: demo_app
environment:
  sdk: ^3.5.0
dependencies:
  flutter:
    sdk: flutter
flutter:
  uses-material-design: true
''';

/// Real Flutter, no entrypoint: a plugin or package.
const String _packagePubspec = '''
name: demo_package
dependencies:
  flutter:
    sdk: flutter
''';

ProjectFileReader _files(Map<String, String> files) =>
    (String path) => files[path];

void main() {
  group('Established', () {
    test('a measured field carries its value and its evidence', () {
      const field = Established<String>.measured('x', evidence: 'ran it');
      expect(field.isMeasured, isTrue);
      expect(field.value, 'x');
      expect(field.evidence, 'ran it');
      expect(field.refusal, isEmpty);
    });

    test(
      'absent and unchecked are different answers, and neither is a value',
      () {
        const absent = Established<String>.absent('Android has none');
        const unchecked = Established<String>.unchecked('needs a Mac');
        expect(absent.state, EstablishedState.absent);
        expect(unchecked.state, EstablishedState.unchecked);
        expect(absent.value, isNull);
        expect(unchecked.value, isNull);
        expect(absent.isMeasured, isFalse);
        expect(unchecked.isMeasured, isFalse);
        // The difference is the point: a known absence is not a blind spot.
        expect(absent.state, isNot(unchecked.state));
        expect(unchecked.refusal, 'needs a Mac');
      },
    );

    test('the state travels in the json, so a reader cannot mistake one', () {
      const unchecked = Established<String>.unchecked('needs a Mac');
      expect(unchecked.toJson()['state'], 'unchecked');
      expect(unchecked.toJson().containsKey('value'), isFalse);
    });
  });

  group('ProjectBuildSpec', () {
    test('the module placeholder is filled from detection', () {
      const spec = ProjectBuildSpec(
        target: ProjectTarget.android,
        tool: ProjectBuildTool.gradleWrapper,
        command: Established<List<String>>.measured(<String>[
          '<module>:assembleDebug',
        ], evidence: 'ran it'),
        artifact: Established<ProjectArtifact>.measured(
          ProjectArtifact(
            directory: '<module>/build/outputs/apk/debug',
            fileName: 'app-debug.apk',
          ),
          evidence: 'saw it',
        ),
        applicationId: Established<ApplicationIdSource>.measured(
          ApplicationIdSource.buildOutputMetadata,
          evidence: 'read it',
        ),
      );
      expect(spec.commandFor(module: 'mobile'), <String>[
        'mobile:assembleDebug',
      ]);
      expect(
        spec.artifactFor(module: 'mobile')!.path,
        'mobile/build/outputs/apk/debug/app-debug.apk',
      );
      // Left alone when there is no module to fill in.
      expect(spec.commandFor(), <String>['<module>:assembleDebug']);
    });

    test('an unchecked command is not runnable and answers with a refusal', () {
      const spec = ProjectBuildSpec(
        target: ProjectTarget.ios,
        tool: ProjectBuildTool.xcodebuild,
        command: Established<List<String>>.unchecked('needs a Mac'),
        artifact: Established<ProjectArtifact>.unchecked('needs a Mac'),
        applicationId: Established<ApplicationIdSource>.unchecked(
          'needs a Mac',
        ),
      );
      expect(spec.isRunnable, isFalse);
      expect(spec.refusal, 'needs a Mac');
      expect(spec.commandFor(module: 'app'), isNull);
      expect(spec.artifactFor(module: 'app'), isNull);
    });
  });

  group('the Flutter descriptor', () {
    final descriptor = descriptorFor(ProjectKind.flutter)!;

    test('its Android build is measured, down to the artifact and the id', () {
      final android = descriptor.buildFor(ProjectTarget.android)!;
      expect(android.isRunnable, isTrue);
      expect(android.commandFor(), <String>['build', 'apk', '--debug']);
      expect(
        android.artifactFor()!.path,
        'build/app/outputs/flutter-apk/app-debug.apk',
      );
      expect(
        android.applicationId.value,
        ApplicationIdSource.buildOutputMetadata,
      );
      // Every measured field says how it was measured.
      expect(android.command.evidence, contains('flutter build apk --debug'));
      expect(android.artifact.evidence, isNotEmpty);
      expect(android.applicationId.evidence, contains('output-metadata.json'));
    });

    test('its iOS build is unchecked, and says so with the reason', () {
      final ios = descriptor.buildFor(ProjectTarget.ios)!;
      expect(ios.isRunnable, isFalse);
      expect(ios.command.state, EstablishedState.unchecked);
      expect(ios.refusal, contains('needs a Mac'));
      expect(ios.refusal, contains('release-build.yml has no macOS job'));
    });

    test('its live channel is the VM service, and it is measured', () {
      expect(descriptor.liveChannel.isMeasured, isTrue);
      expect(descriptor.liveChannel.value, contains('VM service'));
    });

    test('it can build for Android and not for iOS', () {
      expect(descriptor.runnableTargets, <ProjectTarget>[
        ProjectTarget.android,
      ]);
      expect(descriptor.canBuild, isTrue);
    });
  });

  group('detectProject', () {
    test('a Flutter app is the first descriptor, named from its pubspec', () {
      final reading = detectProject(
        directoryName: 'checkout',
        read: _files(<String, String>{'pubspec.yaml': _appPubspec}),
      );
      expect(reading, isNotNull);
      expect(reading!.kind, ProjectKind.flutter);
      expect(reading.name, 'demo_app');
      expect(reading.descriptor, isNotNull);
      expect(reading.evidence, isNotEmpty);
    });

    test('a directory with nothing in it is null, never an empty project', () {
      final reading = detectProject(
        directoryName: 'checkout',
        read: _files(const <String, String>{}),
      );
      expect(reading, isNull);
    });

    test('it reads the pubspec through readPubspec rather than beside it', () {
      // The seam is only real if there is one reading of a pubspec in this
      // app. A package and an app disagree about `isRunnable` and agree about
      // `isFlutter`; both answers have to come from the same place.
      for (final contents in <String>[_appPubspec, _packagePubspec]) {
        final reading = detectProject(
          directoryName: 'checkout',
          read: _files(<String, String>{'pubspec.yaml': contents}),
        );
        expect(reading?.kind, ProjectKind.flutter, reason: contents);
        expect(reading!.name, readPubspec(contents).name);
      }
      // And the package says why it cannot be run, in the words the loop uses.
      final package = detectProject(
        directoryName: 'checkout',
        read: _files(<String, String>{'pubspec.yaml': _packagePubspec}),
      )!;
      expect(package.evidence.join(' '), contains('package or a plugin'));
    });

    test('a pubspec with no Flutter in it is not a Flutter project', () {
      final reading = detectProject(
        directoryName: 'checkout',
        read: _files(<String, String>{
          'pubspec.yaml': 'name: pure_dart\ndependencies:\n  path: ^1.9.0\n',
        }),
      );
      expect(reading, isNull);
    });
  });
}
