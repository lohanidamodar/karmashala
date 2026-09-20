/// What an agent should *do* about a browser failure, as a token it can branch
/// on. There is nowhere structured to put it — a thrown tool is rendered as one
/// `Error: $e` text block with no error `data` field — so it rides as a trailer
/// on the message. Retry is its own axis because "what to do next" and "will
/// doing it again ever work" are different questions, and answering only the
/// first is how an agent loops on `elementNotFound` forever.
library;

import 'browser_consent.dart' show kBrowserConsentLocation;
import 'browser_failure.dart';

/// The next move, from a closed vocabulary.
enum BrowserRecoveryAction {
  /// The connection or the tab is gone. Attach again before anything else.
  reconnect('reconnect'),

  /// The page moved under us. Any selector, index or coordinate obtained
  /// before this call is stale and must be looked up again.
  resnapshot('re-snapshot'),

  /// Nothing is wrong that waiting will not fix: the browser was busy.
  retry('retry'),

  /// The call itself was malformed or asked for something impossible. The same
  /// arguments will fail the same way.
  fixArguments('fix-arguments'),

  /// A person has to do something first — install a browser, open a tab, grant
  /// permission. No sequence of tool calls gets past this.
  askUser('ask-user'),

  /// Give up on this route and say so. Retrying is not just useless, it is
  /// evidence of a bug worth reporting.
  stop('stop');

  const BrowserRecoveryAction(this.token);

  /// The stable string written into the trailer. Deliberately not `name`: the
  /// Dart identifier is free to change, this is a wire value.
  final String token;
}

/// Whether repeating the identical call can ever help.
enum BrowserRetryAdvice {
  /// Safe to repeat as-is.
  safe('safe'),

  /// Only after the [BrowserRecoveryAction] has been carried out.
  afterRecovery('after-recovery'),

  /// Never. The same input produces the same failure.
  never('never');

  const BrowserRetryAdvice(this.token);

  final String token;
}

/// The whole answer to "what now": what to do, whether to retry, and the
/// concrete call to make.
class BrowserRecovery {
  const BrowserRecovery(this.action, this.retry, this.next);

  final BrowserRecoveryAction action;
  final BrowserRetryAdvice retry;

  /// The specific next call, named as a tool the agent already has —
  /// "browser_find" beats "look again", which an agent has to re-derive.
  final String next;

  /// The trailer, on its own line. Square-bracketed and single-line so it
  /// survives `Error: $e`; `|`-separated because no value ever contains one.
  String get line =>
      '[recovery: ${action.token} | retry: ${retry.token} | next: $next]';

  @override
  String toString() => line;
}

/// The recovery for each way the browser client can fail. No default arm, so a
/// new failure cannot be added without deciding what an agent does about it.
BrowserRecovery recoveryFor(BrowserFailure failure) => switch (failure) {
  // Nothing to attach to, and nothing an agent can install.
  BrowserFailure.chromeNotFound => const BrowserRecovery(
    BrowserRecoveryAction.askUser,
    BrowserRetryAdvice.never,
    'ask the developer to install Chrome or set CHROME_EXECUTABLE',
  ),
  // A different port is an argument change the agent can make, so not askUser.
  BrowserFailure.portInUse => const BrowserRecovery(
    BrowserRecoveryAction.fixArguments,
    BrowserRetryAdvice.afterRecovery,
    'browser_connect(port: <another port>)',
  ),
  BrowserFailure.notRunning => const BrowserRecovery(
    BrowserRecoveryAction.reconnect,
    BrowserRetryAdvice.afterRecovery,
    'browser_connect() to attach, or browser_navigate(url: …) which connects',
  ),
  // Often a second Chrome on the same profile took the launch, in which case
  // attaching to what is now listening works where launching again does not.
  BrowserFailure.startupFailed => const BrowserRecovery(
    BrowserRecoveryAction.reconnect,
    BrowserRetryAdvice.afterRecovery,
    'browser_connect(spawn: false) to attach to whatever did start',
  ),
  BrowserFailure.disconnected => const BrowserRecovery(
    BrowserRecoveryAction.reconnect,
    BrowserRetryAdvice.afterRecovery,
    'browser_connect() — the previous session is gone',
  ),
  // Both the connection and every selector taken from the old tab are void.
  BrowserFailure.targetGone => const BrowserRecovery(
    BrowserRecoveryAction.reconnect,
    BrowserRetryAdvice.afterRecovery,
    'browser_tabs() then browser_tabs(select: "<id>"); selectors are stale',
  ),
  BrowserFailure.noTarget => const BrowserRecovery(
    BrowserRecoveryAction.askUser,
    BrowserRetryAdvice.afterRecovery,
    'ask the developer to open a tab, then browser_tabs()',
  ),
  // The navigation may still be in flight, and re-issuing it is idempotent.
  BrowserFailure.navigationTimeout => const BrowserRecovery(
    BrowserRecoveryAction.retry,
    BrowserRetryAdvice.safe,
    'browser_screenshot() to see what is blocking, then browser_navigate again',
  ),
  BrowserFailure.timeout => const BrowserRecovery(
    BrowserRecoveryAction.retry,
    BrowserRetryAdvice.safe,
    'retry once; if it times out again, browser_screenshot() for a dialog',
  ),
  BrowserFailure.protocolError => const BrowserRecovery(
    BrowserRecoveryAction.fixArguments,
    BrowserRetryAdvice.never,
    'change the arguments; the browser refused this exact request',
  ),
  BrowserFailure.evaluationFailed => const BrowserRecovery(
    BrowserRecoveryAction.fixArguments,
    BrowserRetryAdvice.never,
    'fix the expression; the page threw on it',
  ),
  // The most loop-prone failure here: the selector predates the page's change.
  BrowserFailure.elementNotFound => const BrowserRecovery(
    BrowserRecoveryAction.resnapshot,
    BrowserRetryAdvice.afterRecovery,
    'browser_find(text: …) for a current selector — the old one is stale',
  ),
  // Asking again immediately is nagging a person who already answered.
  BrowserFailure.pickCancelled => const BrowserRecovery(
    BrowserRecoveryAction.askUser,
    BrowserRetryAdvice.never,
    'ask the developer what they meant, in words, before picking again',
  ),
  // A defect here, not a mistake the caller made, and a retry hides it.
  BrowserFailure.malformedResponse => const BrowserRecovery(
    BrowserRecoveryAction.stop,
    BrowserRetryAdvice.never,
    'report this to the developer; the CDP reply was not the shape we expect',
  ),
};

/// The recovery for a call this app refused before the browser saw it. Its own
/// constant rather than a [BrowserFailure] arm: these never reach the CDP
/// client, and the only fix is different arguments.
const BrowserRecovery badArgumentsRecovery = BrowserRecovery(
  BrowserRecoveryAction.fixArguments,
  BrowserRetryAdvice.never,
  'correct the arguments and call again',
);

/// The recovery for a tool refused by the consent gate. `never` is the important
/// half: a permission is not a transient condition an agent can wait out.
const BrowserRecovery consentRequiredRecovery = BrowserRecovery(
  BrowserRecoveryAction.askUser,
  BrowserRetryAdvice.never,
  'ask the developer to grant it in $kBrowserConsentLocation, then say '
  'what you will run and why',
);
