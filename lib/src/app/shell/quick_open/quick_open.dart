import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/git/application/changes_providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/design_tokens.dart';
import 'quick_open_cache.dart';
import 'quick_open_item.dart';
import 'quick_open_sources.dart';
import 'repo_file_index.dart';

/// Row geometry. Fixed so the list can be scrolled to an arbitrary selection
/// without waiting for it to be laid out — a keyboard-driven list that can only
/// reveal rows it has already built is a list that jumps.
const _rowHeight = 42.0;
const _headerHeight = 24.0;

/// One search box over the whole workspace: projects, repositories, sessions,
/// the selected repository's files, its branches, the GitHub work already
/// loaded, agents, and the commands the palette always had.
///
/// **Three rules it is built around.**
///
/// 1. *Nothing here fetches.* Opening quick open must never start a `gh` call,
///    a `git status` or a PTY. Branches, pull requests and issues come from
///    [QuickOpenCache] — data some other surface already loaded — and the file
///    index is a bounded local walk that starts only once the user types.
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
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (_) => QuickOpen(initialQuery: initialQuery),
      );

  @override
  ConsumerState<QuickOpen> createState() => _QuickOpenState();
}

class _QuickOpenState extends ConsumerState<QuickOpen> {
  late final TextEditingController _controller;
  final _scroll = ScrollController();

  List<QuickOpenItem> _items = const [];
  List<QuickOpenSection> _sections = const [];
  List<QuickOpenResult> _flat = const [];
  int _selected = 0;

  /// The root whose walk was asked for, so it is asked for once.
  String? _indexing;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
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

  void _rebuildItems() {
    final root = ref.read(quickOpenFileRootProvider);
    final index = ref.read(repoFileIndexProvider);
    final navigator = Navigator.of(context);
    _items =
        QuickOpenSources(
          ref: ref,
          // The navigator's own context, not this dialog's: an item's action
          // runs *after* quick open has popped itself, and a route on its way
          // out is not somewhere to open the next dialog or show a snack bar
          // from.
          context: navigator.context,
          dismiss: (action) {
            navigator.pop();
            action();
          },
        ).build(
          files: root == null ? const [] : index.cached(root),
          changedPaths: _changedPaths(),
        );
    _rerank();
  }

  void _rerank() {
    final query = _query;
    _sections = rankQuickOpen(query, _items);
    _flat = [
      for (final section in _sections)
        for (final result in section.results) result,
    ];
    if (_selected >= _flat.length) _selected = _flat.isEmpty ? 0 : 0;
  }

  /// Starts the repository walk the first time the user types, and refreshes
  /// the list in place when it lands. Never awaited by the UI.
  void _ensureFileIndex() {
    final root = ref.read(quickOpenFileRootProvider);
    if (root == null || _indexing == root) return;
    final index = ref.read(repoFileIndexProvider);
    if (index.isIndexed(root)) return;
    _indexing = root;
    index.index(root).then((_) {
      if (!mounted) return;
      setState(_rebuildItems);
    });
  }

  void _onQueryChanged(String _) {
    if (!_query.isEmpty) _ensureFileIndex();
    setState(() {
      _selected = 0;
      _rerank();
    });
    _revealSelected();
  }

  void _move(int delta) {
    if (_flat.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, _flat.length - 1);
    });
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
        offset += _rowHeight;
        seen++;
      }
    }
    return offset;
  }

  void _revealSelected() {
    if (!_scroll.hasClients || _flat.isEmpty) return;
    final top = _offsetOf(_selected);
    final bottom = top + _rowHeight;
    final view = _scroll.position.viewportDimension;
    final current = _scroll.offset;
    final target = bottom > current + view
        ? bottom - view
        : (top < current ? top : null);
    if (target == null) return;
    _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
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
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 72, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 520),
        child: Focus(
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SearchField(controller: _controller, onChanged: _onQueryChanged),
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
                indexing: _indexing != null && !_indexed,
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
    return root != null && ref.read(repoFileIndexProvider).isIndexed(root);
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
          _ResultRow(
            result: result,
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

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Insets.sm),
    child: TextField(
      controller: controller,
      autofocus: true,
      decoration: const InputDecoration(
        prefixIcon: Icon(AppIcons.magnifyingGlass, size: 18),
        hintText: 'Go to a session, file, branch, PR — or run a command',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: onChanged,
    ),
  );
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

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.result,
    required this.selected,
    required this.onTap,
  });

  final QuickOpenResult result;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = result.item;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: _rowHeight,
        // Selection is a wash plus a rule, not a filled bar: the row has to
        // stay readable and the accent is the only colour in the palette.
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: Insets.md),
        child: Row(
          children: [
            Icon(item.icon, size: Chrome.icon, color: foreground),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Highlighted(
                    text: item.title,
                    positions: result.titlePositions,
                    style: theme.textTheme.bodyMedium!,
                    accent: scheme.primary,
                  ),
                  if (item.subtitle != null)
                    Text(
                      item.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (item.detail != null) ...[
              const SizedBox(width: Insets.sm),
              Text(
                item.detail!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The title with the matched characters emphasised, so a fuzzy hit explains
/// itself instead of looking like a mistake.
class _Highlighted extends StatelessWidget {
  const _Highlighted({
    required this.text,
    required this.positions,
    required this.style,
    required this.accent,
  });

  final String text;
  final List<int> positions;
  final TextStyle style;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    if (positions.isEmpty) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final marked = positions.toSet();
    final spans = <TextSpan>[];
    final buffer = StringBuffer();
    bool? runIsMatch;
    void flush() {
      if (buffer.isEmpty) return;
      spans.add(
        TextSpan(
          text: buffer.toString(),
          style: runIsMatch == true
              ? style.copyWith(color: accent, fontWeight: FontWeight.w700)
              : style,
        ),
      );
      buffer.clear();
    }

    for (var i = 0; i < text.length; i++) {
      final isMatch = marked.contains(i);
      if (runIsMatch != isMatch) {
        flush();
        runIsMatch = isMatch;
      }
      buffer.write(text[i]);
    }
    flush();
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
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
                '>  commands   ·   #  sessions   ·   /  files',
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
