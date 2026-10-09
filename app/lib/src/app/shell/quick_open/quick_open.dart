import 'dart:async';

import 'package:agent_cli/process.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_git/git.dart';

import '../../../features/cli_detection/data/conversation_search.dart';
import '../../../features/git/application/changes_providers.dart';
import '../../../features/overview/application/overview_prefs.dart';
import '../../../features/overview/presentation/background_launch_notice.dart';
import '../../../features/remote/application/remote_approval_bindings.dart';
import '../../../features/sessions/presentation/new_session_dialog.dart';
import '../../../features/sessions/presentation/session_destination_picker.dart'
    show SessionDestination;
import '../../../features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart' show SplitAxis;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import '../phone_routes.dart';
import '../shell_shortcuts.dart';
import '../workbench_tabs.dart' show openOverviewTab;
import 'conversation_hits.dart';
import 'quick_open_cache.dart';
import 'quick_open_item.dart';
import 'quick_open_list.dart';
import 'quick_open_sources.dart';
import 'quick_open_step.dart';
import 'repo_file_index.dart';
import 'typed_command.dart';
import 'typed_command_catalog.dart';
import 'typed_command_confirm.dart';
import 'typed_command_history.dart';
import 'typed_command_runner.dart';

part 'quick_open/typed_command_section.dart';
part 'quick_open/typed_command_run.dart';
part 'quick_open/quick_open_button.dart';
part 'quick_open/rows.dart';

/// History rows an empty box shows.
const int kTypedCommandHistoryShown = 5;

/// What a row of the command section does when it is picked.
class _CommandRow {
  const _CommandRow({
    this.completion,
    this.plan,
    this.history,
    this.enabled = true,
    this.dot,
  });

  /// A suggestion: the box after accepting it.
  final String? completion;

  /// The preview: what Enter runs.
  final CommandPlan? plan;

  /// A remembered command, parsed again when it is picked.
  final String? history;
  final bool enabled;
  final SessionDot? dot;
}

/// A [QuickOpenStep] the palette is in, with its rows as last built and what
/// the level above had — so going back finds the query and the highlight as
/// they were.
class _StepFrame {
  _StepFrame(
    this.step, {
    required this.queryBefore,
    required this.selectedBefore,
  });

  final QuickOpenStep step;
  final String queryBefore;
  final int selectedBefore;
  List<QuickOpenItem> items = const [];
}

/// Bumped when something outside the widget tree asks for quick open — today
/// the global hotkey. The counter's value means nothing, only that it moved.
class QuickOpenRequest extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final quickOpenRequestProvider = NotifierProvider<QuickOpenRequest, int>(
  QuickOpenRequest.new,
);

/// One search box over the whole workspace. *Nothing here fetches*: the file
/// index is a bounded local walk that begins only once the user types.
class QuickOpen extends ConsumerStatefulWidget {
  const QuickOpen({super.key, this.initialQuery = ''});

  /// Pre-typed text, used by the shortcut that opens straight into commands.
  final String initialQuery;

  static Future<void> show(BuildContext context, {String initialQuery = ''}) =>
      showDialog<void>(
        context: context,
        barrierColor: Theme.of(
          context,
        ).colorScheme.scrim.withValues(alpha: 0.35),
        builder: (_) => QuickOpen(initialQuery: initialQuery),
      );

  @override
  ConsumerState<QuickOpen> createState() => _QuickOpenState();
}

class _QuickOpenState extends ConsumerState<QuickOpen> {
  late final TextEditingController _controller;
  final _scroll = ScrollController();

  List<QuickOpenItem> _items = const [];

  /// The conversation rows for the query as typed, and the query they were built
  /// for — kept apart from [_items] as the only query-dependent source.
  List<QuickOpenItem> _conversationItems = const [];
  String _conversationQuery = '';

  /// The server's answers to this palette's conversation searches.
  late final ConversationHits _hits;

  List<QuickOpenSection> _sections = const [];
  List<QuickOpenResult> _flat = const [];
  int _selected = 0;

  /// Held rather than re-read, because [dispose] needs it after `ref` is no
  /// longer somewhere to read providers from.
  late final RepoFileIndex _index;

  /// The root whose files are being asked for, or `null`.
  EnvironmentPath? _walking;

  StreamSubscription<EnvironmentPath>? _indexChanges;

  /// Read the first time a verb is typed, then kept for the palette's life.
  CommandCatalog? _catalog;

  /// Projects observed not to be under Git, so `--worktree` is refused there.
  final Set<String> _notGit = {};
  final Set<String> _gitAsked = {};

  List<String> _history = const [];

  /// The command section's rows by item id; empty when there is none.
  final Map<String, _CommandRow> _commandRows = {};

  /// The steps gone down into, innermost last; empty is the full list.
  final List<_StepFrame> _steps = [];

  /// True only while a row picked "to the side" runs: what [_sources]'
  /// `dismiss` reads to run the row's action as an open beside.
  bool _openingBeside = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    _history = _readHistory();
    _hits = ConversationHits(
      ref.read(conversationSearchProvider),
      onAnswer: _onConversationAnswer,
    );
    _index = ref.read(repoFileIndexProvider);
    // The index refreshes itself behind the dialog — a watcher fires, an agent
    // turn ends — so the open palette has to be told, not just asked once.
    _indexChanges = _index.changes.listen(_onIndexChanged);
    _rebuildItems();
    // Take a copy of whatever the app has already loaded about this repository.
    // Reading is free and the providers it reads are never created here — but
    // `harvest` *writes* `quickOpenCacheProvider` at the end, and a provider
    // may not be modified during a life-cycle. Debug asserts on it; release
    // lets the write through and risks the missed rebuild the assert exists to
    // prevent. So the palette opens on what was already cached and takes the
    // harvested facts a frame later.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(quickOpenCacheProvider.notifier)
          .harvest(
            ProviderScope.containerOf(context, listen: false),
            ref.read(selectedRepositoryIdProvider),
          );
      setState(_rebuildItems);
      _catchUpConversations();
    });
  }

  /// Asks the server to read what the running sessions appended since their
  /// last reading, then searches again if that found anything — so today's
  /// turns are findable.
  void _catchUpConversations() {
    ref.read(conversationSearchProvider).catchUp().then(
      (changed) {
        if (!mounted || changed == 0) return;
        _hits.forget();
        _onConversationAnswer();
      },
      // No server to ask: the search answers from what it has.
      onError: (Object _) {},
    );
  }

  /// The server answered a conversation search: draw it.
  void _onConversationAnswer() {
    // A step lists no conversations; going back searches again.
    if (!mounted || _steps.isNotEmpty) return;
    setState(() {
      _searchConversations(force: true);
      _rerank();
    });
  }

  @override
  void dispose() {
    _hits.close();
    _indexChanges?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  QuickOpenQuery get _query => QuickOpenQuery.parse(_controller.text);

  /// The changed paths, when some other surface has already run `git status`.
  Set<String> _changedPaths() {
    final container = ProviderScope.containerOf(context, listen: false);
    if (!container.exists(repositoryChangesProvider)) return const {};
    final changes = container.read(repositoryChangesProvider).asData?.value;
    return {for (final change in changes ?? const []) change.path};
  }

  QuickOpenSources _sources() {
    final navigator = Navigator.of(context);
    return QuickOpenSources(
      ref: ref,
      // The navigator's own context, not this dialog's: an item's action runs
      // *after* quick open has popped, and a route on its way out is no host.
      context: navigator.context,
      dismiss: (action) {
        // Resolved before the pop: an unmounted element has no `ref` to read.
        final terminals = _openingBeside
            ? ref.read(terminalSessionsControllerProvider.notifier)
            : null;
        navigator.pop();
        if (terminals == null) {
          action();
        } else {
          terminals.openBeside(action);
        }
      },
      push: _push,
      phone: ref.read(phoneShellRouterProvider).current,
    );
  }

  void _rebuildItems() {
    final root = ref.read(quickOpenFileRootProvider);
    _items = _sources().build(
      files: root == null ? const [] : _index.cached(root),
      changedPaths: _changedPaths(),
    );
    final step = _steps.lastOrNull;
    if (step != null) step.items = step.step.items();
    _rerank();
  }

  // --- steps -----------------------------------------------------------------

  /// Goes down into [step]: the box empties and the highlight is on its first
  /// row, which the step put first because it is what Enter should do.
  void _push(QuickOpenStep step) {
    if (!mounted) return;
    setState(() {
      _steps.add(
        _StepFrame(
          step,
          queryBefore: _controller.text,
          selectedBefore: _selected,
        )..items = step.items(),
      );
      _controller.clear();
      _selected = 0;
      _rerank();
    });
    _revealSelectedAfterLayout();
  }

  /// Back up one step, to the query and highlight the level above had. False
  /// when already at the full list.
  bool _back() {
    if (_steps.isEmpty) return false;
    final frame = _steps.removeLast();
    _controller.value = TextEditingValue(
      text: frame.queryBefore,
      selection: TextSelection.collapsed(offset: frame.queryBefore.length),
    );
    setState(() {
      // Rebuilt rather than kept: the level above may be the full list, whose
      // rows moved on while the step was open.
      _rebuildItems();
      if (_steps.isEmpty) {
        _searchConversations(force: true);
        _rerank();
      }
      _selected = _flat.isEmpty
          ? 0
          : frame.selectedBefore.clamp(0, _flat.length - 1);
    });
    _revealSelectedAfterLayout();
    return true;
  }

  /// Runs the conversation search for the query as typed: a ranked page from
  /// the server's index, and no debounce — lagging the list would read as a
  /// bug. Until the server answers, the last answer stays on screen.
  void _searchConversations({bool force = false}) {
    final query = _query;
    final only = query.only;
    final text = only == null || only == QuickOpenGroup.conversations
        ? query.text
        : '';
    if (text == _conversationQuery && !force) return;
    _conversationQuery = text;
    if (text.isEmpty) {
      _conversationItems = const [];
      return;
    }
    final hits = _hits.hitsFor(text, kQuickOpenConversationLimit);
    if (hits != null) {
      _conversationItems = _sources().conversations(hits, text);
    }
  }

  void _rerank() {
    final step = _steps.lastOrNull;
    if (step != null) {
      // A step's rows are its own: no typed commands, no history, no sigils.
      _commandRows.clear();
      _sections = step.step.filter(_controller.text, step.items);
      _flat = [
        for (final section in _sections)
          for (final result in section.results) result,
      ];
      if (_selected >= _flat.length) _selected = 0;
      return;
    }
    final query = _query;
    // The command section leads when there is one; the search below it is the
    // same search as ever, so a verb typed by accident hides nothing.
    final command = _commandSection();
    _sections = [
      ?command,
      ...rankQuickOpen(query, [..._items, ..._conversationItems]),
    ];
    _flat = [
      for (final section in _sections)
        for (final result in section.results) result,
    ];
    if (_selected >= _flat.length) _selected = _flat.isEmpty ? 0 : 0;
  }

  /// The questions `answer` picks from are read off the frame, kept read
  /// while the palette is open, and the palette re-ranks when one lands.
  final Map<String, ProviderSubscription<AsyncValue<Object?>>> _questions = {};

  void _readQuestionsFor(TypedCommand typed) {
    if (typed.verb != CommandVerb.answer) return;
    for (final session in _catalogNow().sessions) {
      if (!session.questionUnread || _questions.containsKey(session.id)) {
        continue;
      }
      _questions[session.id] = ref.listenManual(
        chatOpenQuestionProvider(session.id),
        (_, next) {
          if (!mounted || next.asData?.value == null) return;
          _catalog = null;
          setState(_rerank);
        },
      );
    }
  }

  /// `--worktree` is refused on a folder that is not under Git; whether it is
  /// is read once per project, off the frame, and the palette re-ranks.
  void _askGitFor(TypedCommand typed) {
    if (typed.verb != CommandVerb.start) return;
    final text = _controller.text;
    for (final project in _catalogNow().projects) {
      if (_gitAsked.contains(project.id)) continue;
      if (!text.contains(project.token)) continue;
      _gitAsked.add(project.id);
      final checkout = commandDefaultCheckout(
        ProviderScope.containerOf(context, listen: false),
        project.id,
      );
      if (checkout == null) continue;
      ref.read(checkoutGitPresenceProvider(checkout.path).future).then((
        presence,
      ) {
        if (!mounted || presence != GitPresence.notARepository) return;
        _notGit.add(project.id);
        _catalog = null;
        setState(_rerank);
      }, onError: (_) {});
    }
  }

  /// Asks the server for the repository's files the first time the user
  /// types, and again when what is cached is stale. Never awaited: the cached
  /// list is already up.
  void _ensureFileIndex() {
    final root = ref.read(quickOpenFileRootProvider);
    // The selected repository changed under an open palette: the answer in
    // flight is for a tree nobody is searching any more.
    if (_walking != null && _walking != root) _walking = null;
    if (root == null || _index.isFresh(root) || _walking == root) return;
    _walking = root;
    _index.index(root).then((_) {
      if (!mounted) return;
      if (_walking == root) _walking = null;
      setState(_rebuildItems);
    });
  }

  /// Something under the indexed repository moved, or a walk landed. Re-rank
  /// against whatever is cached now, and start the re-walk if one is due.
  void _onIndexChanged(EnvironmentPath root) {
    if (!mounted || root != ref.read(quickOpenFileRootProvider)) return;
    if (_steps.isEmpty && !_query.isEmpty) _ensureFileIndex();
    setState(_rebuildItems);
  }

  void _onQueryChanged(String _) {
    final inStep = _steps.isNotEmpty;
    if (!inStep && !_query.isEmpty) _ensureFileIndex();
    setState(() {
      _selected = 0;
      if (!inStep) _searchConversations();
      _rerank();
    });
    _revealSelectedAfterLayout();
  }

  void _move(int delta) => _selectRow(_selected + delta);

  /// Moves the highlight to [index], clamped. Deliberately does **not** wrap: a
  /// list that jumps to its first row is one you cannot hold the key down on.
  void _selectRow(int index) {
    if (_flat.isEmpty) return;
    setState(() => _selected = index.clamp(0, _flat.length - 1));
    _revealSelected();
    // Again after layout: a lazy list only estimates the extent it has not
    // built, and a jump clamped to that estimate stops short of a far row.
    _revealSelectedAfterLayout();
  }

  /// The scroll offset of the row for result [index], counting the headers
  /// above it.
  double _offsetOf(int index) {
    final header = quickOpenHeaderHeightOf(context);
    final row = quickOpenRowHeightOf(context);
    var offset = 0.0;
    var seen = 0;
    for (final section in _sections) {
      offset += header;
      for (var i = 0; i < section.results.length; i++) {
        if (seen == index) return offset;
        offset += row;
        seen++;
      }
    }
    return offset;
  }

  /// Scrolls the highlighted row into view, after the frame when the list has
  /// just changed: until layout the extents describe the *previous* list.
  void _revealSelectedAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealSelected();
    });
  }

  void _revealSelected() {
    if (!_scroll.hasClients || _flat.isEmpty) return;
    final target = revealOffset(
      position: _scroll.position,
      leading: _offsetOf(_selected),
      extent: quickOpenRowHeightOf(context),
    );
    if (target != null) _scroll.jumpTo(target);
  }

  void _activate({bool beside = false}) {
    if (_flat.isEmpty) return;
    _pick(_flat[_selected].item, beside: beside);
  }

  /// Runs [item]; [beside] opens its tab to the side where that is offered,
  /// and is plain Enter everywhere else — a dialog has no side to open on.
  void _pick(QuickOpenItem item, {bool beside = false}) {
    if (!beside || !_offersBeside(item)) {
      item.onSelect();
      return;
    }
    _openingBeside = true;
    try {
      item.onSelect();
    } finally {
      _openingBeside = false;
    }
  }

  /// Whether this window can put a tab beside the work at all: never on a
  /// phone, which shows one group, nor in a window too narrow to split, nor
  /// before there is a group to be beside.
  bool get _besideAvailable =>
      ref.read(phoneShellRouterProvider).current == null &&
      !WidthClass.of(MediaQuery.sizeOf(context).width).isCompact &&
      ref
          .read(terminalSessionsControllerProvider.notifier)
          .canSplitWorkspace(SplitAxis.horizontal);

  bool _offersBeside(QuickOpenItem item) => item.opensTab && _besideAvailable;

  /// Ctrl+Enter — ⌘Enter on macOS — VS Code's "open to the side".
  static bool _isBesideChord(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    return commandActivator(
          LogicalKeyboardKey.enter,
        ).accepts(event, keyboard) ||
        commandActivator(
          LogicalKeyboardKey.numpadEnter,
        ).accepts(event, keyboard);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_isBesideChord(event)) {
      _activate(beside: true);
      return KeyEventResult.handled;
    }
    // Shift+Enter resumes the stopped session the row names; Enter only shows
    // it. A row with nothing to resume takes it as Enter.
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        HardwareKeyboard.instance.isShiftPressed &&
        _flat.isNotEmpty) {
      if (_flat[_selected].item.onResume case final resume?) {
        resume();
        return KeyEventResult.handled;
      }
    }
    // Backspace on an empty box goes back a step. A press, not a repeat: a held
    // key that has just emptied the query must not carry on up the stack.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _controller.text.isEmpty &&
        _back()) {
      return KeyEventResult.handled;
    }
    // Tab completes only while there is a command section to complete from;
    // otherwise it goes where it always went.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.tab &&
        !HardwareKeyboard.instance.isShiftPressed &&
        _commandRows.isNotEmpty &&
        _tabComplete()) {
      return KeyEventResult.handled;
    }
    return handleListNavigation(
      event,
      onMove: _move,
      onHome: () => _selectRow(0),
      onEnd: () => _selectRow(_flat.length - 1),
      onActivate: _activate,
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = _flat.length;
    final step = _steps.lastOrNull?.step;
    final besideAvailable = _besideAvailable;
    // Said only while the highlighted row can do it, so the footer never
    // offers a key that would do what Enter does.
    final besideHint =
        besideAvailable && _flat.isNotEmpty && _flat[_selected].item.opensTab
        ? '${commandChordLabel('Enter')}  open to the side   ·   '
        : '';
    final rows = _rows(besideAvailable: besideAvailable);
    return QuickOpenFrame(
      // Wide enough for a path and its shortcut on one row, narrow enough that
      // the eye does not travel from a title to a chip across the window.
      maxWidth: 640,
      maxHeight: 480,
      onKey: _onKey,
      searchField: QuickOpenSearchField(
        controller: _controller,
        onChanged: _onQueryChanged,
        hintText:
            step?.hintText ?? 'Jump to a session, project, file or command',
        // Whatever the keymap binds today, so the hint is never a lie.
        shortcut: shellCommandLabel('quickOpen.show'),
        breadcrumb: [for (final frame in _steps) frame.step.title],
        onBreadcrumbTap: _back,
      ),
      body: _flat.isEmpty
          ? _Empty(query: _query, step: step)
          : ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.zero,
              itemCount: rows.length,
              itemBuilder: (context, index) => rows[index],
            ),
      footer: QuickOpenFooter(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Ends rather than overflows at a phone's width and a large text
            // scale, where the count alone is wider than its share.
            Flexible(
              child: Text(
                '$count result${count == 1 ? '' : 's'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (step == null && _walking != null && !_indexed) ...[
              const SizedBox(width: Insets.sm),
              const Flexible(
                child: Text(
                  '· indexing files…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (step == null && _conversationQuery.isNotEmpty)
              if (conversationCoverageNote(_hits.status) case final note?) ...[
                const SizedBox(width: Insets.sm),
                Flexible(
                  child: Tooltip(
                    message:
                        'Conversation search finds only what has been '
                        'indexed: $note.',
                    child: Text(
                      '· $note',
                      key: const ValueKey('quickOpen.conversationCoverage'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
          ],
        ),
        // The sigils are a hint, not a control: at a narrow width they
        // ellipsise rather than push the result count off the row.
        hint: step != null
            ? 'Enter  open   ·   ${besideHint}Backspace  back   ·   Esc  close'
            : _commandRows.isNotEmpty && _controller.text.trim().isNotEmpty
            ? 'Tab  complete   ·   Enter  run   ·   Esc  close'
            : '$besideHint'
                  r'>  commands   ·   #  sessions   ·   ?  conversations   ·   '
                  r'/  files   ·   $  snippets   ·   ~  presets',
      ),
    );
  }

  bool get _indexed {
    final root = ref.read(quickOpenFileRootProvider);
    return root != null && _index.isIndexed(root);
  }

  /// Headers and rows, flattened once per build so the list and the offset
  /// arithmetic cannot drift apart. [besideAvailable] gives each row that
  /// opens a tab its "open to the side" button.
  List<Widget> _rows({required bool besideAvailable}) {
    final besideTooltip = 'Open to the side (${commandChordLabel('Enter')})';
    final widgets = <Widget>[];
    var seen = 0;
    for (final section in _sections) {
      widgets.add(_SectionHeader(label: section.group.label));
      for (final result in section.results) {
        final index = seen++;
        final command = _commandRows[result.item.id];
        final dot = command?.dot;
        widgets.add(
          QuickOpenRow(
            icon: result.item.icon,
            leading: result.item.leading,
            title: result.item.title,
            titlePositions: result.titlePositions,
            subtitle: result.item.subtitle,
            detail: result.item.detail,
            // A command's detail is the chord that runs it (see
            // `QuickOpenSources._command`); every other group's is a note.
            detailIsShortcut: result.item.group == QuickOpenGroup.commands,
            enabled: command?.enabled ?? true,
            trailing: dot == null ? null : _SessionDotView(dot: dot),
            selected: index == _selected,
            onTap: () {
              setState(() => _selected = index);
              _pick(result.item);
            },
            besideTooltip: besideTooltip,
            onResume: switch (result.item.onResume) {
              final resume? => () {
                setState(() => _selected = index);
                resume();
              },
              null => null,
            },
            onOpenBeside: besideAvailable && result.item.opensTab
                ? () {
                    setState(() => _selected = index);
                    _pick(result.item, beside: true);
                  }
                : null,
          ),
        );
      }
    }
    return widgets;
  }
}
