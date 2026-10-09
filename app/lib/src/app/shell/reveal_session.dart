/// Where a notification, an alert or "go to the next agent" takes the person:
/// the one decision every one of them asks (owner, 2026-10-09: a session
/// chatted with only in the dashboard's peek opened onto an empty screen).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/notifications/application/notification_providers.dart'
    show focusWatchedSession;
import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'phone_routes.dart';
import 'quick_open/typed_command_runner.dart' show peekOnDashboard;

/// Where [revealSession] took the person.
enum SessionReveal {
  /// Its open tab, brought forward.
  tab,

  /// The Agent dashboard, with the session peeked — on the phone, the
  /// Dashboard tab and its peek page.
  dashboard,

  /// An imported CLI session, selected as before: it has no dashboard card.
  selected,

  /// It is gone — archived or deleted — and the dashboard opened instead.
  gone,
}

/// Shows [openId]: its open tab when this window has one, else the Agent
/// dashboard with it peeked. Never opens a tab of its own, whatever "Resume
/// and start sessions in the background" says — "Open in a tab" in the peek
/// is how a person asks for one. A session that is gone opens the dashboard
/// and says so ([sessionRevealNoticeProvider]).
SessionReveal revealSession(
  ProviderContainer container, {
  required String openId,
  bool imported = false,
}) {
  final read = container.read;
  final phone = read(phoneShellRouterProvider).current;
  if (imported) {
    if (focusWatchedSession(container, openId: openId, imported: true)) {
      // The phone's session page is where an imported session shows.
      if (phone != null) read(phoneWorkbenchProvider.notifier).open();
      return SessionReveal.selected;
    }
    return _gone(container, phone);
  }
  final session = read(sessionsDataProvider).getById(openId);
  if (session == null || session.isArchived) return _gone(container, phone);

  if (phone == null) {
    final terminals = read(terminalSessionsControllerProvider.notifier);
    for (final paneId in read(paneSessionsProvider).panesOf(openId)) {
      final tabId = terminals.tabIdOfPane(paneId);
      if (tabId == null) continue;
      focusWatchedSession(container, openId: openId, imported: false);
      // Selecting the session already selected moves nothing, so the tab is
      // brought forward here too.
      _activate(container, tabId);
      terminals.focusPane(paneId);
      return SessionReveal.tab;
    }
  }
  _openDashboard(container, phone);
  // The explorer still walks to it; selecting the session itself would draw
  // its paneless page over every tab.
  focusWatchedSession(
    container,
    openId: openId,
    imported: false,
    selectSession: false,
  );
  peekOnDashboard(container, openId);
  return SessionReveal.dashboard;
}

SessionReveal _gone(ProviderContainer container, PhoneShellRoutes? phone) {
  container
      .read(sessionRevealNoticeProvider.notifier)
      .say('That session is no longer here — it was archived or deleted.');
  _openDashboard(container, phone);
  return SessionReveal.gone;
}

/// The dashboard: the phone's Dashboard tab, or the desktop's pinned tab.
void _openDashboard(ProviderContainer container, PhoneShellRoutes? phone) {
  if (phone != null) return phone.showDashboard();
  final tabId = container
      .read(terminalSessionsControllerProvider.notifier)
      .openOverviewTab();
  _activate(container, tabId);
}

/// [activateTerminalTab] for a caller holding a container, not a widget.
void _activate(ProviderContainer container, String tabId) {
  container.read(terminalSessionsControllerProvider.notifier)
    ..activateTab(tabId)
    ..revealTab(tabId);
  // A selection with no pane of ours is drawn over every tab, as
  // `releaseHijackedSelection` says; it goes. An imported one never has one.
  if (container.read(selectedImportedSessionIdProvider) != null) {
    container.read(selectedImportedSessionIdProvider.notifier).select(null);
  }
  final selected = container.read(selectedSessionIdProvider);
  if (selected != null &&
      container.read(paneSessionsProvider).paneOf(selected) == null) {
    container.read(selectedSessionIdProvider.notifier).select(null);
  }
}

/// What a reveal has to tell the person — a session that is gone — for the
/// shell, which holds a messenger, to show. A new notice each time, so the
/// same words twice are said twice.
class SessionRevealNotice extends Notifier<({int seq, String message})?> {
  @override
  ({int seq, String message})? build() => null;

  void say(String message) =>
      state = (seq: (state?.seq ?? 0) + 1, message: message);
}

final sessionRevealNoticeProvider =
    NotifierProvider<SessionRevealNotice, ({int seq, String message})?>(
      SessionRevealNotice.new,
    );
