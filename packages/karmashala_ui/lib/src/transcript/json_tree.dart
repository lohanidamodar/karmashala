import 'package:flutter/material.dart';
import 'package:karmashala_core/util.dart' show matchesSearch;

import '../app_icons.dart';
import '../compact_controls.dart';
import '../design_tokens.dart';
import '../search_field.dart';
import 'code_block.dart';

/// Children a node shows before the rest wait behind "N more".
const int kJsonTreePage = 100;

final _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

/// The JSONPath of [key] under [parent]: `$.items[2].name`, or
/// `$["odd key"]` for a key that is not an identifier.
String jsonChildPath(String parent, Object key) => switch (key) {
  final int i => '$parent[$i]',
  final String k when _identifier.hasMatch(k) => '$parent.$k',
  _ => '$parent["${'$key'.replaceAll('"', r'\"')}"]',
};

/// A JSON (or YAML) value as a tree: objects and lists fold, the top levels
/// open. Above it, a search that opens what matches, expand and collapse
/// all, and — for the row last tapped — its path, to copy. [value] is what
/// `jsonDecode` answers — maps, lists and scalars.
class JsonTreeView extends StatefulWidget {
  const JsonTreeView(
    this.value, {
    this.openDepth = 1,
    this.toolbar = true,
    super.key,
  });

  final Object? value;

  /// How many levels start open.
  final int openDepth;

  /// Whether the search and the expand controls are drawn.
  final bool toolbar;

  @override
  State<JsonTreeView> createState() => _JsonTreeViewState();
}

class _JsonTreeViewState extends State<JsonTreeView> {
  /// Folds the reader changed, by path; the rest follow [_allOpen] or depth.
  final _open = <String, bool>{};
  final _shown = <String, int>{};
  bool? _allOpen;
  String _query = '';
  String? _selected;

  /// Paths whose key or value holds [_query], and every container above them.
  Set<String> _matches = const {};
  Set<String> _onTheWay = const {};

  @override
  void didUpdateWidget(JsonTreeView old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _query.isNotEmpty) _search(_query);
  }

  void _search(String query) {
    final q = query.trim();
    final matches = <String>{};
    final onTheWay = <String>{};
    bool walk(Object? value, String path, String? key) {
      final hit =
          q.isNotEmpty &&
          (matchesSearch(q, key) ||
              (value is! Map && value is! List && matchesSearch(q, '$value')));
      if (hit) matches.add(path);
      var below = false;
      if (value is Map) {
        for (final e in value.entries) {
          if (walk(e.value, jsonChildPath(path, '${e.key}'), '${e.key}')) {
            below = true;
          }
        }
      } else if (value is List) {
        for (var i = 0; i < value.length; i++) {
          if (walk(value[i], jsonChildPath(path, i), null)) below = true;
        }
      }
      if (below) onTheWay.add(path);
      return hit || below;
    }

    if (q.isNotEmpty) walk(widget.value, r'$', null);
    setState(() {
      _query = query;
      _matches = matches;
      _onTheWay = onTheWay;
    });
  }

  void _all(bool open) => setState(() {
    _open.clear();
    _allOpen = open;
  });

  bool _isOpen(String path, int depth) =>
      _onTheWay.contains(path) ||
      (_open[path] ?? _allOpen ?? depth < widget.openDepth);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = <Widget>[];
    _rows(rows, label: null, value: widget.value, path: r'$', depth: 0);
    final selected = _selected;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.toolbar)
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: Row(
                children: [
                  Expanded(
                    child: SearchField(
                      key: const ValueKey('json-search'),
                      decoration: compactSearchDecoration(
                        hintText: 'Search keys and values',
                      ),
                      onChanged: _search,
                    ),
                  ),
                  if (_query.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: Insets.sm),
                      child: Text(
                        '${_matches.length} match'
                        '${_matches.length == 1 ? '' : 'es'}',
                        key: const ValueKey('json-match-count'),
                        style: muted,
                      ),
                    ),
                  IconButton(
                    key: const ValueKey('json-expand-all'),
                    tooltip: 'Expand all',
                    visualDensity: VisualDensity.compact,
                    iconSize: Chrome.iconAction,
                    onPressed: () => _all(true),
                    icon: const Icon(AppIcons.plusCircle),
                  ),
                  IconButton(
                    key: const ValueKey('json-collapse-all'),
                    tooltip: 'Collapse all',
                    visualDensity: VisualDensity.compact,
                    iconSize: Chrome.iconAction,
                    onPressed: () => _all(false),
                    icon: const Icon(AppIcons.minusCircle),
                  ),
                ],
              ),
            ),
          ),
        if (widget.toolbar && selected != null)
          SelectionContainer.disabled(
            child: Row(
              key: const ValueKey('json-selected-path'),
              children: [
                Expanded(
                  child: Text(
                    selected,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MonoStyles.small.copyWith(color: scheme.primary),
                  ),
                ),
                CopyTextButton(text: selected, tooltip: 'Copy path'),
              ],
            ),
          ),
        ...rows,
      ],
    );
  }

  void _rows(
    List<Widget> out, {
    required String? label,
    required Object? value,
    required String path,
    required int depth,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mono = MonoStyles.small.copyWith(color: scheme.onSurface);
    final highlight = _matches.contains(path)
        ? StateLayers.selected(scheme)
        : null;
    final key = label == null
        ? null
        : TextSpan(
            text: '$label: ',
            style: mono.copyWith(color: scheme.primary),
          );
    final entries = switch (value) {
      final Map<Object?, Object?> map => [
        for (final e in map.entries)
          (e.key.toString(), jsonChildPath(path, e.key.toString()), e.value),
      ],
      final List<Object?> list => [
        for (var i = 0; i < list.length; i++)
          ('$i', jsonChildPath(path, i), list[i]),
      ],
      _ => null,
    };
    final selected = _selected == path;
    Widget line(Widget child, {VoidCallback? onTap}) => Padding(
      padding: EdgeInsets.only(left: Insets.lg * depth),
      child: InkWell(
        key: ValueKey('json-row-$path'),
        onTap: () => setState(() {
          onTap?.call();
          _selected = path;
        }),
        borderRadius: BorderRadius.circular(Radii.sm),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? StateLayers.subtle(scheme) : highlight,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: child,
        ),
      ),
    );
    if (entries == null) {
      out.add(
        line(
          Padding(
            padding: const EdgeInsets.only(left: Chrome.iconSmall),
            child: Text.rich(
              TextSpan(children: [?key, _scalar(value, mono, scheme)]),
            ),
          ),
        ),
      );
      return;
    }
    final open = entries.isNotEmpty && _isOpen(path, depth);
    final brackets = value is Map ? ('{', '}') : ('[', ']');
    final summary = entries.isEmpty
        ? '${brackets.$1}${brackets.$2}'
        : '${brackets.$1} ${entries.length} '
              '${value is Map ? 'key' : 'item'}${entries.length == 1 ? '' : 's'} '
              '${brackets.$2}';
    out.add(
      line(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              open ? AppIcons.caretDown : AppIcons.caretRight,
              size: Chrome.iconSmall,
              color: entries.isEmpty
                  ? Colors.transparent
                  : scheme.onSurfaceVariant,
            ),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    ?key,
                    TextSpan(
                      text: summary,
                      style: mono.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        onTap: entries.isEmpty ? null : () => _open[path] = !open,
      ),
    );
    if (!open) return;
    final shown = _shown[path] ?? kJsonTreePage;
    for (final (childLabel, childPath, child) in entries.take(shown)) {
      _rows(
        out,
        label: childLabel,
        value: child,
        path: childPath,
        depth: depth + 1,
      );
    }
    if (entries.length > shown) {
      out.add(
        Padding(
          padding: EdgeInsets.only(left: Insets.lg * (depth + Insets.hair)),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () =>
                  setState(() => _shown[path] = shown + kJsonTreePage),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.labelSmall,
              ),
              child: Text('${entries.length - shown} more'),
            ),
          ),
        ),
      );
    }
  }

  TextSpan _scalar(Object? value, TextStyle mono, ColorScheme scheme) {
    final semantic = SemanticColors.of(context);
    return switch (value) {
      null => TextSpan(
        text: 'null',
        style: mono.copyWith(color: scheme.onSurfaceVariant),
      ),
      final String s => TextSpan(
        text: '"$s"',
        style: mono.copyWith(color: semantic.idle),
      ),
      final bool b => TextSpan(
        text: '$b',
        style: mono.copyWith(color: scheme.tertiary),
      ),
      _ => TextSpan(
        text: '$value',
        style: mono.copyWith(color: scheme.secondary),
      ),
    };
  }
}
