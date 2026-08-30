import 'package:chitragupta/src/features/git/application/diff_annotations.dart';
import 'package:chitragupta/src/features/git/domain/diff_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds exact, structured feedback for the agent', () {
    final prompt = buildDiffFeedbackPrompt(const [
      DiffAnnotation(
        repositoryId: 'repo',
        path: 'lib/app.dart',
        diffIndex: 12,
        line: DiffLine(DiffLineKind.added, '+final value = 1;'),
        comment: 'Use the configured value.',
      ),
    ]);

    expect(prompt, contains('`lib/app.dart` (diff line 13)'));
    expect(prompt, contains('`+final value = 1;`'));
    expect(prompt, contains('Use the configured value.'));
  });
}
