import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../../app/widgets/row_menu.dart';
import '../../explorer/application/session_context.dart';
import '../../notes/application/composer_draft.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/todos_providers.dart';
import '../domain/project_scope.dart';
import '../domain/todo.dart';
import 'project_menu.dart';

/// The resting height of either text field, in lines. Both start at one, which
/// is how the panel has always looked when there is nothing in it.
const _minLines = 1;

/// The most the composer grows to before it scrolls inside itself instead.
///
/// Four rather than unbounded because this field is *pinned* above the list:
/// every line it takes is a line of todos it hides, and a paste of something
/// enormous must not swallow the panel. The row editor has no such cap — see
/// there for why.
const _composerMaxLines = 4;

/// The Todos surface: a line of text, done or not, in the order you put it in.
///
/// ## What Enter does, and why there is no line break
///
/// **A todo is a single paragraph.** Enter files a new one and commits an edit;
/// nothing here inserts a newline, and both fields declare
/// `TextInputType.text` so that no platform inserts one behind our back.
///
/// The alternative was `MessageComposer`'s contract — Enter sends, Shift+Enter
/// breaks the line — and it is the wrong one here. That field writes a
/// *prompt*, which really is multi-paragraph, and it buys the break with a
/// `FocusNode.onKeyEvent` that swallows Return before the engine sees it. A
/// todo wants none of that: the row draws it as one run of text, the list gives
/// it one position, `todo_add` takes one `body`, and a second paragraph would
/// have nowhere to be read. Buying a break we do not want would also cost the
/// thing we do: on the companion's soft keyboard the return key would become a
/// newline and there would be no way left to save at all.
///
/// What the fields *are* is wrapping. A single-line `TextField` scrolls
/// `AxisDirection.right`, so a 200-character todo — an ordinary one here — had
/// to be dragged sideways to be re-read while typing it. Both fields now grow
/// downwards instead.
///
/// ## How this differs from the attention inbox
///
/// The inbox and this panel both list things that want doing, and only one of
/// them is a list *you* wrote. The inbox is **observed**: the app notices an
/// agent waiting on approval, a turn that failed, a build that went red, and it
/// files and un-files those rows itself as the conditions change. Nothing a
/// person types can put a row there, and a row leaves when the app decides it
/// has. A todo is the opposite in every one of those respects — it is written,
/// by a person or by an agent through `todo_add`, it never appears on its own,
/// and nothing but a tick or a delete takes it away. That is also why this
/// rail glyph carries **no badge**: a count here would make a hand-written list
/// look like an alert queue, which is the inbox's job and not this panel's.
///
/// ## Why a surface of its own rather than a section of Notes
///
/// They are the same *kind* of thing — the user's own writing, filed to a
/// project or to nothing — and sharing one panel was the obvious move. What
/// rules it out is `Settings → Notes`: that switch really does hide the Notes
/// surface, and a todo list that vanishes because somebody turned off a
/// different feature is a broken todo list. The two also want opposite verbs (a
/// note is *sent back* to an agent, a todo is *ticked off*) and opposite
/// orders, so a shared panel would have shared nothing but the frame.
class TodosView extends ConsumerStatefulWidget {
  const TodosView({super.key});

  @override
  ConsumerState<TodosView> createState() => _TodosViewState();
}

class _TodosViewState extends ConsumerState<TodosView> {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The panel has just turned to Todos, so the list is about to be read.
    // After the frame, because this may replace the state the build below is
    // already using — see [TodosController.refresh] for why anything has to
    // ask at all.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(todosProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // "New todo" in the palette opens this surface and asks for the cursor, so
    // somebody who could not find the panel can keep typing the todo they came
    // to write. Only on a *change*, so merely showing the panel never takes
    // the keyboard away from the terminal.
    ref.listen(todoComposerFocusProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _composerFocus.requestFocus();
      });
    });
    // The other moment the list is about to be read: the user has come back to
    // the window, over a panel that never went away. `initState` above cannot
    // see that, and it is the case the owner actually hit.
    //
    // The listener lives here rather than in the controller so that it exists
    // only while this surface does: a closed panel costs nothing, and neither
    // does a focus regain over a list that has not changed. Only a *genuine*
    // regain counts — the window must have been seen to lose focus first, which
    // is the guard `FileListingRefreshController` uses for the same signal.
    ref.listen(windowFocusedProvider, (previous, next) {
      if (!next || previous != false) return;
      ref.read(todosProvider.notifier).refresh();
    });
    final scope = ref.watch(todoScopeProvider);
    final all = ref.watch(todosProvider);
    final shown = [
      for (final todo in all)
        if (scope.contains(todo.projectId)) todo,
    ];
    final open = shown.where((todo) => !todo.isDone).length;
    final done = shown.length - open;

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
            if (done > 0)
              IconButton(
                tooltip: 'Clear $done finished todo${done == 1 ? '' : 's'}',
                iconSize: Chrome.icon,
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.trash),
                onPressed: () => _clearDone(context),
              ),
          ],
        ),
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
                  padding: const EdgeInsets.only(bottom: Insets.sm),
                  itemCount: shown.length,
                  itemBuilder: (context, index) {
                    final todo = shown[index];
                    // The one divider in the list: everything under it is
                    // finished, so a tick never makes a row disappear.
                    final startsDone =
                        todo.isDone && (index == 0 || !shown[index - 1].isDone);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (startsDone) const _DoneDivider(),
                        // The project is named under the line only while the
                        // panel is showing more than one, where it is the
                        // answer to "why is this in my list"; under a filter
                        // it would repeat the header on every row.
                        _TodoRow(todo: todo, showProject: scope.isAll),
                      ],
                    );
                  },
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

  void _clearDone(BuildContext context) {
    final removed = ref.read(todosProvider.notifier).clearDone();
    if (removed == 0) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Cleared $removed finished todo${removed == 1 ? '' : 's'}.',
        ),
      ),
    );
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
        // Grows down instead of scrolling sideways. A single-line field
        // scrolls `AxisDirection.right`, and a real todo is a sentence: the
        // owner's longest runs to 200 characters, so the *normal* case was a
        // box you had to drag horizontally to re-read what you had typed.
        // Capped at four lines because the composer is pinned above the list
        // and must not grow until it has eaten it; past that it scrolls.
        minLines: _minLines,
        maxLines: _composerMaxLines,
        // A todo is one paragraph, so Enter files it rather than breaking the
        // line — see [TodosView]. `TextInputType.text` is the
        // half of that contract the *platform* reads: left to itself a
        // multi-line field asks for `TextInputType.multiline`, and both the
        // Windows key handler and a soft keyboard would then turn Return into
        // a newline and never deliver the action.
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.done,
        onSubmitted: onSubmit,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          prefixIcon: const Icon(AppIcons.plus, size: Chrome.iconSmall),
          prefixIconConstraints: const BoxConstraints(
            minWidth: Chrome.control,
            minHeight: Chrome.control,
          ),
        ),
      ),
    );
  }
}

class _DoneDivider extends StatelessWidget {
  const _DoneDivider();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.md, Insets.md, Insets.md, 2),
      child: Text(
        'DONE',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One todo: a tick, the line, and the menu that moves, files or removes it.
///
/// The menu is reached the four ways [RowContextMenu] defines — right-click,
/// `Shift+F10`, the Menu key, a screen reader's action — and the `⋮` that
/// duplicates them is drawn only while a pointer or the keyboard is on the
/// row. The tick is the row's focus stop, which is what makes `Shift+F10`
/// reachable here with no mouse at all.
class _TodoRow extends ConsumerStatefulWidget {
  const _TodoRow({required this.todo, required this.showProject});

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

  /// The session this row would send to, captured when the menu was built.
  ///
  /// Captured rather than re-read on activation, for the reason
  /// `resolveSnippetTarget` gives: the answer the row was *labelled* with is
  /// the one the user chose, and a fresh read could send the line to a session
  /// that came to the front while the menu was open.
  ({String id, String title})? _sendTo;

  /// Where "send this to the session" goes.
  ///
  /// [focusedSessionIdProvider] and nothing else — the Explorer's selection,
  /// and failing that the session running in the focused group's active tab.
  /// That is already the app's one answer to "which session is this window
  /// about", and a side panel that invented a second would describe a
  /// different session from the status bar two inches away.
  ///
  /// **Read, never watched.** A menu is built as it opens, so reading here
  /// costs one lookup per menu; watching would put every row of the list on
  /// the focused-session signal and repaint the panel on every tab click.
  ({String id, String title})? _resolveTarget() {
    final id = ref.read(focusedSessionIdProvider);
    if (id == null) return null;
    return (
      id: id,
      title: ref.read(sessionDaoProvider).getById(id)?.title ?? 'the session',
    );
  }

  /// The row's actions, in the one vocabulary every path to them shares.
  ///
  /// Built fresh per call: the same entries cannot be mounted by the `⋮` and
  /// by a right-click at once, and a menu is only ever built as it opens.
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
            : 'Send to ${target.title}’s message box',
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
        todos.delete(widget.todo.id);
      case 'send':
        _send();
      case 'file':
        await _file();
    }
  }

  /// Puts the line in the session's message box.
  ///
  /// **Offered, not sent** — the contract [ComposerDrafts] already gives a
  /// note, and the reason is the same one twice over: a todo is a deferred
  /// instruction the user wrote for themselves, and dispatching one would be
  /// Karmashala deciding it was still worded right. Nothing here ticks it off
  /// either; a line handed to an agent is not a line that is done.
  void _send() {
    final target = _sendTo;
    if (target == null) return;
    ref.read(composerDraftProvider.notifier).queue(target.id, widget.todo.body);
    // Bring that session up, so the box the text just landed in is the one on
    // screen. Selecting is all this does.
    ref.read(selectedSessionIdProvider.notifier).select(target.id);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Sent to ${target.title}’s message box.')),
    );
  }

  /// The "file under…" picker, opened where the row is rather than as a
  /// dialog: moving a todo between projects is a menu choice, not a form.
  ///
  /// Anchored on the row rather than on the button that used to own this menu,
  /// because the button is no longer the only way here — a right-click and
  /// `Shift+F10` reach the same choice and neither has a button to sit under.
  Future<void> _file() async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final chosen = await showMenu<ProjectScope>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + box.size.height,
        overlay.size.width - origin.dx - box.size.width,
        0,
      ),
      items: projectPickerMenuItems(ref, selected: widget.todo.projectId),
    );
    if (chosen == null || !mounted) return;
    ref.read(todosProvider.notifier).setProject(widget.todo.id, chosen.projectId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final todo = widget.todo;
    final project = todo.projectId == null
        ? null
        : projectNameById(ref, todo.projectId!);
    final menuLabel = 'Actions for “${todo.body}”';

    return RowContextMenu(
      menuLabel: menuLabel,
      itemBuilder: _menuItems,
      onSelected: _act,
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: todo.isDone,
              semanticLabel: todo.isDone
                  ? 'Reopen “${todo.body}”'
                  : 'Finish “${todo.body}”',
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (next) => ref
                  .read(todosProvider.notifier)
                  .setDone(todo.id, next ?? false),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_editor case final editor?)
                      TextField(
                        controller: editor,
                        autofocus: true,
                        // Unbounded, unlike the composer: the row this replaces
                        // already draws the whole body wrapped, so a field that
                        // grows to exactly the same height means tapping to edit
                        // never makes the line you were reading jump or shrink.
                        // A tall row is only a tall row — the list scrolls.
                        minLines: _minLines,
                        maxLines: null,
                        // Same contract as the composer, for the same reason.
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.done,
                        style: theme.textTheme.bodyMedium,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                        onSubmitted: (_) => _commitEditing(),
                        // Clicking away keeps the edit rather than dropping it:
                        // the user finished typing and looked elsewhere, which
                        // is not the same as asking to undo.
                        onTapOutside: (_) => _commitEditing(),
                      )
                    else
                      // A tap edits. There is nowhere else for a tap on a todo
                      // to go, and a one-line thing whose typo you cannot fix is
                      // a thing you delete and retype.
                      InkWell(
                        onTap: _startEditing,
                        child: Text(
                          todo.body,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: todo.isDone ? scheme.onSurfaceVariant : null,
                            decoration: todo.isDone
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),
                    if (project != null && widget.showProject)
                      Text(
                        project,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Kept, and revealed rather than removed. Right-click is
            // invisible until it is tried; a button that appears when the
            // pointer is on the row costs nothing at rest and is how the menu
            // is discovered in the first place. On a touch surface — the
            // companion runs this pane — it is always drawn, because there is
            // no right-click and no hover there to reveal it with.
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

/// What an empty Todos panel says.
///
/// Two different emptinesses, because they need two different answers: an empty
/// *filter* is not an empty list, and saying "no todos yet" while eleven of
/// them sit under another project is a lie the panel can easily avoid.
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
