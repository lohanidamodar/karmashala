import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

/// The note a session without a project opens with is Karmashala's, not the
/// person's: it can be told apart from what they wrote.
void main() {
  const folder = '/home/u/karmashala/scratch/2026-10-04-tidy-a1b2c3';

  test('the person\'s words come apart from the note ahead of them', () {
    final split = splitScratchPreamble(
      withScratchPreamble(folder, 'Tidy the downloads folder'),
    );
    expect(split.preamble, scratchPreamble(folder));
    expect(split.rest, 'Tidy the downloads folder');
  });

  test('wherever the note sits, and with nothing after it', () {
    final typed = splitScratchPreamble(
      'Please carry out this request: ${withScratchPreamble(folder, 'go')}',
    );
    expect(typed.preamble, scratchPreamble(folder));
    expect(typed.rest, 'Please carry out this request:\n\ngo');

    final alone = splitScratchPreamble(withScratchPreamble(folder, null));
    expect(alone.preamble, isNotNull);
    expect(alone.rest, isEmpty);
  });

  test('a message without the note is left whole', () {
    final split = splitScratchPreamble('This session has no bugs.');
    expect(split.preamble, isNull);
    expect(split.rest, 'This session has no bugs.');
  });
}
