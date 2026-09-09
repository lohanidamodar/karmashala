import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/cli_detection/application/cli_detection_providers.dart';
import '../../../features/cli_detection/data/conversation_index_dao.dart';
import '../../../features/git/application/changes_providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/design_tokens.dart';
import 'quick_open_cache.dart';
import 'quick_open_item.dart';
import 'quick_open_list.dart';
import 'quick_open_sources.dart';
import 'repo_file_index.dart';

/// Bumped when something outside the widget tree asks for quick open — today
/// the global hotkey, which summons the window with the palette already up.
///
/// A provider rather than a direct call because `SystemIntegrationService` lives
/// outside the tree and has no `BuildContext`; the shell listens and opens the
/// dialog with one it actually has. Same shape as `windowRaiseRequestProvider`:
/// the counter's value means nothing, only that it moved.
class QuickOpenRequest extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final quickOpenRequestProvider = NotifierProvider<QuickOpenRequest, int>(
  QuickOpenRequest.new,
);

/// A section header's height. The rows themselves are [quickOpenRowHeight],
/// shared with every other filtered list in the shell.
const _headerHeight = 24.0;

/// One search box over the whole workspace: projects, repositories, sessions,
/// **what was said inside them**, the selected repository's files, its
/// branches, the GitHub work already loaded, agents, and the commands the
/// palette always had.
///
/// **Three rules it is built around.**
///
/// 1. *Nothing here fetches.* Opening quick open must never start a `gh` call,
///    a `git status` or a PTY. Branches, pull requests and issues come from
///    [QuickOpenCache] — data some other surface already loaded — and the file
///    index is a bounded local walk that starts only once the user types. The
///    conversation search reads an index this app already built on its own
///    triggers (`ConversationIndexer`); it opens no transcript and walks no
///    store, which is the difference between a search and a grep.
/// 2. *Ranked across kinds, grouped for reading.* Sections are ordered by their
///    best match, so the group you meant is at the top; see [rankQuickOpen].
/// 3. *Enter opens the exact thing*, through whatever already owns that jump.
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

  /// The conversation rows for the query as typed, and the query they were
  /// built for.
  ///
  /// Held apart from [_items] because they are the only source that depends on
  /// the query: everything else is built once and re-ranked.
  List<QuickOpenItem> _conversationItems = const [];
  String _conversationQuery = '';

  List<QuickOpenSection> _sections = const [];
  List<QuickOpenResult> _flat = const [];
  int _selected = 0;

  /// Held rather than re-read, because [dispose] needs it after `ref` is no
  /// longer somewhere to read providers from.
  late final RepoFileIndex _index;

  /// The root of the walk currently being waited on, or `null`. Also what
  /// [dispose] cancels: a walk nobody is looking at any more should not go on
  /// spending the UI isolate.
  String? _walking;

  StreamSubscription<String>? _indexChanges;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    _index = ref.read(repoFileIndexProvider);
    // The index refreshes itself behind the dialog — a watcher fires, an agent
    // turn ends — so the open palette has to be told, not just asked once.
    _indexChanges = _index.changes.listen(_onIndexChanged);
    // Take a copy of whatever the app has already loaded about this repository.
    // Reading is free; the providers this reads from are never created here.
    ref
        .read(quickOpenCacheProvider.notifier)
        .harvest(
          ProviderScope.containerOf(context, listen: false),
          ref.read(selectedRepositoryIdProvider),
        );
    _rebuildItems();
  }

  @override
  void dispose() {
    _indexChanges?.cancel();
    final walking = _walking;
    if (walking != null) _index.cancel(walking);
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
      // *after* quick open has popped itself, and a route on its way out is
      // not somewhere to open the next dialog or show a snack bar from.
      context: navigator.context,
      dismiss: (action) {
        navigator.pop();
        action();
      },
    );
  }

  void _rebuildItems() {
    final root = ref.read(quickOpenFileRootProvider);
    _items = _sources().build(
      files: root == null ? const [] : _index.cached(root),
      changedPaths: _changedPaths(),
    );
    _rerank();
  }

  /// Runs the conversation search for the query as typed.
  ///
  /// One indexed FTS5 statement, bounded by `kConversationSearchLimit`, on the
  /// synchronous connection like every other read in this app — and skipped
  /// entirely for a query it has already run, and for a sigil that means
  /// another group. No debounce: the palette's other sources re-rank on the
  /// keystroke, and a search lagging the list it shares a window with would
  /// read as a bug.
  void _searchConversations() {
    final query = _query;
    final only = query.only;
    final text = only == null || only == QuickOpenGroup.conversations
        ? query.text
        : '';
    if (text == _conversationQuery) return;
    _conversationQuery = text;
    if (text.isEmpty) {
      _conversationItems = const [];
      return;
    }
    final List<ConversationHit> hits = ref
        .read(conversationIndexDaoProvider)
        .search(text);
    _conversationItems = _sources().conversations(hits, text);
  }

  void _rerank() {
    final query = _query;
    _sections = rankQuickOpen(query, [..._items, ..._conversationItems]);
    _flat = [
      for (final section in _sections)
        for (final result in section.results) result,
    ];
    if (_selected >= _flat.length) _selected = _flat.isEmpty ? 0 : 0;
  }

  /// Starts the repository walk the first time the user types, and again
  /// whenever what is cached has gone stale. Never awaited by the UI: the
  /// cached list is already on screen and the walk refreshes it in place.
  void _ensureFileIndex() {
    final root = ref.read(quickOpenFileRootProvider);
    final walking = _walking;
    // The selected repository changed under an open palette. The walk in
    // flight is for a tree nobody is searching any more.
    if (walking != null && walking != root) {
      _index.cancel(walking);
      _walking = null;
    }
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
  void _onIndexChanged(String root) {
    if (!mounted || root != ref.read(quickOpenFileRootProvider)) return;
    if (!_query.isEmpty) _ensureFileIndex();
    setState(_rebuildItems);
  }

  void _onQueryChanged(String _) {
    if (!_query.isEmpty) _ensureFileIndex();
    setState(() {
      _selected = 0;
      _searchConversations();
      _rerank();
    });
    _revealSelectedAfterLayout();
  }

  void _move(int delta) => _selectRow(_selected + delta);

  /// Moves the highlight to [index], clamped. Deliberately does **not** wrap:
  /// a list that jumps from its last row to its first on one more press is a
  /// list you cannot hold the arrow key down on.
  void _selectRow(int index) {
    if (_flat.isEmpty) return;
    setState(() => _selected = index.clamp(0, _flat.length - 1));
    _revealSelected();
  }

  /// The scroll offset of the row for result [index], counting the headers
  /// above it.
  double _offsetOf(int index) {
    var offset = 0.0;
    var seen = 0;
    for (final section in _sections) {
      offset += _headerHeight;
      for (var i = 0; i < section.results.length; i++) {
        if (seen == index) return offset;
        offset += quickOpenRowHeightOf(context);
        seen++;
      }
    }
    return offset;
  }

  /// Scrolls the highlighted row into view.
  ///
  /// Deferred to after the frame when the list itself has just changed: the
  /// scroll position's extents still describe the *previous* list until it has
  /// been laid out, and clamping a target against those is how a keyboard-
  /// driven list ends up scrolled somewhere nobody asked for.
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

  void _activate() {
    if (_flat.isEmpty) return;
    _flat[_selected].item.onSelect();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final control = HardwareKeyboard.instance.isControlPressed;
    final key = event.logicalKey;

    // Ctrl+N/Ctrl+P move as well as the arrows: this is a list that is driven
    // while both hands are on the home row.
    if (key == LogicalKeyboardKey.arrowDown ||
        (control && key == LogicalKeyboardKey.keyN)) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        (control && key == LogicalKeyboardKey.keyP)) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _move(8);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _move(-8);
      return KeyEventResult.handled;
    }
    // Home/End drive the list, not the caret. The query is a short phrase in a
    // single-line box — there is nothing in it worth jumping to — and the ends
    // of a result list are somewhere people genuinely want to reach.
    if (key == LogicalKeyboardKey.home) {
      _selectRow(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _selectRow(_flat.length - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _activate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 72 is a desktop-sized gap, and this palette opens in a window that can be
    // 560 tall — where it is an eighth of the height held empty above a list
    // that is the whole point. At 720x560 with text at 1.3x the fixed rows
    // (field, two dividers, footer) then no longer fit and the column
    // overflowed by 5px. Scaled to the window it keeps the same look on a
    // desktop and gives the list back the room on a small one.
    final height = MediaQuery.sizeOf(context).height;
    final topInset = (height * 0.09).clamp(16.0, 72.0);
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: EdgeInsets.only(top: topInset, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 520),
        child: Focus(
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              QuickOpenSearchField(
                controller: _controller,
                onChanged: _onQueryChanged,
                hintText:
                    'Go to a session, file or branch — or search what was '
                    'said',
              ),
              const Divider(height: 1),
              Flexible(
                child: _flat.isEmpty
                    ? _Empty(query: _query)
                    : ListView.builder(
                        controller: _scroll,
                        padding: EdgeInsets.zero,
                        itemCount: _rows.length,
                        itemBuilder: (context, index) => _rows[index],
                      ),
              ),
              const Divider(height: 1),
              _Footer(
                count: _flat.length,
                indexing: _walking != null && !_indexed,
                colour: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _indexed {
    final root = ref.read(quickOpenFileRootProvider);
    return root != null && _index.isIndexed(root);
  }

  /// Headers and rows, flattened once per build so the list and the offset
  /// arithmetic cannot drift apart.
  List<Widget> get _rows {
    final widgets = <Widget>[];
    var seen = 0;
    for (final section in _sections) {
      widgets.add(_SectionHeader(label: section.group.label));
      for (final result in section.results) {
        final index = seen++;
        widgets.add(
          QuickOpenRow(
            icon: result.item.icon,
            title: result.item.title,
            titlePositions: result.titlePositions,
            subtitle: result.item.subtitle,
            detail: result.item.detail,
            selected: index == _selected,
            onTap: () {
              setState(() => _selected = index);
              result.item.onSelect();
            },
          ),
        );
      }
    }
    return widgets;
  }
}

/// The mouse's way in to [QuickOpen] — a search field that is really a button,
/// sitting beside the menu bar the way a desktop app's command centre does.
///
/// Loop 50 shipped quick open with **no** mouse affordance: no button, no menu
/// item, nothing to click. A keyboard-only entrance to the app's main way of
/// finding things is an entrance most people never find.
class QuickOpenButton extends StatelessWidget {
  const QuickOpenButton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Tooltip(
      message: 'Search sessions, files, branches and commands  ·  Ctrl+K',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Material(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () => QuickOpen.show(context),
            child: Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    AppIcons.magnifyingGlass,
                    size: Chrome.iconSmall,
                    color: muted,
                  ),
                  const SizedBox(width: Insets.sm),
                  Flexible(
                    child: Text(
                      'Go to…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  ),
                  // The chord is decoration — the tooltip says it too — so it
                  // is what the field gives up first. Flexible rather than
                  // dropped outright so it shortens before it goes, and so the
                  // row can never overflow whatever the chrome beside it takes.
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: Insets.md),
                      child: Text(
                        'Ctrl+K',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: muted,
                          fontFamily: kMonoFamily,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: _headerHeight,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: Insets.md, top: Insets.xs),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.query});

  final QuickOpenQuery query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = query.only;
    return Padding(
      padding: const EdgeInsets.all(Insets.xl),
      child: Text(
        group == null
            ? 'Nothing matches.'
            : 'Nothing in ${group.label.toLowerCase()} matches.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.count,
    required this.indexing,
    required this.colour,
  });

  final int count;
  final bool indexing;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: Chrome.statusBar + Insets.xs,
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      alignment: Alignment.centerLeft,
      child: DefaultTextStyle.merge(
        style: theme.textTheme.labelSmall!.copyWith(color: colour),
        child: Row(
          children: [
            Text('$count result${count == 1 ? '' : 's'}'),
            if (indexing) ...[
              const SizedBox(width: Insets.sm),
              const Text('· indexing files…'),
            ],
            const Spacer(),
            // The sigils are a hint, not a control: at a narrow width they
            // ellipsise rather than push the result count off the row.
            const Flexible(
              child: Text(
                r'>  commands   ·   #  sessions   ·   ?  conversations   ·   '
                r'/  files   ·   $  snippets   ·   ~  presets',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
