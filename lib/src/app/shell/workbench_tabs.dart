/// The verbs that open a workbench tab and bring one forward. Their own file, so
/// a menu item or a chord need not import `workbench.dart`, which imports back.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_terminal_core/geometry.dart';

import '../../features/explorer/application/session_context.dart';
import '../../features/notes/application/notes_providers.dart';
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

/// Opens Settings as a workbench tab, or brings the open one forward, landing it
/// on [section] — scrolled to [anchor] when one is given. Asking twice focuses
/// that tab rather than opening a second.
void openSettingsTab(
  WidgetRef ref, {
  SettingsSectionId? section,
  SettingsAnchor? anchor,
}) {
  if (anchor != null) {
    ref
        .read(settingsTabSectionProvider.notifier)
        .reveal(SettingsTarget.anchor(anchor));
  } else if (section != null) {
    ref.read(settingsTabSectionProvider.notifier).select(section);
  }
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openSettingsTab();
  activateTerminalTab(ref, tabId);
}

/// Opens note [noteId] in a tab of its own, or brings its open tab forward.
void openNoteTab(WidgetRef ref, String noteId) {
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openDocumentTab(notePaneId(noteId));
  activateTerminalTab(ref, tabId);
}

/// Starts an empty note, filed where the Notes panel is looking, and opens it.
/// A note closed still empty is not kept (see `NoteTabsObserver`).
String writeNewNote(WidgetRef ref) {
  final note = ref
      .read(notesProvider.notifier)
      .capture(
        body: '',
        projectId: ref.read(noteScopeProvider).projectForNewItems,
        inheritProjectFromSource: false,
      );
  openNoteTab(ref, note.id);
  return note.id;
}

/// Lets go of a selection that has no pane of ours: `_NoPaneForSession` replaces
/// the *whole* pane stack, so it held the window against every live tab.
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
