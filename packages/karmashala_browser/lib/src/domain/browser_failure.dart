/// Why a browser operation failed: callers react to the kind, not to a string.
/// The paired message on [BrowserException] is written for a human in the UI.
enum BrowserFailure {
  /// No Chromium-family browser executable could be located.
  chromeNotFound,

  /// The debugging port is occupied by something that is not a DevTools
  /// endpoint.
  portInUse,

  /// Nothing is listening on the debugging port and we were told not to spawn.
  /// Also a Chrome 136+ that ignored `--remote-debugging-port` because it is on
  /// the default data directory: both are a refused connection, indistinguishable.
  notRunning,

  /// A browser was spawned but never opened its debugging endpoint.
  startupFailed,

  /// The browser (or the tab) went away while we were talking to it.
  disconnected,

  /// The target we were attached to is gone: closed, crashed, or detached.
  targetGone,

  /// The browser is running but exposes no page we can drive.
  noTarget,

  /// A navigation was issued but the page never reached its load event.
  navigationTimeout,

  /// A CDP command was sent but no reply arrived in time.
  timeout,

  /// The browser replied with a protocol-level error.
  protocolError,

  /// Injected JavaScript threw.
  evaluationFailed,

  /// A selector matched nothing.
  elementNotFound,

  /// The user pressed Escape (or otherwise abandoned) while picking.
  pickCancelled,

  /// A reply was received but was not shaped the way the protocol promises.
  malformedResponse,
}

/// The single exception type raised by everything under `features/browser`.
/// [message] is user-facing and must stay actionable; [cause] is for logs.
class BrowserException implements Exception {
  const BrowserException(this.failure, this.message, {this.cause});

  final BrowserFailure failure;
  final String message;
  final Object? cause;

  @override
  String toString() => 'BrowserException(${failure.name}): $message';
}

/// Standard, actionable wording for each failure kind. A pure function, so the
/// phrasing is testable and identical wherever a failure is raised.
String describeBrowserFailure(
  BrowserFailure failure, {
  String? detail,
  int? port,
}) {
  final suffix = detail == null || detail.isEmpty ? '' : ' ($detail)';
  return switch (failure) {
    BrowserFailure.chromeNotFound =>
      'No Chrome or Edge installation was found. Install Google Chrome, or '
          'set CHROME_EXECUTABLE to the browser you want to drive.$suffix',
    BrowserFailure.portInUse =>
      'Port ${port ?? 0} is in use by something that is not a Chrome DevTools '
          'endpoint. Close whatever owns the port, or pick another one.$suffix',
    BrowserFailure.notRunning =>
      'Nothing is listening on port ${port ?? 0}. Since Chrome 136 that is '
          'also what a Chrome started with the flag on its default profile '
          'looks like — the switch is ignored there and the port never opens '
          '— and from here the two are the same silence. Start Chrome with '
          '--remote-debugging-port=${port ?? 0} *and* a --user-data-dir of '
          'its own, run Chrome for Testing, or let Karmashala launch its own '
          'on a throwaway profile.$suffix',
    BrowserFailure.startupFailed =>
      'Chrome was launched but never opened its debugging port '
          '(${port ?? 0}). It may have exited immediately, or another Chrome '
          'using the same profile took over the launch.$suffix',
    BrowserFailure.disconnected =>
      'The browser disconnected. It was closed, crashed, or the debugging '
          'session was ended from the browser side.$suffix',
    BrowserFailure.targetGone =>
      'The page went away: the tab was closed, crashed, or navigated '
          'somewhere else while the operation was running.$suffix',
    BrowserFailure.noTarget =>
      'The browser is running but has no page to drive. Open a tab and try '
          'again.$suffix',
    BrowserFailure.navigationTimeout =>
      'The page never finished loading. It may be waiting on a slow request, '
          'or blocked behind a dialog.$suffix',
    BrowserFailure.timeout =>
      'The browser did not answer in time. It may be busy, paused in the '
          'debugger, or showing a modal dialog.$suffix',
    BrowserFailure.protocolError => 'The browser rejected the request.$suffix',
    BrowserFailure.evaluationFailed =>
      'JavaScript running in the page threw an error.$suffix',
    BrowserFailure.elementNotFound =>
      'No element in the page matched that selector.$suffix',
    BrowserFailure.pickCancelled => 'Element picking was cancelled.$suffix',
    BrowserFailure.malformedResponse =>
      'The browser sent a reply this client could not read.$suffix',
  };
}
