import 'browser_consent.dart';

/// The consent check the browser tools run, bound to one caller. Built per
/// dispatch because the scope depends on the calling session, which arrives with
/// the request and is not app state.
class ProjectScopedBrowserConsent implements BrowserConsent {
  const ProjectScopedBrowserConsent({required this.store, required this.scope});

  final BrowserConsentStore store;

  /// Null when the caller could not be placed in a project — the fail-closed
  /// arm: "cannot check" must never read as "allowed".
  final ({String id, String name})? scope;

  @override
  BrowserConsentDecision check(BrowserCapability capability) {
    final resolved = scope;
    if (resolved == null) return const DeniedBrowserConsent().check(capability);
    if (store.isGranted(resolved.id, capability)) {
      return const BrowserConsentDecision.allowed();
    }
    // The refusal names the project and where to say yes: the agent's next move
    // is to ask a human, and a request they cannot act on is worse than none.
    return BrowserConsentDecision.denied(
      'Not permitted: running JavaScript in the attached page has not been '
      'granted for the project "${resolved.name}". This is a one-time consent, '
      'not a per-call prompt — ask the developer to turn on "Run JavaScript in '
      'the page" for "${resolved.name}" under Settings → Tools → Browser, and '
      'they can take it back in the same place. Until then, use browser_find, '
      'browser_capture and browser_screenshot, which need no grant.',
    );
  }
}
