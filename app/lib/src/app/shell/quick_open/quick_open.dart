import 'dart:async';

import 'package:agent_cli/process.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_git/git.dart';

import '../../../features/cli_detection/data/conversation_search.dart';
import '../../../features/git/application/changes_providers.dart';
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

  // --- typed commands --------------------------------------------------------

  List<String> _readHistory() {
    try {
      return ref.read(typedCommandHistoryProvider).list();
    } catch (_) {
      // No store (a test harness without one) is no history, not a crash.
      return const [];
    }
  }

  void _recordHistory(String command) {
    try {
      ref.read(typedCommandHistoryProvider).record(command);
    } catch (_) {
      // Remembering is a convenience; failing to must not stop the command.
    }
  }

  CommandCatalog _catalogNow() => _catalog ??= readCommandCatalog(
    ProviderScope.containerOf(context, listen: false),
    notGitProjectIds: _notGit,
    conversationHits: (query) =>
        _hits.hitsFor(query, kCommandSuggestionLimit) ?? const [],
  );

  /// The rows a typed verb, or an empty box with history, puts above the
  /// search — or null, which leaves the palette exactly as it always was.
  QuickOpenSection? _commandSection() {
    _commandRows.clear();
    final text = _controller.text;
    if (text.trim().isEmpty) return _historySection();
    if (typedCommandVerbOf(text) == null && !typedCommandMayOpenSession(text)) {
      return null;
    }
    final typed = parseTypedCommand(text, _catalogNow());
    if (typed == null) return null;
    _askGitFor(typed);
    _readQuestionsFor(typed);

    final items = <QuickOpenItem>[];
    void add(String id, _CommandRow row, QuickOpenItem Function(String) make) {
      _commandRows[id] = row;
      items.add(make(id));
    }

    final error = typed.error;
    if (error != null) {
      add(
        'command/error',
        const _CommandRow(enabled: false),
        (id) => _commandItem(id, title: error, icon: AppIcons.warningCircle),
      );
    }
    final plan = typed.plan;
    if (plan != null) {
      add(
        'command/plan',
        _CommandRow(plan: plan, enabled: plan.runnable),
        (id) => _commandItem(
          id,
          title: plan.preview,
          subtitle: plan.refusal ?? plan.note ?? 'Enter to run',
          icon: plan.runnable ? AppIcons.playCircle : AppIcons.prohibit,
        ),
      );
    }
    for (final launch in typed.launches) {
      add(
        'command/launch/${launch.preview}',
        _CommandRow(plan: launch, enabled: launch.runnable),
        (id) => _commandItem(
          id,
          title: launch.preview,
          subtitle: launch.refusal ?? launch.note,
          icon: !launch.runnable
              ? AppIcons.prohibit
              : launch.action is OpenNewSessionDialogCommand
              ? AppIcons.chatCircleDots
              : AppIcons.playCircle,
        ),
      );
    }
    for (final suggestion in typed.suggestions) {
      add(
        'command/${suggestion.id}',
        _CommandRow(
          completion: suggestion.completion,
          enabled: suggestion.enabled,
          dot: suggestion.dot,
        ),
        (id) => _commandItem(
          id,
          title: suggestion.label,
          subtitle: suggestion.hint,
          detail: suggestion.disabledReason ?? suggestion.detail,
          icon: _iconFor(suggestion.kind),
        ),
      );
    }
    if (items.isEmpty) return null;
    return QuickOpenSection(
      group: QuickOpenGroup.command,
      results: [
        for (final item in items)
          QuickOpenResult(item: item, score: 0, titlePositions: const []),
      ],
    );
  }

  QuickOpenSection? _historySection() {
    if (_history.isEmpty) return null;
    final results = <QuickOpenResult>[];
    for (final (index, command)
        in _history.take(kTypedCommandHistoryShown).indexed) {
      final id = 'history/$index';
      _commandRows[id] = _CommandRow(history: command);
      results.add(
        QuickOpenResult(
          item: _commandItem(
            id,
            title: command,
            subtitle: 'Enter to run again · Tab to edit',
            icon: AppIcons.clockCounterClockwise,
            group: QuickOpenGroup.history,
          ),
          score: 0,
          titlePositions: const [],
        ),
      );
    }
    return QuickOpenSection(group: QuickOpenGroup.history, results: results);
  }

  QuickOpenItem _commandItem(
    String id, {
    required String title,
    required IconData icon,
    String? subtitle,
    String? detail,
    QuickOpenGroup group = QuickOpenGroup.command,
  }) => QuickOpenItem(
    id: id,
    group: group,
    title: title,
    subtitle: subtitle,
    detail: detail,
    icon: icon,
    onSelect: () => _pickCommandRow(id),
  );

  static IconData _iconFor(CommandArgKind kind) => switch (kind) {
    CommandArgKind.project => AppIcons.folder,
    CommandArgKind.agent => AppIcons.robot,
    CommandArgKind.session => AppIcons.chatCircle,
    CommandArgKind.environment || CommandArgKind.keyword => AppIcons.terminal,
    CommandArgKind.flag => AppIcons.gitBranch,
    CommandArgKind.option => AppIcons.listChecks,
  };

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

  _CommandRow? get _selectedCommandRow {
    if (_flat.isEmpty) return null;
    return _commandRows[_flat[_selected].item.id];
  }

  /// Enter, or a click, on a command row.
  void _pickCommandRow(String id) {
    final row = _commandRows[id];
    if (row == null || !row.enabled) return;
    if (row.completion case final completion?) {
      _accept(completion);
      return;
    }
    if (row.plan case final plan?) {
      _run(plan);
      return;
    }
    if (row.history case final history?) {
      // Run again only what still resolves; anything else goes back into the
      // box, where its preview says what changed.
      final plan = parseTypedCommand('$history ', _catalogNow())?.plan;
      if (plan != null && plan.runnable) {
        _run(plan);
      } else {
        _accept('$history ');
      }
    }
  }

  /// Tab: accept the highlighted suggestion, or the first usable one when the
  /// highlight is on the preview.
  bool _tabComplete() {
    final selected = _selectedCommandRow;
    if (selected == null) return false;
    if (selected.history case final history?) {
      _accept('$history ');
      return true;
    }
    if (selected.completion != null) {
      if (selected.enabled) _accept(selected.completion!);
      return true;
    }
    for (final row in _commandRows.values) {
      if (row.completion != null && row.enabled) {
        _accept(row.completion!);
        return true;
      }
    }
    return true;
  }

  void _accept(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onQueryChanged(text);
  }

  void _run(CommandPlan plan) {
    final action = plan.action;
    if (action == null || !plan.runnable) return;
    if (plan.canonical.isNotEmpty) _recordHistory(plan.canonical);
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final host = Navigator.of(context).context;
    final sources = _sources();
    sources.dismiss(() {
      if (action is OpenNewSessionDialogCommand) {
        final projectId = action.projectId;
        NewSessionDialog.show(
          host,
          destination: projectId == null
              ? null
              : SessionDestination(
                  projectId: projectId,
                  checkout: commandDefaultCheckout(container, projectId),
                ),
          firstPrompt: action.firstMessage,
        );
        return;
      }
      if (action is ResumeCommand) {
        // The session jump every session row makes.
        sources.focusSession(action.sessionId, imported: action.imported);
        return;
      }
      // While the palette's ref still reads: the runner's own work outlives it.
      if (action is PeekCommand ||
          (action is StartCommand && action.keepHere)) {
        openOverviewTab(ref);
      }
      final runner = TypedCommandRunner(
        container,
        say: (message) =>
            messenger?.showSnackBar(SnackBar(content: Text(message))),
      );
      if (plan.confirm case final confirm?) {
        unawaited(
          confirmTypedCommand(host, confirm).then((go) {
            if (go) runner.run(action);
          }),
        );
        return;
      }
      runner.run(action);
      // A terminal opened, or a session's ask, is drawn on the session page.
      if (action is OpenTerminalCommand || action is AnswerCommand) {
        sources.phone?.showWorkbench();
      }
    });
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
            Text('$count result${count == 1 ? '' : 's'}'),
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

/// The mouse's way in to [QuickOpen] — a search field that is really a button.
/// It shipped with no mouse affordance at all, which most people never found.
///
/// Drawn as board A2's field: the raised tone (`s1`), a 6px corner, 26px
/// tall, the magnifier, a muted placeholder that says what it reaches, and
/// the chord in a key pill at the end. Its width is the title bar's to give.
class QuickOpenButton extends StatelessWidget {
  const QuickOpenButton({super.key});

  static const _placeholder = 'Jump to a session, project, file or command';

  /// The board's field: 10px in from each end, 8px between glyph and words.
  static const _padX = 10.0;

  /// The inner width, at 1x text, below which the key pill steps aside: the
  /// glyph, a few words of the placeholder and a "Ctrl Shift K"-long pill.
  static const _pillRoom = 150.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final muted = scheme.onSurfaceVariant;
    // The keymap's chord, not a literal: a remapped Ctrl+K should say so here.
    final chord = shellChordLabel<OpenQuickOpenIntent>(
      where: (intent) => intent.query.isEmpty,
    );
    return Tooltip(
      message: [_placeholder, ?chord].join('  ·  '),
      child: Material(
        color: tones.raised,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: () => QuickOpen.show(context),
          child: Container(
            height: Chrome.control,
            padding: const EdgeInsets.symmetric(horizontal: _padX),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: tones.line),
            ),
            // The field's own width decides whether the pill fits; the title
            // bar sizes the field with a fixed width, never by intrinsics.
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  Icon(
                    AppIcons.magnifyingGlass,
                    size: Chrome.iconSmall,
                    color: muted,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      _placeholder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: TypeSizes.field,
                        color: muted,
                      ),
                    ),
                  ),
                  // The chord is decoration — the tooltip says it too — so it
                  // is what the field gives up first, whole rather than cut.
                  if (chord != null &&
                      constraints.maxWidth >=
                          WidthClass.scaleBreakpoint(
                            _pillRoom,
                            MediaQuery.textScalerOf(context),
                          )) ...[
                    const SizedBox(width: Insets.sm),
                    _KeyPill(chord),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A chord as a key — board A2's `.kbd`: 11px dim ink in a 4px-cornered
/// outline on the floating hairline, written with spaces ("Ctrl K") the way a
/// keycap row reads rather than the `+` a menu writes.
class _KeyPill extends StatelessWidget {
  const _KeyPill(this.chord);

  final String chord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      decoration: BoxDecoration(
        border: Border.all(color: SurfaceTones.of(context).floatingLine),
        borderRadius: BorderRadius.circular(Insets.xs),
      ),
      child: Text(
        chord.replaceAll('+', ' '),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: TypeSizes.caption,
          height: 16 / 11,
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A session's state on a command row, in the colours the rest of the app
/// gives the same states.
class _SessionDotView extends StatelessWidget {
  const _SessionDotView({required this.dot});

  final SessionDot dot;

  @override
  Widget build(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final (color, label) = switch (dot) {
      SessionDot.waiting => (semantic.attention, 'Waiting on you'),
      SessionDot.working => (semantic.working, 'Working'),
      SessionDot.idle => (semantic.idle, 'Idle'),
      SessionDot.stopped => (semantic.neutral, 'Not running'),
      SessionDot.unknown => (semantic.neutral, 'Status unknown'),
    };
    return Padding(
      padding: const EdgeInsets.only(right: Insets.sm),
      child: StatusDot(color: color, label: label),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Indented to the rows' own inset plus theirs, so the label stands over
    // the glyphs of the group it names.
    return Container(
      height: quickOpenHeaderHeightOf(context),
      alignment: Alignment.bottomLeft,
      padding: const EdgeInsets.only(
        left: Insets.xs + Insets.sm,
        bottom: Insets.xs,
      ),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall
            ?.merge(Chrome.groupLabel)
            .copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.query, this.step});

  final QuickOpenQuery query;

  /// The step the box is in, whose own rows are all that was searched.
  final QuickOpenStep? step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = query.only;
    final step = this.step;
    return Padding(
      padding: const EdgeInsets.all(Insets.xl),
      child: Text(
        step != null
            ? 'Nothing in ${step.title} matches.'
            : group == null
            ? 'Nothing matches.'
            : 'Nothing in ${group.label.toLowerCase()} matches.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
