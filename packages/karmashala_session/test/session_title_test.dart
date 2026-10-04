import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

/// Who names a new session: a title a person typed is theirs, so no agent
/// title replaces it; blank or a placeholder leaves it to the machine.
void main() {
  test('a title a person typed is theirs, trimmed', () {
    final named = newSessionTitle('  phone 1c ', typed: true);
    expect(named.title, 'phone 1c');
    expect(named.byUser, isTrue);
  });

  test('blank becomes "Session", and the agent may still name it', () {
    for (final typed in [true, false]) {
      final named = newSessionTitle('   ', typed: typed);
      expect(named.title, kUnnamedSessionTitle);
      expect(named.byUser, isFalse);
    }
  });

  test('a placeholder left in the dialog is nobody\'s name', () {
    for (final placeholder in kAppGeneratedSessionTitles) {
      expect(newSessionTitle(placeholder, typed: true).byUser, isFalse);
      expect(isPlaceholderSessionTitle(' $placeholder '), isTrue);
    }
  });

  test('a title a program gave (an automation\'s name) is not a person\'s', () {
    final named = newSessionTitle('Nightly review', typed: false);
    expect(named.title, 'Nightly review');
    expect(named.byUser, isFalse);
  });

  test('a message names a session by its first line', () {
    expect(sessionTitleFromMessage('# Fix the cart\n\nMore'), 'Fix the cart');
    expect(sessionTitleFromMessage('\n\n  make   it fast  '), 'make it fast');
    final long = sessionTitleFromMessage('word ' * 40);
    expect(long.length, lessThanOrEqualTo(61));
    expect(long, endsWith('…'));
    expect(sessionTitleFromMessage('   '), kUnnamedSessionTitle);
  });
}
