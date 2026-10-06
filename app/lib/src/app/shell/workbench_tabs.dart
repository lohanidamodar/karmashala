/// The verbs that open a workbench tab and bring one forward. Their own file, so
/// a menu item or a chord need not import `workbench.dart`, which imports back.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_device_pane/providers.dart' show AndroidDevice;
import 'package:karmashala_terminal_core/geometry.dart';

import '../../features/agents/presentation/usage_tab/usage_tab_state.dart';
import '../../features/explorer/application/session_context.dart';
import '../../features/notes/application/notes_providers.dart';
import '../../features/running/application/running_providers.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/presentation/session_transcript_view.dart';
import '../../features/settings/application/settings_tab.dart';
import '../../features/settings/presentation/settings_nav.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'logs_tab_view.dart' show LogSource, logsTabSourceProvider;
import 'phone_routes.dart';

/// Brings [tabId] to the front and makes sure the terminal is what the workbench
/// is showing: picking a tab from a strip or a list is a request to *see* it.
void activateTerminalTab(WidgetRef ref, String tabId) {
  final terminals = ref.read(terminalSessionsControllerProvider.notifier);
  terminals.activateTab(tabId);
  // The group that holds it, which activating the tab has just focused.
  terminals.showTerminalForTab(tabId);
  releaseHijackedSelection(ref, inGroup: terminals.groupOfTab(tabId));
}

/// Opens [device]'s live preview as a workbench tab, or brings forward the
/// one already open: one tab per device, so a second click is not a second
/// stream of the same phone. A new one opens **on the side** — beside the
/// work, in the group other previews are in — so the phone is watched next
/// to what drives it, not instead of it (owner, 2026-10-01).
void openDevicePreviewTab(WidgetRef ref, AndroidDevice device) {
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openDocumentBeside(
        devicePreviewPaneId(device.serial),
        sharesGroup: isDevicePreviewPane,
      );
  activateTerminalTab(ref, tabId);
}

/// Opens the file browser on [leftEnvironmentId] and [rightEnvironmentId], or
/// brings forward the one already open on that pair. The two machines and the
/// two starting folders are the tab's id, so a restore reopens it where it was.
void openFilesTab(
  WidgetRef ref, {
  required String leftEnvironmentId,
  required String rightEnvironmentId,
  String leftPath = '',
  String rightPath = '',
}) {
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openDocumentTab(
        filesPaneId(
          leftEnvironmentId: leftEnvironmentId,
          rightEnvironmentId: rightEnvironmentId,
          leftPath: leftPath,
          rightPath: rightPath,
        ),
      );
  activateTerminalTab(ref, tabId);
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
  // The phone shows no workbench tabs: its More tab has the same page.
  final phone = ref.read(phoneShellRouterProvider).current;
  if (phone != null) {
    phone.showMore(PhoneMoreEntry.settings);
    return;
  }
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openSettingsTab();
  activateTerminalTab(ref, tabId);
}

/// Opens the Usage page as a workbench tab (spec §5), or brings the open one
/// forward. Its own tab rather than a Settings page: it is read, not set.
/// [accountId] ([usageAccountId]) lands it on that account — an account
/// card's "Usage details" asks about the account it shows.
void openUsageTab(WidgetRef ref, {String? accountId}) {
  if (accountId != null) {
    ref.read(usageTabSelectionProvider.notifier).selectAccount(accountId);
  }
  final phone = ref.read(phoneShellRouterProvider).current;
  if (phone != null) {
    phone.showMore(PhoneMoreEntry.usage);
    return;
  }
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openUsageTab();
  activateTerminalTab(ref, tabId);
}

/// Opens the Stores page as a workbench tab, or brings the open one forward.
void openStoresTab(WidgetRef ref) {
  final phone = ref.read(phoneShellRouterProvider).current;
  if (phone != null) {
    phone.showMore(PhoneMoreEntry.stores);
    return;
  }
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openStoresTab();
  activateTerminalTab(ref, tabId);
}

/// Opens the Logs tab, or brings it forward; [source] picks the log it shows.
void openLogsTab(WidgetRef ref, {LogSource? source}) {
  if (source != null) ref.read(logsTabSourceProvider.notifier).show(source);
  // The phone keeps its own Log page under More, built for copying out.
  final phone = ref.read(phoneShellRouterProvider).current;
  if (phone != null) {
    phone.showMore(PhoneMoreEntry.log);
    return;
  }
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openLogsTab();
  activateTerminalTab(ref, tabId);
}

/// Opens the Overview tab, or brings it forward. The phone has it under More.
void openOverviewTab(WidgetRef ref) {
  final phone = ref.read(phoneShellRouterProvider).current;
  if (phone != null) {
    phone.showMore(PhoneMoreEntry.overview);
    return;
  }
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openOverviewTab();
  activateTerminalTab(ref, tabId);
}

/// Opens the Running tab, or brings it forward. [sessionId] shows only that
/// session's processes; without it, the tab shows everything.
void openRunningTab(WidgetRef ref, {String? sessionId}) {
  ref.read(runningFilterProvider.notifier).session(sessionId);
  final phone = ref.read(phoneShellRouterProvider).current;
  if (phone != null) {
    phone.showMore(PhoneMoreEntry.running);
    return;
  }
  final tabId = ref
      .read(terminalSessionsControllerProvider.notifier)
      .openRunningTab();
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
