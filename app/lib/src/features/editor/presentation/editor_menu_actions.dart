import '../../workspaces/data/workspace_data.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:path/path.dart' as p;

import '../../../app/shell/side_panel_state.dart';
import '../../explorer/application/session_context.dart';
import '../../file_explorer/application/file_explorer_providers.dart';
import '../../git/application/changes_providers.dart';
import '../../notes/application/composer_draft.dart';
import '../../notes/application/notes_providers.dart';
import '../../notes/presentation/note_edit_dialog.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';

/// The app's entries on the editor's context menu, beside the editor's own.
abstract final class EditorMenuValues {
  static const copyPath = 'file.copy-path';
  static const copyRelativePath = 'file.copy-relative-path';
  static const copyPathLine = 'file.copy-path-line';
  static const revealInFiles = 'file.reveal-in-files';
  static const openExternally = 'file.open-external';
  static const openFolder = 'file.open-folder';
  static const selectionToNote = 'selection.note';
  static const selectionToSession = 'selection.session';
}

/// A file tab's entries. Pure, so what a state offers is testable without a
/// tab. [relativeRoot] is the Files panel's root when the file is under it —
/// the one place a relative path and a reveal in that panel mean anything.
/// [onThisMachine] is false for a file on an SSH host: no local editor or
/// file manager can open it.
List<PopupMenuEntry<String>> editorFileMenuItems({
  required EnvironmentPath? relativeRoot,
  bool onThisMachine = true,
}) => [
  DesktopMenuItem(
    value: EditorMenuValues.copyPath,
    label: 'Copy path',
    icon: AppIcons.copySimple,
  ),
  DesktopMenuItem(
    value: EditorMenuValues.copyRelativePath,
    label: 'Copy relative path',
    icon: AppIcons.copySimple,
    enabled: relativeRoot != null,
  ),
  DesktopMenuItem(
    value: EditorMenuValues.copyPathLine,
    label: 'Copy path:line',
    icon: AppIcons.copySimple,
  ),
  const DesktopMenuDivider(),
  DesktopMenuItem(
    value: EditorMenuValues.revealInFiles,
    label: 'Reveal in Files panel',
    icon: AppIcons.treeStructure,
    enabled: relativeRoot != null,
  ),
  DesktopMenuItem(
    value: EditorMenuValues.openExternally,
    label: 'Open in external editor',
    icon: AppIcons.arrowSquareOut,
    enabled: onThisMachine,
  ),
  DesktopMenuItem(
    value: EditorMenuValues.openFolder,
    label: 'Open containing folder',
    icon: AppIcons.folderOpen,
    enabled: onThisMachine,
  ),
];

/// What can be made of a selection. Absent rather than disabled without one,
/// like the terminal's captures; Notes off hides its entry, and no session to
/// send to disables that one, because opening a session makes it work.
List<PopupMenuEntry<String>> editorSelectionMenuItems({
  required bool hasSelection,
  required bool notesEnabled,
  required bool offerNote,
  required bool hasSession,
}) => [
  if (hasSelection) ...[
    if (offerNote && notesEnabled)
      DesktopMenuItem(
        value: EditorMenuValues.selectionToNote,
        label: 'Create note from selection',
        icon: AppIcons.notePencil,
      ),
    DesktopMenuItem(
      value: EditorMenuValues.selectionToSession,
      label: 'Send selection to session',
      icon: AppIcons.paperPlaneRight,
      enabled: hasSession,
    ),
  ],
];

/// The Files panel's root when [path] is under it, else null.
EnvironmentPath? filesPanelRootFor(WidgetRef ref, EnvironmentPath path) {
  final root = ref.read(fileTreeRootProvider);
  return root != null && isUnderFileTreeRoot(root, path) ? root : null;
}

/// [path] relative to [root], in the separators [root] is written with.
String relativeFilePath(EnvironmentPath root, EnvironmentPath path) {
  final context = root.path.contains(r'\') ? p.windows : p.posix;
  return context.relative(path.path, from: root.path);
}

void _say(BuildContext context, String message) => ScaffoldMessenger.maybeOf(
  context,
)?.showSnackBar(SnackBar(content: Text(message)));

Future<void> copyToClipboard(
  BuildContext context,
  String text,
  String what,
) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) _say(context, '$what copied to clipboard');
}

/// Selects [path] in the Files panel and brings the panel up.
void revealInFilesPanel(WidgetRef ref, EnvironmentPath path) {
  ref
      .read(fileRevealTargetProvider.notifier)
      .reveal(FileRevealTarget(path: path, isDirectory: false));
  if (ref.read(sidePanelProvider) != SidePanelSurface.files) {
    ref.read(sidePanelProvider.notifier).select(SidePanelSurface.files);
  }
}

/// Keeps [text] as a note through the same dialog a terminal capture uses,
/// filed under the Files panel's repository when [path] is inside it.
Future<void> captureSelectionAsNote(
  BuildContext context,
  WidgetRef ref, {
  required String text,
  EnvironmentPath? path,
}) async {
  final underRoot = path != null && filesPanelRootFor(ref, path) != null;
  final repositoryId = underRoot
      ? ref.read(selectedRepositoryIdProvider)
      : null;
  final note = await showCapturedNoteDialog(
    context,
    ref,
    body: text,
    projectId: repositoryId == null
        ? null
        : ref.read(workspaceDataProvider).repository(repositoryId)?.projectId,
    sourceRepositoryId: repositoryId,
  );
  if (note != null && context.mounted) _say(context, 'Saved to Notes.');
}

/// Offers [text] to the focused session the way a note is sent back: typed at
/// its prompt or queued for its composer, never submitted.
void sendSelectionToSession(BuildContext context, WidgetRef ref, String text) {
  final sessionId = ref.read(focusedSessionIdProvider);
  if (sessionId == null) {
    _say(context, 'No session to send this to — open one first.');
    return;
  }
  final title =
      ref.read(sessionsDataProvider).getById(sessionId)?.title ?? 'the session';
  final outcome = offerToSession(ref, sessionId: sessionId, text: text);
  ref.read(selectedSessionIdProvider.notifier).select(sessionId);
  _say(context, sessionOfferMessage(outcome, title));
}

/// Whether there is a session to send a selection to, read as the menu opens.
bool hasSessionToOffer(WidgetRef ref) =>
    ref.read(focusedSessionIdProvider) != null;

/// Whether Notes is on, read as the menu opens.
bool notesAreEnabled(WidgetRef ref) => ref.read(notesEnabledProvider);
