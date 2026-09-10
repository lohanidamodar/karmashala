/// The verbs that open a workbench tab and bring one forward.
///
/// Their own file so a menu item, a chord or a quick-open row can reach them
/// without importing `workbench.dart`, which imports those widgets back.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/explorer/application/session_context.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/presentation/session_transcript_view.dart';
import '../../features/settings/application/settings_tab.dart';
import '../../features/settings/presentation/settings_nav.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';


/// Brings [tabId] to the front and makes sure the terminal is what the workbench
/// is showing: picking a tab from a strip or a list is a request to *see* it.
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
/// The one way in. It used to be a route over the window, which covered the very
/// panes half of these settings are about. Asking twice focuses the tab rather
/// than opening a second one.
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
/// `_NoPaneForSession` replaces the *whole* pane stack, so a paneless selection
/// held the middle of the window against every live tab in the strip. Cleared
/// rather than out-voted: `null` is the one value `WorkbenchView`'s listeners
/// ignore, and only the selection in the way of its own host group is dropped.
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
