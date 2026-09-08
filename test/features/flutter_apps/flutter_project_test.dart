import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/flutter_apps/domain/flutter_project.dart';
import 'package:path/path.dart' as p;

const String _app = '''
name: karmashala
description: "An app"
publish_to: 'none'

environment:
  sdk: ^3.12.2

dependencies:
  flutter:
    sdk: flutter
  path: ^1.9.1

flutter:
  uses-material-design: true
  assets:
    - assets/images/
''';

const String _package = '''
name: my_plugin

dependencies:
  flutter:
    sdk: flutter
''';

const String _pureDart = '''
name: relay
dependencies:
  shelf: ^1.4.0
''';

void main() {
  group('readPubspec', () {
    test('an app carries both signals and is runnable', () {
      final reading = readPubspec(_app);
      expect(reading.name, 'karmashala');
      expect(reading.evidence, {
        FlutterEvidence.flutterSection,
        FlutterEvidence.sdkDependency,
      });
      expect(reading.isFlutter, isTrue);
      expect(reading.isRunnable, isTrue);
    });

    test('a package depends on the SDK and is not runnable', () {
      final reading = readPubspec(_package);
      expect(reading.evidence, {FlutterEvidence.sdkDependency});
      expect(reading.isFlutter, isTrue);
      expect(reading.isRunnable, isFalse);
    });

    test('a pure Dart package is not a Flutter project', () {
      final reading = readPubspec(_pureDart);
      expect(reading.name, 'relay');
      expect(reading.evidence, isEmpty);
      expect(reading.isFlutter, isFalse);
    });

    test('a package merely named flutter is not the SDK', () {
      final reading = readPubspec('''
name: impostor
dependencies:
  flutter: ^1.0.0
''');
      expect(reading.evidence, isEmpty);
    });

    test('dev_dependencies count — flutter_test pulls the SDK in', () {
      final reading = readPubspec('''
name: tested
dev_dependencies:
  flutter:
    sdk: flutter
''');
      expect(reading.evidence, {FlutterEvidence.sdkDependency});
    });

    test('a comment is not a section', () {
      final reading = readPubspec('''
name: commented
# flutter:
dependencies:
  meta: ^1.0.0
''');
      expect(reading.evidence, isEmpty);
    });

    test('an indented flutter: outside a dependency block proves nothing', () {
      final reading = readPubspec('''
name: nested
workspace:
  flutter:
    sdk: flutter
''');
      expect(reading.evidence, isEmpty);
    });

    test('a quoted name is read without its quotes', () {
      expect(readPubspec('name: "quoted"\nflutter:\n').name, 'quoted');
    });

    test('an empty file is not a Flutter project and does not throw', () {
      final reading = readPubspec('');
      expect(reading.name, isNull);
      expect(reading.isFlutter, isFalse);
    });
  });

  group('flutterProjectDepth', () {
    test('the root itself is zero, not one', () {
      expect(
        flutterProjectDepth(
          root: '/src/repo',
          directory: '/src/repo',
          context: p.posix,
        ),
        0,
      );
    });

    test('one and two directories down', () {
      expect(
        flutterProjectDepth(
          root: '/src/repo',
          directory: '/src/repo/app',
          context: p.posix,
        ),
        1,
      );
      expect(
        flutterProjectDepth(
          root: '/src/repo',
          directory: '/src/repo/packages/mobile',
          context: p.posix,
        ),
        2,
      );
    });

    test('outside the root is null, never zero', () {
      expect(
        flutterProjectDepth(
          root: '/src/repo',
          directory: '/src/other',
          context: p.posix,
        ),
        isNull,
      );
    });

    test('a Windows path is measured with a Windows ruler', () {
      expect(
        flutterProjectDepth(
          root: r'C:\src\repo',
          directory: r'C:\src\repo\packages\app',
          context: p.windows,
        ),
        2,
      );
    });
  });

  group('flutterProjectsIn', () {
    List<FlutterProject> find(
      List<PubspecCandidate> candidates, {
      String root = '/src/repo',
      int maxDepth = kFlutterProjectMaxDepth,
    }) => flutterProjectsIn(
      root: root,
      candidates: candidates,
      context: p.posix,
      maxDepth: maxDepth,
    );

    test('the root project is found and named from its pubspec', () {
      final found = find([(path: '/src/repo/pubspec.yaml', contents: _app)]);
      expect(found, hasLength(1));
      expect(found.single.name, 'karmashala');
      expect(found.single.directory, '/src/repo');
      expect(found.single.depth, 0);
      expect(found.single.isRunnable, isTrue);
    });

    test('a pure Dart pubspec is not returned at all', () {
      expect(find([(path: '/src/repo/pubspec.yaml', contents: _pureDart)]), isEmpty);
    });

    test('shallowest first, then by name', () {
      final found = find([
        (path: '/src/repo/packages/zulu/pubspec.yaml', contents: _package),
        (path: '/src/repo/packages/alpha/pubspec.yaml', contents: _package),
        (path: '/src/repo/pubspec.yaml', contents: _app),
      ]);
      expect(
        found.map((project) => project.name).toList(),
        ['karmashala', 'my_plugin', 'my_plugin'],
      );
      expect(found.first.depth, 0);
      expect(
        found.map((project) => project.directory).skip(1).toList(),
        ['/src/repo/packages/alpha', '/src/repo/packages/zulu'],
      );
    });

    test('three directories down is past the bound and is dropped', () {
      final found = find([
        (
          path: '/src/repo/packages/a/example/pubspec.yaml',
          contents: _app,
        ),
      ]);
      expect(found, isEmpty);
    });

    test('a pubspec outside the root is dropped rather than measured as zero', () {
      expect(find([(path: '/src/other/pubspec.yaml', contents: _app)]), isEmpty);
    });

    test('the bound is a parameter, so a caller can widen it deliberately', () {
      final found = find(
        [(path: '/src/repo/a/b/c/pubspec.yaml', contents: _app)],
        maxDepth: 3,
      );
      expect(found, hasLength(1));
      expect(found.single.depth, 3);
    });

    test('a pubspec with no name falls back to its directory', () {
      final found = find([
        (path: '/src/repo/app/pubspec.yaml', contents: 'flutter:\n'),
      ]);
      expect(found.single.name, 'app');
    });

    test('a package is reported and marked not runnable', () {
      final found = find([
        (path: '/src/repo/pubspec.yaml', contents: _package),
      ]);
      expect(found.single.isRunnable, isFalse);
      expect(found.single.toJson()['runnable'], isFalse);
    });
  });
}
