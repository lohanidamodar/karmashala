import 'package:karmashala/src/features/git/data/git_diff_parsing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Turning a row of a rendered diff into a line of the file.
///
/// This is the translation the old review comments never did: they stored the
/// row index, which is a fact about a rendering and changes whenever the diff
/// is regenerated. Every number here is a line of the **new** file, which is
/// what an anchor can be checked against.
void main() {
  List<int?> numbersFor(String diff) =>
      newFileLineNumbers(parseUnifiedDiff(diff));

  test('added and context lines are numbered from the hunk header', () {
    const diff = '''
diff --git a/lib/a.dart b/lib/a.dart
index 1111111..2222222 100644
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -8,4 +8,5 @@ class A {
   final int x;
-  int get y => 1;
+  int get y => 2;
+  int get z => 3;
   void go() {}''';
    final lines = parseUnifiedDiff(diff);
    final numbers = newFileLineNumbers(lines);

    // Four headers and one hunk marker carry no line of the file.
    expect(numbers.take(5), everyElement(isNull));
    expect(numbers.sublist(5), [
      8, // ` final int x;`
      null, // `-int get y => 1;` — not in the new file at all
      9, // `+int get y => 2;`
      10, // `+int get z => 3;`
      11, // ` void go() {}`
    ]);
  });

  test('a removed line gets no number rather than its neighbour\'s', () {
    const diff = '@@ -1,3 +1,2 @@\n a\n-b\n c';
    // Handing back 2 — the line that now follows the deletion — would anchor a
    // comment about `b` onto `c`. That is the exact class of silent
    // mis-anchoring this feature exists to remove, so the answer is null and
    // the caller makes it a file-level thread instead.
    expect(numbersFor(diff), [null, 1, null, 2]);
  });

  test('a second hunk restarts from its own header', () {
    const diff = '@@ -1,2 +1,2 @@\n a\n b\n@@ -40,2 +41,2 @@\n x\n+y';
    expect(numbersFor(diff), [null, 1, 2, null, 41, 42]);
  });

  test('git\'s no-newline marker is not a line of the file', () {
    const diff = '@@ -1,2 +1,2 @@\n a\n+b\n\\ No newline at end of file';
    // Counting it would shift every number after it by one, and in a
    // multi-hunk file that is a silent off-by-one in every later anchor.
    expect(numbersFor(diff), [null, 1, 2, null]);
  });

  test('rows before any hunk header are not guessed at', () {
    const diff = 'diff --git a/x b/x\nsomething unparseable\n@@ -1 +1 @@\n a';
    final numbers = numbersFor(diff);
    expect(numbers[0], isNull);
    expect(numbers[1], isNull, reason: 'no header yet means no numbering');
    expect(numbers.last, 1);
  });

  test('a malformed hunk header numbers nothing rather than from zero', () {
    const diff = '@@ this is not a hunk header @@\n a\n+b';
    expect(numbersFor(diff), everyElement(isNull));
  });
}
