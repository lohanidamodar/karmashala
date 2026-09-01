import 'package:karmashala/src/features/browser/domain/browser_failure.dart';
import 'package:flutter_test/flutter_test.dart';

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
