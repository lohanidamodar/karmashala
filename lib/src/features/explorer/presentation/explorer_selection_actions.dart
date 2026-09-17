import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';

import '../../projects/application/project_providers.dart';
import '../../workspaces/application/workspaces_controller.dart';
import '../../workspaces/presentation/new_context_dialog.dart';
import '../application/bulk_session_delete.dart';
import '../application/explorer_tree_nodes.dart';
import '../application/explorer_tree_provider.dart';
import '../application/session_selection.dart';
import 'bulk_delete_dialog.dart';
import 'explorer_project_row.dart';
import 'session_rows.dart';

/// The ids of [kind]'s rows in the order the tree draws them — what a
/// Shift-click ranges over and Ctrl+A selects.
List<String> selectableOrder(List<ExplorerNode> nodes, SelectionKind kind) => [
  for (final node in nodes)
    ?switch ((kind, node)) {
      (SelectionKind.projects, final ProjectNode node) => node.project.id,
      (SelectionKind.sessions, final SessionRowNode node) => node.session.id,
      (SelectionKind.sessions, final ImportedRowNode node) => node.session.id,
      _ => null,
    },
];

/// What a click on a selectable row means, given the keys held: Shift ranges
/// from the anchor, Cmd or Ctrl toggles (entering the mode), and a plain click
/// in the mode ticks. Answers whether the click was spent here; when not, the
/// row does its ordinary thing. A project the selection cannot take still
/// folds, so sessions stay reachable; a session it cannot take does nothing.
bool handleSelectableClick(
  WidgetRef ref, {
  required String id,
  required SelectionKind kind,
}) {
  final keys = HardwareKeyboard.instance;
  final controller = ref.read(sessionSelectionProvider.notifier);
  if (keys.isShiftPressed) {
    controller.extendTo(
      id,
      kind: kind,
      order: selectableOrder(ref.read(explorerTreeProvider).nodes, kind),
    );
    return true;
  }
  if (keys.isMetaPressed || keys.isControlPressed) {
    controller.toggle(id, kind: kind);
    return true;
  }
  final selection = ref.read(sessionSelectionProvider);
  if (!selection.active) return false;
  if (selection.canTick(kind)) {
    controller.toggle(id, kind: kind);
    return true;
  }
  return kind == SelectionKind.sessions;
}

/// The kind of the Explorer row holding keyboard focus, if any.
SelectionKind? focusedRowKind() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  SelectionKind? kind;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is ExplorerProjectRow) {
      kind = SelectionKind.projects;
    } else if (widget is NativeSessionRow || widget is ImportedSessionRow) {
      kind = SelectionKind.sessions;
    }
    return kind == null;
  });
  return kind;
}

/// Ticks every visible row of [kind] — the focused row's kind, else the kind
/// the selection already holds. Answers whether anything was selected.
bool selectAllVisible(WidgetRef ref, [SelectionKind? kind]) {
  final chosen =
      kind ?? focusedRowKind() ?? ref.read(sessionSelectionProvider).kind;
  if (chosen == null) return false;
  return ref
      .read(sessionSelectionProvider.notifier)
      .selectAll(
        selectableOrder(ref.read(explorerTreeProvider).nodes, chosen),
        chosen,
      );
}

/// The bulk verbs over the selection, as menu entries and as their effect.
/// Built by the bar and by a ticked row's right-click, which offer the same
/// verbs on the same set.
class ExplorerSelectionVerbs {
  ExplorerSelectionVerbs(this.ref, this.context);

  final WidgetRef ref;
  final BuildContext context;

  static const _move = 'selection:move:';
  static const newContext = 'selection:new-context';
  static const remove = 'selection:remove';
  static const delete = 'selection:delete';
  static const selectAll = 'selection:all';
  static const done = 'selection:done';

  static bool owns(String value) => value.startsWith('selection:');

  SessionSelection get _selection => ref.read(sessionSelectionProvider);

  /// A ticked row's right-click: every verb, named with the count it acts on.
  List<PopupMenuEntry<String>> rowMenu() {
    final selection = _selection;
    final kind = selection.kind ?? SelectionKind.sessions;
    final many = kind.count(selection.count);
    return [
      if (kind == SelectionKind.projects) ...[
        for (final workspace in ref.read(workspacesControllerProvider))
          DesktopMenuItem(
            value: '$_move${workspace.id}',
            label: 'Move $many to ${workspace.name}',
            icon: AppIcons.folder,
          ),
        DesktopMenuItem(
          value: newContext,
          label: 'Move $many to a new context…',
          icon: AppIcons.folderPlus,
        ),
        DesktopMenuItem(
          value: remove,
          label: 'Remove $many from their context',
          icon: AppIcons.minusCircle,
        ),
      ] else
        DesktopMenuItem(
          value: delete,
          label: 'Delete $many…',
          icon: AppIcons.trash,
          destructive: true,
        ),
      const DesktopMenuDivider(),
      ..._tail(),
    ];
  }

  /// The bar's own menu: the verbs without the count the bar already shows.
  List<PopupMenuEntry<String>> barMenu() {
    final kind = _selection.kind;
    final some = _selection.count > 0;
    return [
      if (kind == SelectionKind.projects)
        ...moveMenu(prefix: 'Move to ')
      else if (some)
        DesktopMenuItem(
          value: delete,
          label: 'Delete…',
          icon: AppIcons.trash,
          destructive: true,
        ),
      if (kind == SelectionKind.projects)
        DesktopMenuItem(
          value: remove,
          label: 'Remove from context',
          icon: AppIcons.minusCircle,
        ),
      if (some) const DesktopMenuDivider(),
      ..._tail(),
    ];
  }

  /// The contexts to move the selection to, and a new one.
  List<PopupMenuEntry<String>> moveMenu({String prefix = ''}) => [
    for (final workspace in ref.read(workspacesControllerProvider))
      DesktopMenuItem(
        value: '$_move${workspace.id}',
        label: '$prefix${workspace.name}',
        icon: AppIcons.folder,
      ),
    DesktopMenuItem(
      value: newContext,
      label: prefix.isEmpty ? 'New context…' : '${prefix}a new context…',
      icon: AppIcons.folderPlus,
    ),
  ];

  List<PopupMenuEntry<String>> _tail() => [
    DesktopMenuItem(
      value: selectAll,
      label: 'Select all',
      icon: AppIcons.check,
      shortcut: defaultTargetPlatform == TargetPlatform.macOS ? '⌘A' : 'Ctrl+A',
    ),
    DesktopMenuItem(value: done, label: 'Done selecting', icon: AppIcons.x),
  ];

  Future<void> run(String value) async {
    if (value.startsWith(_move)) {
      final id = value.substring(_move.length);
      final name = ref
          .read(workspacesControllerProvider)
          .where((w) => w.id == id)
          .map((w) => w.name)
          .firstOrNull;
      if (name != null) _file(id, name);
      return;
    }
    switch (value) {
      case newContext:
        await _fileIntoNewContext();
      case remove:
        _file(null, null);
      case delete:
        await _delete();
      case selectAll:
        selectAllVisible(ref, _selection.kind ?? SelectionKind.sessions);
      case done:
        ref.read(sessionSelectionProvider.notifier).leave();
    }
  }

  /// Everything the move and its undo need, read before anything can await.
  ({
    List<String> ids,
    Map<String, String?> previous,
    WorkspacesController contexts,
    SessionSelectionController selection,
    ScaffoldMessengerState? messenger,
  })
  _capture() {
    final projects = ref.read(projectDaoProvider);
    final ids = [
      for (final id in _selection.ids)
        if (projects.getById(id) != null) id,
    ];
    return (
      ids: ids,
      previous: {for (final id in ids) id: projects.getById(id)!.workspaceId},
      contexts: ref.read(workspacesControllerProvider.notifier),
      selection: ref.read(sessionSelectionProvider.notifier),
      messenger: ScaffoldMessenger.maybeOf(context),
    );
  }

  void _file(String? workspaceId, String? name) =>
      _apply(_capture(), workspaceId, name);

  Future<void> _fileIntoNewContext() async {
    final captured = _capture();
    if (captured.ids.isEmpty) return;
    final created = await NewContextDialog.show(
      context,
      movingCount: captured.ids.length,
    );
    if (created == null) return;
    _apply(captured, created.id, created.name);
  }

  static void _apply(
    ({
      List<String> ids,
      Map<String, String?> previous,
      WorkspacesController contexts,
      SessionSelectionController selection,
      ScaffoldMessengerState? messenger,
    })
    captured,
    String? workspaceId,
    String? name,
  ) {
    if (captured.ids.isEmpty) return;
    captured.contexts.assignAll({
      for (final id in captured.ids) id: workspaceId,
    });
    captured.selection.leave();
    final many = SelectionKind.projects.count(captured.ids.length);
    captured.messenger?.showSnackBar(
      SnackBar(
        content: Text(
          name == null
              ? 'Removed $many from their context.'
              : 'Moved $many to $name.',
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => captured.contexts.assignAll(captured.previous),
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final bulk = ref.read(sessionBulkDeleteProvider);
    final targets = bulk.resolve(_selection.ids);
    if (targets.isEmpty) return;
    final deleteFromCli = await confirmBulkSessionDelete(context, targets);
    if (deleteFromCli == null) return;
    bulk.run(targets, deleteFromCli: deleteFromCli);
  }
}

/// The menu a row shows while it is ticked: the selection's verbs, which act on
/// the whole set. Null for a row that is not in the selection.
List<PopupMenuEntry<String>>? selectionRowMenu(
  WidgetRef ref,
  BuildContext context,
  String id,
) {
  final selection = ref.read(sessionSelectionProvider);
  if (!selection.active || !selection.contains(id)) return null;
  return ExplorerSelectionVerbs(ref, context).rowMenu();
}

/// The menu value for "Select", on every selectable row's own menu.
const selectRowAction = 'select';

/// "Select": enters selection mode with this row ticked.
PopupMenuEntry<String> selectRowMenuItem() => DesktopMenuItem(
  value: selectRowAction,
  label: 'Select',
  icon: AppIcons.check,
);

/// Handles a selection verb picked from a row's menu. Answers, at once, whether
/// [action] was one; the verb itself may go on to ask something.
bool runSelectionRowAction(
  WidgetRef ref,
  BuildContext context,
  String action, {
  required String id,
  required SelectionKind kind,
}) {
  if (action == selectRowAction) {
    ref.read(sessionSelectionProvider.notifier).toggle(id, kind: kind);
    return true;
  }
  if (!ExplorerSelectionVerbs.owns(action)) return false;
  unawaited(ExplorerSelectionVerbs(ref, context).run(action));
  return true;
}
