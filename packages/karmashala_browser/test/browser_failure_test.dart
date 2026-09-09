import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

void main() {
  group('describeBrowserFailure', () {
    test('every failure kind has a message', () {
      for (final failure in BrowserFailure.values) {
        final message = describeBrowserFailure(failure, port: 9222);
        expect(message, isNotEmpty, reason: failure.name);
        expect(message.trim(), message, reason: failure.name);
      }
    });

    test('port failures name the port so the user can act on it', () {
      expect(
        describeBrowserFailure(BrowserFailure.portInUse, port: 9333),
        contains('9333'),
      );
      expect(
        describeBrowserFailure(BrowserFailure.notRunning, port: 9333),
        contains('--remote-debugging-port=9333'),
      );
    });

    test('notRunning names both switches Chrome 136 now requires', () {
      // Since Chrome 136 `--remote-debugging-port` is ignored on the default
      // data directory, so the old remedy — the flag on its own — produces a
      // Chrome that starts fine and never opens the port.
      final message = describeBrowserFailure(
        BrowserFailure.notRunning,
        port: 9222,
      );
      expect(message, contains('--remote-debugging-port=9222'));
      expect(message, contains('--user-data-dir'));
      expect(message, contains('136'));
    });

    test('notRunning does not claim to know why the port is silent', () {
      // We cannot tell "no Chrome is running" from "a Chrome is running on its
      // default profile and ignored the flag": both are a refused connection
      // on 9222. So there is no fifteenth failure kind for the second case,
      // and this message names both rather than picking one.
      final message = describeBrowserFailure(
        BrowserFailure.notRunning,
        port: 9222,
      );
      expect(message, contains('default profile'));
      expect(
        message,
        contains('the same silence'),
        reason: 'the two cases are indistinguishable from here, and say so',
      );
    });

    test('a missing browser tells the user what to install or set', () {
      final message = describeBrowserFailure(BrowserFailure.chromeNotFound);
      expect(message, contains('Chrome'));
      expect(message, contains('CHROME_EXECUTABLE'));
    });

    test('disconnection is described as the browser going away', () {
      expect(
        describeBrowserFailure(BrowserFailure.disconnected),
        contains('closed'),
      );
    });

    test('detail is appended in parentheses', () {
      expect(
        describeBrowserFailure(
          BrowserFailure.elementNotFound,
          detail: 'selector `#nope`',
        ),
        endsWith('(selector `#nope`)'),
      );
    });

    test('an empty detail adds nothing', () {
      expect(
        describeBrowserFailure(BrowserFailure.pickCancelled, detail: ''),
        isNot(contains('(')),
      );
    });

    test('startupFailed explains the profile-takeover case', () {
      expect(
        describeBrowserFailure(BrowserFailure.startupFailed, port: 9222),
        contains('same profile'),
      );
    });
  });

  test('BrowserException carries its failure kind into toString', () {
    const exception = BrowserException(BrowserFailure.timeout, 'took too long');
    expect(exception.toString(), contains('timeout'));
    expect(exception.toString(), contains('took too long'));
  });
}
