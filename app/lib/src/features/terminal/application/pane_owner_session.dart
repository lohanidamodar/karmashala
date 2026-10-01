import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../explorer/application/session_context.dart' show sessionInTab;
import 'terminal_sessions_controller.dart';

/// The agent session a pane is **working for** — the one an *Attach to chat* on
/// a document pane (an open file, a preview) hands its file to. Null when the
/// pane's surroundings run no session.
///
/// A document pane runs nothing itself, so the answer is read off where it
/// sits, nearest first:
///
/// 1. **Its own tab.** A document split beside an agent in one tab is that
///    agent's — [sessionInTab]'s rule: the tab's focused pane, then any pane.
/// 2. **Its group's strip, leftward.** A tab opens beside the tab that was
///    active, so the nearest session tab to the left is, by construction, the
///    one the person was working in when they opened the file — and it stays
///    the answer when the strip later gains other sessions further off.
/// 3. **Then rightward**, for a file dragged to the front of a strip.
///
/// A session in **another group** is never the answer: a group is a place the
/// person chose, and reaching across one would hand a file to a session they
/// cannot see beside it. The caller falls back as it sees fit — the focused
/// session, or asking.
///
/// [tabs] is every tab of the window; [groupTabIds] the tab ids of the strip
/// the pane's tab hangs in, in strip order (null when the layout has no group
/// for it, and then the tab stands alone).
String? sessionOwningPaneIn(
  PaneSessions panes, {
  required String paneId,
  required List<TerminalTab> tabs,
  List<String>? groupTabIds,
}) {
  TerminalTab? own;
  final byId = <String, TerminalTab>{};
  for (final tab in tabs) {
    byId[tab.id] = tab;
    if (own == null && tab.layout.panes.contains(paneId)) own = tab;
  }
  if (own == null) return null;
  final mine = sessionInTab(panes, own);
  if (mine != null) return mine;
  final strip = groupTabIds ?? const <String>[];
  final at = strip.indexOf(own.id);
  if (at < 0) return null;
  String? sessionAt(int index) => sessionInTab(panes, byId[strip[index]]);
  for (var i = at - 1; i >= 0; i--) {
    if (sessionAt(i) case final sessionId?) return sessionId;
  }
  for (var i = at + 1; i < strip.length; i++) {
    if (sessionAt(i) case final sessionId?) return sessionId;
  }
  return null;
}

/// [sessionOwningPaneIn] for this window's pane [paneId] — for an editor tab,
/// `editorPaneId(path)`. Rebuilt when tabs, groups or which pane runs what
/// change; read it as a menu opens rather than watching it from a pane.
final sessionOwningPaneProvider = Provider.autoDispose.family<String?, String>((
  ref,
  paneId,
) {
  final (tabs, workspace) = ref.watch(
    terminalSessionsControllerProvider.select((s) => (s.tabs, s.workspace)),
  );
  final panes = ref.watch(paneSessionsProvider);
  String? ownTabId;
  for (final tab in tabs) {
    if (tab.layout.panes.contains(paneId)) {
      ownTabId = tab.id;
      break;
    }
  }
  return sessionOwningPaneIn(
    panes,
    paneId: paneId,
    tabs: tabs,
    groupTabIds: ownTabId == null ? null : workspace?.groupOf(ownTabId)?.panes,
  );
});
