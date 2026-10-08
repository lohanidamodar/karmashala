import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart' show ExplorerRowKind;

import '../../explorer/application/workspace_session_entry.dart';
import '../../explorer/presentation/explorer_selection_actions.dart'
    show selectRowAction;
import '../../explorer/presentation/session_row_menu.dart';
import '../../terminal/application/system_terminal_providers.dart';

/// The session menu for [entry] — [sessionMenuItems] for one Karmashala
/// runs, the imported conversation's verbs for one it does not — with
/// [extras], this place's own verbs, as the first group.
List<PopupMenuEntry<String>> overviewSessionMenuItems(
  WidgetRef ref,
  WorkspaceSessionEntry entry, {
  List<PopupMenuEntry<String>> extras = const [],
}) {
  final terminals = _terminals(ref);
  if (entry.native case final native?) {
    return sessionMenuItems(ref, native, terminals: terminals, extras: extras);
  }
  final imported = entry.imported;
  if (imported == null) return extras;
  // The sidebar's own verbs — its Pin, sections, Select — are not this
  // place's.
  const sidebars = {'pin', 'sections', selectRowAction};
  final shared = [
    for (final item in importedSessionMenuItems(
      pinned: false,
      hasSections: false,
      terminals: terminals,
    ))
      if (item is! PopupMenuItem<String> || !sidebars.contains(item.value))
        item,
  ];
  return [
    ...extras,
    if (extras.isNotEmpty && shared.isNotEmpty) const DesktopMenuDivider(),
    ...shared.skipWhile((item) => item is PopupMenuDivider),
  ];
}

/// Opens [entry]'s session menu from [anchor] — at [at] for a right-click —
/// and runs what is picked. [onExtra] answers this place's own verbs first,
/// returning whether it did.
Future<void> showOverviewSessionMenu(
  BuildContext anchor,
  WidgetRef ref,
  WorkspaceSessionEntry entry, {
  List<PopupMenuEntry<String>> extras = const [],
  Future<bool> Function(String value)? onExtra,
  Offset? at,
}) async {
  final items = overviewSessionMenuItems(ref, entry, extras: extras);
  if (items.isEmpty) return;
  final picked = await showSessionMenu(
    anchor,
    ExplorerRowKind.session.menuLabel,
    items,
    at: at,
  );
  if (picked == null || !anchor.mounted) return;
  if (onExtra != null && await onExtra(picked)) return;
  if (!anchor.mounted) return;
  await runOverviewSessionMenuAction(anchor, ref, entry, picked);
}

/// Runs [action], a shared verb from [overviewSessionMenuItems].
Future<void> runOverviewSessionMenuAction(
  BuildContext context,
  WidgetRef ref,
  WorkspaceSessionEntry entry,
  String action,
) async {
  final terminals = _terminals(ref);
  if (entry.native case final native?) {
    await runNativeSessionMenuAction(
      context,
      ref,
      native,
      action,
      terminals: terminals,
    );
  } else if (entry.imported case final imported?) {
    await runImportedSessionMenuAction(
      context,
      ref,
      imported,
      action,
      terminals: terminals,
    );
  }
}

List<SystemTerminal> _terminals(WidgetRef ref) =>
    ref.read(availableSystemTerminalsProvider).asData?.value ?? const [];
