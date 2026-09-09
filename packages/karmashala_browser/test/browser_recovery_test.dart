import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

/// The recovery table, held against the failures it has to answer for.
///
/// The coverage assertion is the load-bearing one: `describeBrowserFailure`
/// already guarantees every failure has a sentence for a person, and this is
/// the same guarantee for the machine reading it.
void main() {
  group('recoveryFor', () {
    test('every failure kind has one', () {
      for (final failure in BrowserFailure.values) {
        final recovery = recoveryFor(failure);
        expect(recovery.next, isNotEmpty, reason: failure.name);
      }
    });

    test('the trailer is one line, in a fixed order', () {
      final line = recoveryFor(BrowserFailure.elementNotFound).line;
      expect(line.split('\n'), hasLength(1));
      expect(
        line,
        startsWith('[recovery: re-snapshot | retry: after-recovery | next: '),
      );
      expect(line, endsWith(']'));
    });

    test('a stale selector is a re-snapshot, never a bare retry', () {
      // The loop this whole file exists to prevent: same selector, same page,
      // same failure, ten times.
      final recovery = recoveryFor(BrowserFailure.elementNotFound);
      expect(recovery.action, BrowserRecoveryAction.resnapshot);
      expect(recovery.retry, BrowserRetryAdvice.afterRecovery);
      expect(recovery.next, contains('browser_find'));
    });

    test('a failure the same arguments will always cause says never', () {
      for (final failure in const [
        BrowserFailure.protocolError,
        BrowserFailure.evaluationFailed,
        BrowserFailure.malformedResponse,
      ]) {
        expect(
          recoveryFor(failure).retry,
          BrowserRetryAdvice.never,
          reason: failure.name,
        );
      }
    });

    test('a busy browser is safe to ask again', () {
      expect(recoveryFor(BrowserFailure.timeout).retry, BrowserRetryAdvice.safe);
      expect(
        recoveryFor(BrowserFailure.navigationTimeout).retry,
        BrowserRetryAdvice.safe,
      );
    });

    test('what only a person can fix is routed to a person', () {
      for (final failure in const [
        BrowserFailure.chromeNotFound,
        BrowserFailure.noTarget,
        BrowserFailure.pickCancelled,
      ]) {
        expect(
          recoveryFor(failure).action,
          BrowserRecoveryAction.askUser,
          reason: failure.name,
        );
      }
    });

    test('a lost tab reconnects and warns that selectors are void', () {
      final recovery = recoveryFor(BrowserFailure.targetGone);
      expect(recovery.action, BrowserRecoveryAction.reconnect);
      expect(recovery.next, contains('stale'));
    });
  });

  test('the tokens are wire values, not enum names', () {
    // `re-snapshot`, `fix-arguments` and `after-recovery` are hyphenated on
    // purpose: they must not track a Dart identifier that anyone is free to
    // rename.
    expect(BrowserRecoveryAction.resnapshot.token, 're-snapshot');
    expect(BrowserRecoveryAction.fixArguments.token, 'fix-arguments');
    expect(BrowserRetryAdvice.afterRecovery.token, 'after-recovery');
  });

  test('a refused consent is permanent until a person acts', () {
    expect(consentRequiredRecovery.action, BrowserRecoveryAction.askUser);
    expect(consentRequiredRecovery.retry, BrowserRetryAdvice.never);
  });
}
