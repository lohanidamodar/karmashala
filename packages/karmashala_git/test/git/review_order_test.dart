import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

/// The order a diff is read in, decided once and applied everywhere.
void main() {
  group('reviewTierOf', () {
    test('an unrecognised path is source, which is read first', () {
      // The default matters more than the table: a file we cannot classify may
      // well be the one the review is about.
      expect(reviewTierOf('lib/main.dart'), ReviewTier.source);
      expect(reviewTierOf('README.md'), ReviewTier.source);
      expect(reviewTierOf('tool/odd-thing'), ReviewTier.source);
    });

    test('the two lockfiles a Flutter app actually carries', () {
      expect(reviewTierOf('pubspec.lock'), ReviewTier.lockfile);
      expect(reviewTierOf('ios/Podfile.lock'), ReviewTier.lockfile);
      // A lockfile is only a lockfile by its whole name.
      expect(reviewTierOf('lib/pubspec.lock.dart'), ReviewTier.source);
    });

    test('generated Dart is named by its suffix, not its directory', () {
      expect(reviewTierOf('lib/models/user.g.dart'), ReviewTier.generated);
      expect(reviewTierOf('lib/models/user.freezed.dart'), ReviewTier.generated);
      expect(reviewTierOf('lib/models/user.dart'), ReviewTier.source);
    });

    test('build output is a segment, at any depth, either slash', () {
      expect(reviewTierOf('build/app/outputs/log.txt'), ReviewTier.buildOutput);
      expect(
        reviewTierOf('packages/pty/build/intermediates/x'),
        ReviewTier.buildOutput,
      );
      expect(reviewTierOf(r'build\app\x'), ReviewTier.buildOutput);
      expect(reviewTierOf('.dart_tool/package_config.json'),
          ReviewTier.buildOutput);
      // A file *called* build is not a directory of build output.
      expect(reviewTierOf('tool/build.dart'), ReviewTier.source);
    });
  });

  group('orderedForReview', () {
    test('tiers it, and never filters it', () {
      const files = [
        'pubspec.lock',
        'lib/models/user.g.dart',
        'build/app/x',
        'lib/main.dart',
        'test/main_test.dart',
      ];

      final ordered = orderedForReview(files, (f) => f);

      expect(ordered, [
        'lib/main.dart',
        'test/main_test.dart',
        'lib/models/user.g.dart',
        'pubspec.lock',
        'build/app/x',
      ]);
      // The whole point of tiering rather than hiding.
      expect(ordered.length, files.length);
      expect(ordered.toSet(), files.toSet());
    });

    test('order inside a tier is the order it arrived in', () {
      const files = ['b.dart', 'a.dart', 'pubspec.lock', 'c.dart'];
      expect(orderedForReview(files, (f) => f), [
        'b.dart',
        'a.dart',
        'c.dart',
        'pubspec.lock',
      ]);
    });

    test('nothing to order is not an error', () {
      expect(orderedForReview(const <String>[], (f) => f), isEmpty);
    });
  });

  group('orderUnifiedDiffForReview', () {
    const diff = '''
diff --git a/pubspec.lock b/pubspec.lock
index 1111111..2222222 100644
--- a/pubspec.lock
+++ b/pubspec.lock
@@ -1 +1 @@
-  version: "1.0.0"
+  version: "1.0.1"
diff --git a/lib/main.dart b/lib/main.dart
index 3333333..4444444 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -1 +1 @@
-void main() {}
+void main() => runApp(App());
''';

    test('the hand-written file comes first, and the lock keeps every line', () {
      final ordered = orderUnifiedDiffForReview(diff);

      expect(
        ordered.indexOf('diff --git a/lib/main.dart b/lib/main.dart'),
        lessThan(ordered.indexOf('diff --git a/pubspec.lock b/pubspec.lock')),
      );
      expect(ordered, contains('+  version: "1.0.1"'));
      expect(ordered, contains('+void main() => runApp(App());'));
      // Reordered, not rewritten: the same lines, and only the order moved.
      expect(
        ordered.split('\n')..sort(),
        diff.split('\n')..sort(),
      );
    });

    test('a diff with one file or none comes back untouched', () {
      expect(orderUnifiedDiffForReview(''), '');
      const single = 'diff --git a/pubspec.lock b/pubspec.lock\n+x\n';
      expect(orderUnifiedDiffForReview(single), single);
      expect(orderUnifiedDiffForReview('not a diff at all'),
          'not a diff at all');
    });

    test('a path with a space in it is read to the end of the header', () {
      const spaced = '''
diff --git a/pubspec.lock b/pubspec.lock
+lock
diff --git a/lib/my file.dart b/lib/my file.dart
+source
''';
      final ordered = orderUnifiedDiffForReview(spaced);
      expect(
        ordered.indexOf('+source'),
        lessThan(ordered.indexOf('+lock')),
      );
    });
  });
}
