import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

/// The guidance a scratch session reads from its folder rather than from its
/// first message.
void main() {
  test('AGENTS.md says what the folder is and how to attach a repository', () {
    final text = kScratchInstructionFiles['AGENTS.md']!;
    expect(text, contains('no project'));
    expect(text, contains('session_checkout_attach'));
    expect(text, contains('project_add'));
    expect(text, isNot(contains('/home/')));
  });

  test('CLAUDE.md is AGENTS.md, imported', () {
    expect(kScratchInstructionFiles['CLAUDE.md']!.trim(), '@AGENTS.md');
  });

  test('an agent is spared the first-message note only when every file it '
      'reads is one the folder holds', () {
    expect(scratchFilesCover(['CLAUDE.md']), isTrue);
    expect(scratchFilesCover(['AGENTS.md']), isTrue);
    expect(scratchFilesCover(['GEMINI.md']), isFalse);
    expect(scratchFilesCover(const []), isFalse);
  });
}
