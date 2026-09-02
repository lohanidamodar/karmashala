import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../git/application/changes_providers.dart';
import '../../projects/application/project_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../data/database_consent_journal.dart';
import '../domain/browser_consent.dart';

/// The recorded browser-consent grants.
final browserConsentStoreProvider = Provider<BrowserConsentStore>(
  (ref) => BrowserConsentStore(
    DatabaseConsentJournal(ref.watch(databaseProvider)),
  ),
);

/// Bumped whenever a grant is made or taken back, so the settings list redraws.
///
/// The store reads straight from `app_metadata` on every call rather than
/// holding state, which is right for a permission check — it can never serve a
/// stale yes — but leaves the UI with nothing to watch.
final browserConsentRevisionProvider =
    NotifierProvider<BrowserConsentRevision, int>(BrowserConsentRevision.new);

class BrowserConsentRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

/// Which project a browser tool call belongs to, and what it is called.
///
/// Resolved in two steps, in this order, because they answer two different
/// questions and only the first one is certain:
///
/// 1. **The calling session's own checkout.** An agent running inside a
///    Karmashala session is working in exactly one project, and the control
///    server already knows which session is calling — this is the answer that
///    cannot be wrong.
/// 2. **The checkout the Explorer is pointed at.** For a caller with no session
///    of its own (an external MCP client on the launcher config, which has no
///    `callerSessionId` at all), this is the only project context that exists.
///    It is what the developer is looking at, which is the same thing they
///    would have in mind when they granted permission.
///
/// When neither answers, the scope is null and the gate refuses. That is the
/// deliberate fail-closed arm: a call with no project is a call whose grant
/// cannot be checked, and "cannot check" must never read as "allowed".
({String id, String name})? resolveBrowserConsentScope(
  ProviderContainer container, {
  String? callerSessionId,
}) {
  String? repositoryId;
  if (callerSessionId != null && callerSessionId.isNotEmpty) {
    repositoryId = container
        .read(sessionDaoProvider)
        .getById(callerSessionId)
        ?.repositoryId;
  }
  repositoryId ??= container.read(selectedRepositoryIdProvider);
  if (repositoryId == null || repositoryId.isEmpty) return null;
  final projectId = container
      .read(repositoryDaoProvider)
      .getById(repositoryId)
      ?.projectId;
  if (projectId == null || projectId.isEmpty) return null;
  final project = container.read(projectDaoProvider).getById(projectId);
  return (id: projectId, name: project?.name ?? projectId);
}

/// The consent check the browser tools run, bound to one caller.
///
/// Built per dispatch rather than held as a provider because the scope depends
/// on `callerSessionId`, which arrives with the request and is not app state.
class ProjectScopedBrowserConsent implements BrowserConsent {
  const ProjectScopedBrowserConsent({
    required this.store,
    required this.scope,
  });

  final BrowserConsentStore store;

  /// Null when no project could be resolved — see
  /// [resolveBrowserConsentScope].
  final ({String id, String name})? scope;

  @override
  BrowserConsentDecision check(BrowserCapability capability) {
    final resolved = scope;
    if (resolved == null) return const DeniedBrowserConsent().check(capability);
    if (store.isGranted(resolved.id, capability)) {
      return const BrowserConsentDecision.allowed();
    }
    // The refusal names the project and the exact place a person goes to say
    // yes, because the agent's next move is to ask a human for something and a
    // request the human cannot act on is worse than no request.
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

/// The consent gate for a caller, or the deny-everything one when no project
/// could be resolved.
BrowserConsent browserConsentFor(
  ProviderContainer container, {
  String? callerSessionId,
}) {
  final scope = resolveBrowserConsentScope(
    container,
    callerSessionId: callerSessionId,
  );
  if (scope == null) return const DeniedBrowserConsent();
  return ProjectScopedBrowserConsent(
    store: container.read(browserConsentStoreProvider),
    scope: scope,
  );
}
