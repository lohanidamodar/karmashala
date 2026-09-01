import 'package:karmashala/src/features/fanout/domain/diff_counts.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counting a diff looks trivial and is not: `+++ b/file` starts with `+`,
/// `--- a/file` starts with `-`, and `\ No newline at end of file` starts with
/// neither but sits inside the hunk. Every one of them is a wrong number.
void main() {
  test('an empty diff counts nothing', () {
    expect(parseDiffLineCounts(''), DiffLineCounts.none);
    expect(parseDiffLineCounts('   \n\n'), DiffLineCounts.none);
  });

  test('file headers are not content', () {
    const diff = '''
diff --git a/a.txt b/a.txt
index 111..222 100644
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,2 @@
-gone
+here
''';
    expect(
      parseDiffLineCounts(diff),
      const DiffLineCounts(insertions: 1, deletions: 1),
    );
  });

  test('the no-newline marker is neither an addition nor a deletion', () {
    const diff = '''
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1 +1 @@
-old
\\ No newline at end of file
+new
\\ No newline at end of file
''';
    expect(
      parseDiffLineCounts(diff),
      const DiffLineCounts(insertions: 1, deletions: 1),
    );
  });

  test('several files add up, and each file resets the hunk state', () {
    const diff = '''
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -0,0 +1,2 @@
+one
+two
diff --git a/b.txt b/b.txt
--- a/b.txt
+++ b/b.txt
@@ -1,3 +0,0 @@
-x
-y
-z
''';
    expect(
      parseDiffLineCounts(diff),
      const DiffLineCounts(insertions: 2, deletions: 3),
    );
  });

  test('anything before the first hunk is preamble, not lines', () {
    const diff = '''
diff --git a/a.bin b/a.bin
new file mode 100644
Binary files /dev/null and b/a.bin differ
''';
    expect(parseDiffLineCounts(diff), DiffLineCounts.none);
  });

  test('two counts add', () {
    const a = DiffLineCounts(insertions: 2, deletions: 1);
    const b = DiffLineCounts(insertions: 3, deletions: 0);
    expect(a + b, const DiffLineCounts(insertions: 5, deletions: 1));
  });
}
