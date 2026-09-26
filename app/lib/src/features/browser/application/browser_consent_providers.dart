import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../git/application/changes_providers.dart';
import '../../workspaces/data/workspace_data.dart';
import '../../sessions/application/session_providers.dart';
import '../data/preferences_consent_journal.dart';
import 'package:karmashala_browser/browser.dart';

/// The recorded browser-consent grants.
final browserConsentStoreProvider = Provider<BrowserConsentStore>(
  (ref) => BrowserConsentStore(
    PreferencesConsentJournal(ref.watch(appPreferencesProvider)),
  ),
);

/// Bumped whenever a grant is made or taken back, so the settings list
/// redraws: the store reads `app_metadata` per call and holds no state.
final browserConsentRevisionProvider =
    NotifierProvider<BrowserConsentRevision, int>(BrowserConsentRevision.new);

class BrowserConsentRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

/// Which project a browser tool call belongs to: the calling session's own
/// checkout, else the Explorer's. Neither answers, the gate refuses.
({String id, String name})? resolveBrowserConsentScope(
  ProviderContainer container, {
  String? callerSessionId,
}) {
  String? repositoryId;
  if (callerSessionId != null && callerSessionId.isNotEmpty) {
    repositoryId = container
        .read(sessionsDataProvider)
        .getById(callerSessionId)
        ?.repositoryId;
  }
  repositoryId ??= container.read(selectedRepositoryIdProvider);
  if (repositoryId == null || repositoryId.isEmpty) return null;
  final projectId = container
      .read(workspaceDataProvider)
      .repository(repositoryId)
      ?.projectId;
  if (projectId == null || projectId.isEmpty) return null;
  final project = container.read(workspaceDataProvider).project(projectId);
  return (id: projectId, name: project?.name ?? projectId);
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
