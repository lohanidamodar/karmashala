import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/app_projects/domain/built_in_projects.dart';
import 'package:karmashala/src/features/app_projects/domain/established.dart';
import 'package:karmashala/src/features/app_projects/domain/project_descriptor.dart';
import 'package:karmashala/src/features/app_projects/domain/project_detection.dart';
import 'package:karmashala/src/features/app_projects/domain/project_kind.dart';

ProjectFileReader _files(Map<String, String> files) =>
    (String path) => files[path];

ProjectEntryLister _entries(Map<String, List<String>> entries) =>
    (String path) => entries[path] ?? const <String>[];

void main() {
  group('detecting native iOS', () {
    test('an Xcode project names its first shared scheme', () {
      final reading = detectProject(
        directoryName: 'checkout',
        read: _files(const <String, String>{}),
        list: _entries(<String, List<String>>{
          '': <String>['MyApp.xcodeproj', 'MyApp.xcworkspace', 'MyApp'],
          'MyApp.xcodeproj/xcshareddata/xcschemes': <String>[
            'MyApp.xcscheme',
            'Alpha.xcscheme',
          ],
        }),
      )!;
      expect(reading.kind, ProjectKind.nativeIos);
      expect(reading.name, 'MyApp');
      // Sorted, so "the first shared scheme" is the same answer every time.
      expect(reading.iosScheme, 'Alpha');
      expect(reading.evidence.join(' '), contains('shared schemes'));
    });

    test('no shared scheme is still a project, and says what is missing', () {
      final reading = detectProject(
        directoryName: 'checkout',
        read: _files(const <String, String>{}),
        list: _entries(<String, List<String>>{
          '': <String>['MyApp.xcodeproj'],
        }),
      )!;
      expect(reading.kind, ProjectKind.nativeIos);
      expect(reading.iosScheme, isNull);
      expect(reading.evidence.join(' '), contains('xcodebuild -scheme'));
    });

    test("a Flutter checkout's ios/ is refused, twice over", () {
      // `Flutter/` beside the project…
      expect(
        detectProject(
          directoryName: 'ios',
          read: _files(const <String, String>{}),
          list: _entries(<String, List<String>>{
            '': <String>['Flutter', 'Runner.xcodeproj', 'Runner.xcworkspace'],
          }),
        ),
        isNull,
      );
      // …and, independently, a pubspec above it.
      expect(
        detectProject(
          directoryName: 'ios',
          read: _files(<String, String>{
            '../pubspec.yaml':
                'name: app\nflutter:\n  uses-material-design: true\n',
          }),
          list: _entries(<String, List<String>>{
            '': <String>['Runner.xcodeproj'],
          }),
        ),
        isNull,
      );
    });

    test('with no listing there is no answer, rather than a guessed one', () {
      expect(
        detectProject(
          directoryName: 'checkout',
          read: _files(const <String, String>{}),
        ),
        isNull,
      );
    });
  });

  group('the native iOS descriptor', () {
    final descriptor = descriptorFor(ProjectKind.nativeIos)!;

    test('it is written out in full and every field refuses', () {
      final ios = descriptor.buildFor(ProjectTarget.ios)!;
      expect(descriptor.canBuild, isFalse);
      expect(ios.isRunnable, isFalse);
      expect(ios.commandFor(), isNull);
      for (final field in <Established<Object>>[
        ios.command,
        ios.artifact,
        ios.applicationId,
      ]) {
        expect(field.state, EstablishedState.unchecked);
        expect(field.reason, contains('needs a Mac'));
        expect(field.reason, contains('release-build.yml has no macOS job'));
        // The shape is readable, and it is not in `value` where anything
        // could run it.
        expect(field.sketch, isNotEmpty);
        expect(field.value, isNull);
      }
      expect(ios.command.sketch, contains('xcodebuild -scheme'));
      expect(ios.artifact.sketch, contains('Debug-iphonesimulator'));
      expect(ios.applicationId.sketch, contains('CFBundleIdentifier'));
      expect(ios.applicationId.sketch, contains('simctl'));
    });

    test('and it has no Android row it never had', () {
      expect(descriptor.buildFor(ProjectTarget.android), isNull);
    });
  });
}
