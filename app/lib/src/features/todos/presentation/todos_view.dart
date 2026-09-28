import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../explorer/application/session_context.dart';
import '../../notes/application/composer_draft.dart';
import '../../sessions/application/session_providers.dart';
import '../../settings/presentation/data_connection_notice.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/todos_providers.dart';
import '../domain/project_scope.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'project_menu.dart';
import 'package:karmashala_ui/primitives.dart';

/// The resting height of either text field, in lines. Both start at one, which
/// is how the panel has always looked when there is nothing in it.
const _minLines = 1;

/// The most the composer grows to before it scrolls inside itself. This field
/// is *pinned* above the list, so every line it takes hides a todo.
const _composerMaxLines = 4;

/// The Todos surface: a line of text, done or not, in the order you put it in.
/// A todo is one paragraph, so Enter files it and no field inserts a newline.
class TodosView extends ConsumerStatefulWidget {
  const TodosView({super.key});

  @override
  ConsumerState<TodosView> createState() => _TodosViewState();
}

class _TodosViewState extends ConsumerState<TodosView> {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();

  /// Whether the finished group is folded away. Open by default, so ticking a
  /// line off never makes it vanish from under the pointer; folding is the
  /// user's own choice, for a long list of things already done.
  bool _doneCollapsed = false;

  @override
  void dispose() {
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // "New todo" in the palette opens this surface and asks for the cursor. Only
    // on a *change*, so merely showing the panel never takes the keyboard.
    ref.listen(todoComposerFocusProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _composerFocus.requestFocus();
      });
    });
    final scope = ref.watch(todoScopeProvider);
    final all = ref.watch(todosProvider);
    final shown = [
      for (final todo in all)
        if (scope.contains(todo.projectId)) todo,
    ];
    // Two groups, each in the order the user put it in: what is still to do,
    // then what is finished. Split here rather than trusted to the store's
    // order, so a tick moves a line to the other group and nowhere else.
    final openTodos = [
      for (final todo in shown)
        if (!todo.isDone) todo,
    ];
    final doneTodos = [
      for (final todo in shown)
        if (todo.isDone) todo,
    ];
    final open = openTodos.length;
    final done = doneTodos.length;

    // The rows, flattened once: open lines, then the Done header, then — while
    // it is unfolded — the finished lines under it.
    final rows = <Widget>[
      // The project is named under the line only while the panel shows more
      // than one; under a filter it would repeat the header on every row.
      for (final todo in openTodos)
        _TodoRow(key: ValueKey(todo.id), todo: todo, showProject: scope.isAll),
      if (done > 0)
        _DoneHeader(
          count: done,
          collapsed: _doneCollapsed,
          onToggle: () => setState(() => _doneCollapsed = !_doneCollapsed),
          onClear: () => _clearDone(done, scope),
        ),
      if (!_doneCollapsed)
        for (final todo in doneTodos)
          _TodoRow(
            key: ValueKey(todo.id),
            todo: todo,
            showProject: scope.isAll,
          ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.listChecks,
          title: open == 0 ? 'Todos' : 'Todos  ·  $open',
          actions: [
            // Flexible, as PaneHeader asks of anything that has to give way
            // with the title: a project name can be longer than the panel.
            Flexible(
              child: ProjectScopeButton(
                scope: scope,
                onSelected: (next) =>
                    ref.read(todoScopeProvider.notifier).select(next),
              ),
            ),
          ],
        ),
        const DataConnectionNotice(padding: DataConnectionNotice.inPanel),
        _Composer(
          controller: _composer,
          focusNode: _composerFocus,
          scope: scope,
          onSubmit: _add,
        ),
        Expanded(
          child: shown.isEmpty
              ? _EmptyTodos(scope: scope, hasAny: all.isNotEmpty)
              : ListView.builder(
                  padding: const EdgeInsets.only(
                    left: Insets.xs,
                    right: Insets.xs,
                    bottom: Insets.sm,
                  ),
                  itemCount: rows.length,
                  itemBuilder: (context, index) => rows[index],
                ),
        ),
      ],
    );
  }

  void _add(String text) {
    if (text.trim().isEmpty) return;
    ref
        .read(todosProvider.notifier)
        .add(
          body: text,
          projectId: ref.read(todoScopeProvider).projectForNewItems,
        );
    _composer.clear();
  }

  /// Asks first; the dialog names the count, so nothing reports it again after.
  Future<void> _clearDone(int count, ProjectScope scope) async {
    final noun = 'finished todo${count == 1 ? '' : 's'}';
    final confirmed = await showConfirmDialog(
      context,
      title: 'Clear $count $noun?',
      message:
          '${count == 1 ? 'It is' : 'They are'} deleted for good. There is no undo.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    ref.read(todosProvider.notifier).clearDone(scope: scope);
  }
}

/// The one field that makes a todo. Deliberately the first thing under the
/// header: writing one has to cost less than deciding where to put it.
class _Composer extends ConsumerWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.scope,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ProjectScope scope;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // What the hint promises is exactly what `add` does: a todo written while
    // looking at everything is filed under nothing, which is a real answer
    // rather than a default nobody chose.
    final hint = scope.projectId == null
        ? 'New todo'
        : 'New todo in ${projectScopeLabel(scope, ref)}';
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    // A field drawn in the panel's own raised tone with no outline at rest:
    // it reads as the list's first, empty line rather than as a form. The
    // accent edge arrives with the cursor, the one moment it is the subject.
    final rest = OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.sm),
      borderSide: BorderSide.none,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.sm,
        Insets.sm,
        Insets.sm,
        Insets.xs,
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        // Grows down instead of scrolling sideways: a single-line field scrolls
        // right, and the owner's longest todo runs to 200 characters.
        minLines: _minLines,
        maxLines: _composerMaxLines,
        // `TextInputType.text` is the half of the one-paragraph contract the
        // *platform* reads: multiline turns Return into a newline and never acts.
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.done,
        onSubmitted: onSubmit,
        style: UiDensity.of(
          context,
        ).rowTitle(theme)?.copyWith(fontWeight: FontWeight.w400),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: tones.raised,
          hintText: hint,
          hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          border: rest,
          enabledBorder: rest,
          focusedBorder: rest.copyWith(
            borderSide: BorderSide(
              color: StateLayers.focusRing(theme.colorScheme),
              width: StateLayers.focusRingWidth,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: 6,
          ),
          prefixIcon: Icon(
            AppIcons.plus,
            size: Chrome.iconSmall,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: Chrome.control,
            minHeight: Chrome.control,
          ),
        ),
      ),
    );
  }
}

/// The head of the finished group: a caret that folds it, its name and count,
/// and the one way to clear it. Clear lives here rather than in the pane
/// header because it acts on exactly the rows under this line.
class _DoneHeader extends StatelessWidget {
  const _DoneHeader({
    required this.count,
    required this.collapsed,
    required this.onToggle,
    required this.onClear,
  });

  final int count;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = theme.textTheme.labelSmall
        ?.merge(Chrome.groupLabel)
        .copyWith(color: muted);
    final noun = 'finished todo${count == 1 ? '' : 's'}';
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: SizedBox(
        height: Chrome.row,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                expanded: !collapsed,
                label: collapsed ? 'Show $noun' : 'Hide $noun',
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  onTap: onToggle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                    child: Row(
                      children: [
                        Icon(
                          collapsed ? AppIcons.caretRight : AppIcons.caretDown,
                          size: Chrome.iconSmall,
                          color: muted,
                        ),
                        const SizedBox(width: Insets.xs),
                        // Its own Text, so the word is the same whatever the
                        // count: the group is "Done", and the number beside it.
                        Text('DONE', style: label),
                        const SizedBox(width: Insets.xs),
                        Text(
                          '$count',
                          style: label?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Clear $count $noun',
              iconSize: Chrome.iconAction,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(
                minWidth: Chrome.control,
                minHeight: Chrome.control,
              ),
              padding: EdgeInsets.zero,
              icon: Icon(AppIcons.trash, color: muted),
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}

/// One todo: a tick, the line, and the menu that moves, files or removes it.
/// The tick is the row's focus stop, which is what makes `Shift+F10` work.
class _TodoRow extends ConsumerStatefulWidget {
  const _TodoRow({required this.todo, required this.showProject, super.key});

  final Todo todo;

  /// Whether to name the project under the line.
  final bool showProject;

  @override
  ConsumerState<_TodoRow> createState() => _TodoRowState();
}

class _TodoRowState extends ConsumerState<_TodoRow> {
  TextEditingController? _editor;

  @override
  void dispose() {
    _editor?.dispose();
    super.dispose();
  }

  void _startEditing() {
    if (_editor != null) return;
    setState(() => _editor = TextEditingController(text: widget.todo.body));
  }

  void _commitEditing() {
    final editor = _editor;
    if (editor == null) return;
    final text = editor.text;
    setState(() {
      editor.dispose();
      _editor = null;
    });
    ref.read(todosProvider.notifier).edit(widget.todo.id, text);
  }

  /// The session this row would send to, captured when the menu was built: the
  /// answer the row was *labelled* with is the one the user chose.
  ({String id, String title})? _sendTo;

  /// Where "send this to the session" goes: [focusedSessionIdProvider] and
  /// nothing else. **Read, never watched** — a menu is built as it opens.
  ({String id, String title})? _resolveTarget() {
    final id = ref.read(focusedSessionIdProvider);
    if (id == null) return null;
    return (
      id: id,
      title: ref.read(sessionsDataProvider).getById(id)?.title ?? 'the session',
    );
  }

  /// The row's actions, built fresh per call: the same entries cannot be mounted
  /// by the `⋮` and by a right-click at once.
  List<PopupMenuEntry<String>> _menuItems() {
    final target = _sendTo = _resolveTarget();
    return [
      if (!widget.todo.isDone) ...[
        DesktopMenuItem(value: 'up', label: 'Move up', icon: AppIcons.arrowUp),
        DesktopMenuItem(
          value: 'down',
          label: 'Move down',
          icon: AppIcons.arrowDown,
        ),
        const DesktopMenuDivider(),
      ],
      // Behind the menu rather than drawn on the row, unlike the Notes card's
      // Send. A note exists to be handed back to an agent; a todo exists to be
      // ticked off, and the verb it is *for* is already the checkbox.
      DesktopMenuItem(
        value: 'send',
        label: target == null
            ? 'Send to a session — open one first'
            : 'Send to ${target.title}',
        icon: AppIcons.paperPlaneRight,
        enabled: target != null,
      ),
      DesktopMenuItem(
        value: 'file',
        label: 'File under…',
        icon: AppIcons.folder,
      ),
      const DesktopMenuDivider(),
      DesktopMenuItem(
        value: 'delete',
        label: 'Delete',
        icon: AppIcons.trash,
        destructive: true,
      ),
    ];
  }

  Future<void> _act(String value) async {
    final todos = ref.read(todosProvider.notifier);
    switch (value) {
      case 'up':
        todos.move(widget.todo.id, up: true);
      case 'down':
        todos.move(widget.todo.id, up: false);
      case 'delete':
        final confirmed = await showConfirmDialog(
          context,
          title: 'Delete todo?',
          message:
              '“${widget.todo.body}” is deleted for good. There is no undo.',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (!confirmed || !mounted) return;
        todos.delete(widget.todo.id);
      case 'send':
        _send();
      case 'file':
        await _file();
    }
  }

  /// Offers the line to the session, in whichever face it is showing. **Offered,
  /// not sent**, and nothing here ticks it off: handed to an agent is not done.
  void _send() {
    final target = _sendTo;
    if (target == null) return;
    // Into whichever face that session is showing: its terminal is typed at,
    // its conversation is queued for. The face is read, never changed.
    final outcome = offerToSession(
      ref,
      sessionId: target.id,
      text: widget.todo.body,
    );
    // Bring that session up, so what the line landed in is the one on screen.
    // Selecting is all this does.
    ref.read(selectedSessionIdProvider.notifier).select(target.id);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(sessionOfferMessage(outcome, target.title))),
    );
  }

  /// The "file under…" picker, anchored on the row rather than on a button: a
  /// right-click and `Shift+F10` reach it too and have no button to sit under.
  Future<void> _file() async {
    final chosen = await showDesktopMenuUnder<ProjectScope>(
      context,
      projectPickerMenuItems(ref, selected: widget.todo.projectId),
    );
    if (chosen == null || !mounted) return;
    ref
        .read(todosProvider.notifier)
        .setProject(widget.todo.id, chosen.projectId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final todo = widget.todo;
    final project = todo.projectId == null
        ? null
        : projectNameById(ref, todo.projectId!);
    final menuLabel = 'Actions for “${todo.body}”';
    // 13/18 under a pointer, with 4px above and below: a one-line todo is the
    // tick's control square tall, and a long one wraps under its own line.
    final bodyStyle = density
        .rowTitle(theme)
        ?.copyWith(
          fontWeight: FontWeight.w400,
          // Finished is dimmed and struck, never removed: it is still the user's
          // line until they clear it.
          color: todo.isDone ? scheme.onSurfaceVariant : null,
          decoration: todo.isDone ? TextDecoration.lineThrough : null,
          decorationColor: todo.isDone ? scheme.onSurfaceVariant : null,
        );

    return RowContextMenu(
      menuLabel: menuLabel,
      itemBuilder: _menuItems,
      onSelected: _act,
      builder: (context) => _HoverWash(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox.square(
              dimension: density.isTouch ? Touch.target : Chrome.control,
              child: Checkbox(
                value: todo.isDone,
                semanticLabel: todo.isDone
                    ? 'Reopen “${todo.body}”'
                    : 'Finish “${todo.body}”',
                // The tightest Material allows under a pointer, so the box
                // fits the control square instead of its 40px default.
                visualDensity: density.isTouch
                    ? VisualDensity.standard
                    : const VisualDensity(
                        horizontal: VisualDensity.minimumDensity,
                        vertical: VisualDensity.minimumDensity,
                      ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (next) => ref
                    .read(todosProvider.notifier)
                    .setDone(todo.id, next ?? false),
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: density.isTouch ? Insets.md : 4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_editor case final editor?)
                      TextField(
                        controller: editor,
                        autofocus: true,
                        // Unbounded, unlike the composer: the row it replaces already draws the body
                        // wrapped, so tapping to edit never makes the line you were reading jump.
                        minLines: _minLines,
                        maxLines: null,
                        // Same contract as the composer, for the same reason.
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.done,
                        // The row's own style, minus the strike: what is being
                        // typed is read, not marked finished.
                        style: bodyStyle?.copyWith(
                          decoration: TextDecoration.none,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                        onSubmitted: (_) => _commitEditing(),
                        // Clicking away keeps the edit rather than dropping it:
                        // the user finished typing and looked elsewhere, which
                        // is not the same as asking to undo.
                        onTapOutside: (_) => _commitEditing(),
                      )
                    else
                      // A tap edits — there is nowhere else for a tap on a todo to go. A URL opens;
                      // a tap anywhere else still edits.
                      LinkableText(
                        todo.body,
                        onTapText: _startEditing,
                        style: bodyStyle,
                      ),
                    if (project != null && widget.showProject)
                      Text(
                        project,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: density.muted(theme),
                      ),
                  ],
                ),
              ),
            ),
            // Kept, and revealed rather than removed: right-click is invisible until it
            // is tried. Always drawn on a touch surface, which has no hover.
            RowMenuButton(
              tooltip: menuLabel,
              itemBuilder: _menuItems,
              onSelected: _act,
            ),
          ],
        ),
      ),
    );
  }
}

/// A row's hover wash, read from its [RowInteractionScope] so only this box
/// repaints as the pointer crosses — the row itself is not rebuilt, since
/// [child] is the same widget either way.
class _HoverWash extends StatelessWidget {
  const _HoverWash({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final engaged = RowInteractionScope.maybeOf(context)?.hovered ?? false;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: engaged
            ? StateLayers.hover(Theme.of(context).colorScheme)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: child,
    );
  }
}

/// What an empty Todos panel says. Two emptinesses, because "no todos yet"
/// while eleven sit under another project is a lie easily avoided.
class _EmptyTodos extends StatelessWidget {
  const _EmptyTodos({required this.scope, required this.hasAny});

  final ProjectScope scope;
  final bool hasAny;

  @override
  Widget build(BuildContext context) {
    if (hasAny) {
      return PanePlaceholder(
        icon: AppIcons.listChecks,
        message: scope.unfiledOnly
            ? 'No todos outside a project. Everything you have written is '
                  'filed under one.'
            : 'Nothing here yet. A todo written while this project is '
                  'showing is filed under it.',
      );
    }
    return const PanePlaceholder(
      icon: AppIcons.listChecks,
      message:
          'No todos yet. Type one in the box above — it belongs to whichever '
          'project the header names, or to no project at all.\n\n'
          'This is your list, not the app’s: nothing appears here on its own '
          'and nothing leaves until you tick it off. What the app noticed for '
          'you is in the Inbox.',
    );
  }
}
