/// The verbs that open a workbench tab and bring one forward.
///
/// Their own file so that the things which *ask* for a tab — a menu item, a
/// chord, a quick-open row, a chip in the session bar — can reach them without
/// importing `workbench.dart`, which imports several of those widgets back.
/// `workbench.dart` re-exports this, so nothing that already had them had to
/// change its import.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/explorer/application/session_context.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/presentation/session_transcript_view.dart';
import '../../features/settings/application/settings_tab.dart';
import '../../features/settings/presentation/settings_nav.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';


/// Brings [tabId] to the front and makes sure the terminal is what the
/// workbench is showing: picking a tab from a strip or a list is a request to
/// *see* it, and it may well have been picked from the conversation — or from
/// the empty state of a session that is not in any tab at all
/// ([releaseHijackedSelection]).
void activateTerminalTab(WidgetRef ref, String tabId) {
  final terminals = ref.read(terminalSessionsControllerProvider.notifier);
  terminals.activateTab(tabId);
  // The group that holds it, which activating the tab has just focused.
  terminals.showTerminalForTab(tabId);
  releaseHijackedSelection(ref, inGroup: terminals.groupOfTab(tabId));
}

/// Opens Settings as a workbench tab, or brings the one already open forward,
/// landing it on [section] when a caller names one.
///
/// **The one way in**, and the whole of what the menu item, `Ctrl+,`, the
/// title bar's gear, quick open and the usage chip each do. It used to be
/// `SettingsScreen.show`, a `MaterialPageRoute` over the window: it covered
/// the menu bar, the tab strip and — the report — the very panes half of these
/// settings are about, so terminal integration, the session host switch, the
/// Flutter SDK paths and the automations were all set blind. A tab is VS
/// Code's answer and it is ours: it sits beside the thing it configures, it is
/// closed the way anything else is, and it comes back after a restart.
///
/// Asking twice focuses the tab rather than opening a second one — see
/// [TerminalSessionsController.openSettingsTab]. A deep link with no section
/// leaves the page where the user left it, which is what makes the tab worth
/// leaving open.
void openSettingsTab(WidgetRef ref, {SettingsSectionId? section}) {
  if (section != null) {
    ref.read(settingsTabSectionProvider.notifier).select(section);
  }
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openSettingsTab();
  activateTerminalTab(ref, tabId);
}

/// Lets go of a selection that has no pane of ours, because the user has just
/// asked to see one that has.
///
/// `_NoPaneForSession` replaces the **whole** pane stack, which is right while
/// the selection is the only thing anyone has asked for and wrong the moment it
/// is not: a selected session nothing of ours runs held the middle of the
/// window against every live tab in the strip. Activating one moved the tab and
/// changed nothing on screen, and `_showingPanes` — false, because no tab was
/// showing — left every chip drawn inactive. That is the reported "after
/// closing a session with end session on a tab, other tabs are not accessible".
/// The terminal was healthy throughout; only the choice of surface was wrong.
///
/// **Cleared, not out-voted by a second mode.** `null` is the one value the
/// selection listeners in `WorkbenchView` ignore (`if (next != null)`), so this
/// cannot restart the fight where a tap opens a session's terminal and
/// something else undoes it. It is also what keeps the way back open: picking
/// the same row again is now a *change*, so the workbench opens it exactly as
/// it did the first time, empty state and all.
///
/// **Only the selection that is in the way.** One that has a pane is the
/// session the user is looking at, and the toggle to its conversation is
/// offered off the back of it; activating a tab must not quietly drop it.
///
/// **And only in the way of the group it was opened into.** A tab activated in
/// another group is not a statement about this one, and clearing the selection
/// then would empty a group nobody had asked about — the very thing
/// [selectionHostGroupProvider] exists to stop.
void releaseHijackedSelection(WidgetRef ref, {String? inGroup}) {
  final host = ref.read(selectionHostGroupProvider);
  if (inGroup != null && host != null && host != inGroup) return;
  // An imported CLI session has no pane of ours by definition, so it is always
  // the paneless kind.
  if (ref.read(selectedImportedSessionIdProvider) != null) {
    ref.read(selectedImportedSessionIdProvider.notifier).select(null);
  }
  final selected = ref.read(selectedSessionIdProvider);
  if (selected != null && sessionTerminalPane(ref, selected) == null) {
    ref.read(selectedSessionIdProvider.notifier).select(null);
  }
}
