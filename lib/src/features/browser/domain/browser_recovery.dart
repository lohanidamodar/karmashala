/// What an agent should *do* about a browser failure, as a token it can branch
/// on rather than a sentence it has to interpret.
///
/// ## Why this is text and not a field
///
/// There is nowhere structured to put it. A tool that throws is rendered by
/// `McpServer._callTool` as one text block, `Error: $error`, with `isError:
/// true` and nothing else — see `mcp_protocol.dart`, and the same two lines in
/// `mcp_bridge/bin/karmashala_mcp.dart`. There is no error `data` field on the
/// way out, and adding one would change a wire format two transports and an
/// external bridge already agree on.
///
/// So the recovery is a trailer on the message, in a shape stable enough to
/// match on: one line, fixed key order, fixed vocabulary. That is a lower
/// ambition than a typed field and a much higher one than what was there
/// before, which was an actionable English sentence for a human and nothing at
/// all for a machine.
///
/// ## Why "retry" is its own axis
///
/// The expensive failure mode with a real browser is not a wrong first move,
/// it is a loop: an agent that re-issues `browser_click(selector: "#go")` after
/// `elementNotFound` will get `elementNotFound` again, forever, because nothing
/// about the page changed between the two calls. "What to do next" and "is
/// doing it again ever going to work" are different questions, and answering
/// only the first is how that loop starts.
library;

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

  /// The specific next call, named as a tool the agent already has. Kept
  /// concrete — "browser_find" beats "look again" — because a generic
  /// suggestion is one an agent has to re-derive.
  final String next;

  /// The trailer, on its own line at the end of the error message.
  ///
  /// Square-bracketed and single-line so it survives being embedded in
  /// `Error: $e` and can be found by a fixed prefix; `|`-separated because none
  /// of the three values ever contains one.
  String get line =>
      '[recovery: ${action.token} | retry: ${retry.token} | next: $next]';

  @override
  String toString() => line;
}

/// The recovery for each way the browser client can fail.
///
/// One entry per [BrowserFailure] and no default arm, so a new failure kind
/// cannot be added without deciding what an agent does about it — the same
/// discipline `describeBrowserFailure` already applies to the human sentence.
BrowserRecovery recoveryFor(BrowserFailure failure) => switch (failure) {
  // Nothing to attach to and nothing an agent can install. The one honest
  // answer is to stop and say what the developer has to do.
  BrowserFailure.chromeNotFound => const BrowserRecovery(
    BrowserRecoveryAction.askUser,
    BrowserRetryAdvice.never,
    'ask the developer to install Chrome or set CHROME_EXECUTABLE',
  ),
  // Someone else owns the port. A different port is an argument change the
  // agent can make on its own, which is why this is not askUser.
  BrowserFailure.portInUse => const BrowserRecovery(
    BrowserRecoveryAction.fixArguments,
    BrowserRetryAdvice.afterRecovery,
    'browser_connect(port: <another port>)',
  ),
  // `spawn: false` was passed, or spawning is off. Connecting again with the
  // default is the whole fix.
  BrowserFailure.notRunning => const BrowserRecovery(
    BrowserRecoveryAction.reconnect,
    BrowserRetryAdvice.afterRecovery,
    'browser_connect() to attach, or browser_navigate(url: …) which connects',
  ),
  // A browser was started and never answered. Often it is a second Chrome on
  // the same profile that took the launch, in which case attaching to what is
  // now listening works where launching again does not.
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
  // The tab we held is gone, so both the connection *and* every selector taken
  // from it are void. Listed as reconnect because that has to happen first.
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
  // A navigation that timed out may still be in flight, and issuing it again is
  // idempotent — the same URL, the same end state.
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
  // The browser rejected the request itself. Re-sending the identical command
  // gets the identical rejection.
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
  // The single most loop-prone failure in this set: the page changed, and the
  // selector an agent is holding came from before it changed.
  BrowserFailure.elementNotFound => const BrowserRecovery(
    BrowserRecoveryAction.resnapshot,
    BrowserRetryAdvice.afterRecovery,
    'browser_find(text: …) for a current selector — the old one is stale',
  ),
  // The developer declined, or walked away. Asking again immediately is worse
  // than useless; it is nagging a person who already answered.
  BrowserFailure.pickCancelled => const BrowserRecovery(
    BrowserRecoveryAction.askUser,
    BrowserRetryAdvice.never,
    'ask the developer what they meant, in words, before picking again',
  ),
  // The browser said something this client cannot parse. That is a defect
  // here, not a mistake the caller made, and a retry hides it.
  BrowserFailure.malformedResponse => const BrowserRecovery(
    BrowserRecoveryAction.stop,
    BrowserRetryAdvice.never,
    'report this to the developer; the CDP reply was not the shape we expect',
  ),
};

/// The recovery for a call this app refused before the browser ever saw it —
/// a missing argument, an unknown key name, an index past the end.
///
/// Its own constant rather than a [BrowserFailure] arm because these never
/// reach the CDP client: they are argument errors, and the only fix is
/// different arguments.
const BrowserRecovery badArgumentsRecovery = BrowserRecovery(
  BrowserRecoveryAction.fixArguments,
  BrowserRetryAdvice.never,
  'correct the arguments and call again',
);

/// The recovery for a tool refused by the consent gate.
///
/// `never` is the important half. A permission an agent does not have is not a
/// transient condition it can wait out, and an agent that retries a denied
/// `browser_evaluate` is burning turns on a decision only a person can make.
const BrowserRecovery consentRequiredRecovery = BrowserRecovery(
  BrowserRecoveryAction.askUser,
  BrowserRetryAdvice.never,
  'ask the developer to grant it in Settings → Tools → Browser, then say what '
      'you will run and why',
);
