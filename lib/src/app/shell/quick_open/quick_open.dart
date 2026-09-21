import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/cli_detection/application/cli_detection_providers.dart';
import '../../../features/cli_detection/data/conversation_index_dao.dart';
import '../../../features/git/application/changes_providers.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'quick_open_cache.dart';
import 'quick_open_item.dart';
import 'quick_open_list.dart';
import 'quick_open_sources.dart';
import 'repo_file_index.dart';

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

  List<QuickOpenSection> _sections = const [];
  List<QuickOpenResult> _flat = const [];
  int _selected = 0;

  /// Held rather than re-read, because [dispose] needs it after `ref` is no
  /// longer somewhere to read providers from.
  late final RepoFileIndex _index;

  /// The root of the walk currently being waited on, or `null`. Also what
  /// [dispose] cancels.
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

  /// Reads what the running sessions appended since their last index, then
  /// searches again if that found anything — so today's turns are findable.
  void _catchUpConversations() {
    ref.read(sessionSearchServiceProvider).catchUp().then((changed) {
      if (!mounted || changed == 0) return;
      setState(() {
        _searchConversations(force: true);
        _rerank();
      });
    });
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
      // *after* quick open has popped, and a route on its way out is no host.
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

  /// Runs the conversation search for the query as typed: a ranked page from
  /// the index, and no debounce — lagging the list would read as a bug.
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
    final List<ConversationHit> hits = ref
        .read(sessionSearchServiceProvider)
        .search(text, limit: kQuickOpenConversationLimit)
        .hits;
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

  /// Starts the repository walk the first time the user types, and again when
  /// what is cached is stale. Never awaited: the cached list is already up.
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

  void _activate() {
    if (_flat.isEmpty) return;
    _flat[_selected].item.onSelect();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) => handleListNavigation(
    event,
    onMove: _move,
    onHome: () => _selectRow(0),
    onEnd: () => _selectRow(_flat.length - 1),
    onActivate: _activate,
  );

  @override
  Widget build(BuildContext context) {
    final count = _flat.length;
    return QuickOpenFrame(
      maxWidth: 720,
      maxHeight: 520,
      onKey: _onKey,
      searchField: QuickOpenSearchField(
        controller: _controller,
        onChanged: _onQueryChanged,
        hintText: 'Go to a session, file or branch — or search what was said',
      ),
      body: _flat.isEmpty
          ? _Empty(query: _query)
          : ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.zero,
              itemCount: _rows.length,
              itemBuilder: (context, index) => _rows[index],
            ),
      footer: QuickOpenFooter(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$count result${count == 1 ? '' : 's'}'),
            if (_walking != null && !_indexed) ...[
              const SizedBox(width: Insets.sm),
              const Text('· indexing files…'),
            ],
          ],
        ),
        // The sigils are a hint, not a control: at a narrow width they
        // ellipsise rather than push the result count off the row.
        hint:
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

/// The mouse's way in to [QuickOpen] — a search field that is really a button.
/// It shipped with no mouse affordance at all, which most people never found.
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
              height: Chrome.control,
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
                  // is what the field gives up first, shortening before it goes.
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
                          fontFamilyFallback: kMonoFallback,
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
      height: quickOpenHeaderHeightOf(context),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: Insets.md, top: Insets.xs),
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
