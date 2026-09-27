import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_terminal_core/profiles.dart' show AgentPaneLaunch;
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../explorer/application/checkout_picker.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../snippets/application/snippet_insertion.dart';
import '../../snippets/application/snippet_providers.dart';
import '../../workspaces/data/workspace_data.dart';
import 'system_terminal_providers.dart';
import 'terminal_sessions_controller.dart';

final _log = AppLogger.named('client-intents');

/// **What the server asks this window to show** (slice 5b; 3d's
/// `HostedRunPanes`, generalised): a tab on a session or a terminal the
/// server runs, a checkout pointed at, a snippet typed into a pane, an
/// imported session opened in a terminal window. The work is the server's;
/// only the showing is this window's. The server tells one window — the one a
/// person last used — so nothing here is done twice. Must be watched.
class ClientIntents extends Notifier<void> {
  @override
  void build() {
    final client = ref.watch(dataClientProvider);
    final intents = client.intents.listen(
      (intent) => unawaited(_handle(intent)),
    );
    ref.onDispose(intents.cancel);
  }

  Future<void> _handle(ClientIntent intent) async {
    try {
      switch (intent) {
        case OpenSessionTab(:final sessionId, :final title, :final launch):
          await _openSession(sessionId, title, launch);
        case OpenTerminalTab(:final paneId, :final title):
          ref
              .read(terminalSessionsControllerProvider.notifier)
              .openHostedRunTab(paneId: paneId, title: title);
        case CloseTerminalTab(:final paneId):
          _closeTab(paneId);
        case SelectCheckout(:final repositoryId):
          final repository = ref
              .read(workspaceDataProvider)
              .repository(repositoryId);
          if (repository != null) {
            ref.read(checkoutPickerProvider).select(repository);
          }
        case InsertSnippet(:final snippetId, :final paneId):
          _insertSnippet(snippetId, paneId);
        case OpenImportedSession(:final importedId):
          await _openImported(importedId);
      }
    } on Object catch (error, stack) {
      // An intent is a request to show something; one that cannot be shown
      // is logged, never thrown into the data channel.
      _log.warning('Could not act on ${intent.runtimeType}.', error, stack);
    }
  }

  Future<void> _openSession(
    String sessionId,
    String title,
    AgentPaneLaunch? launch,
  ) async {
    final launcher = ref.read(sessionLauncherProvider);
    if (launcher.reveal(sessionId)) return;
    final row = ref.read(sessionsDataProvider).getById(sessionId);
    final installation = row == null
        ? null
        : ref
              .read(agentInstallationsDataProvider)
              .getById(row.agentInstallationId);
    final shown =
        launch ??
        (installation == null
            ? null
            : AgentPaneLaunch(
                agentId: installation.agentId,
                executable: installation.executable.path,
                workingDirectory: (row!.workingDirectory ?? row.worktree)?.path,
                sessionId: sessionId,
                title: title,
              ));
    if (row == null || shown == null) return;
    await launcher.showStarted(
      SessionStarted(
        session: row,
        launch: shown,
      ),
    );
  }

  void _closeTab(String paneId) {
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    final state = ref.read(terminalSessionsControllerProvider);
    for (final tab in state.tabs) {
      if (tab.layout.panes.contains(paneId)) {
        controller.closeTab(tab.id);
        return;
      }
    }
  }

  void _insertSnippet(String snippetId, String? paneId) {
    final snippet = ref
        .read(commandSnippetsProvider.notifier)
        .getById(snippetId);
    if (snippet == null) return;
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    final state = ref.read(terminalSessionsControllerProvider);
    final target = paneId == null
        ? resolveSnippetTarget(terminals, state)
        : snippetTargetFor(terminals, state, paneId);
    if (target == null || !snippet.fitsShell(target.shellId)) return;
    insertSnippet(
      terminals: terminals,
      state: state,
      snippet: snippet,
      paneId: target.paneId,
    );
  }

  Future<void> _openImported(String importedId) async {
    final session = ref.read(importedSessionsProvider).getById(importedId);
    if (session == null) return;
    final terminal = await ref.read(defaultSystemTerminalProvider.future);
    if (terminal == null) return;
    await ref
        .read(sessionActionsProvider)
        .openInSystemTerminal(session, terminal);
  }
}

final clientIntentsProvider = NotifierProvider<ClientIntents, void>(
  ClientIntents.new,
);
