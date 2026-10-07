import 'package:flutter/material.dart';

import '../app_icons.dart';
import '../design_tokens.dart';

/// Children a node shows before the rest wait behind "N more".
const int kJsonTreePage = 100;

/// A JSON (or YAML) value as a tree: objects and lists fold, the top levels
/// open. [value] is what `jsonDecode` answers — maps, lists and scalars.
class JsonTreeView extends StatelessWidget {
  const JsonTreeView(this.value, {this.openDepth = 1, super.key});

  final Object? value;

  /// How many levels start open.
  final int openDepth;

  @override
  Widget build(BuildContext context) =>
      _JsonNode(label: null, value: value, depth: 0, openDepth: openDepth);
}

class _JsonNode extends StatefulWidget {
  const _JsonNode({
    required this.label,
    required this.value,
    required this.depth,
    required this.openDepth,
  });

  final String? label;
  final Object? value;
  final int depth;
  final int openDepth;

  @override
  State<_JsonNode> createState() => _JsonNodeState();
}

class _JsonNodeState extends State<_JsonNode> {
  late bool _open = widget.depth < widget.openDepth;
  int _shown = kJsonTreePage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mono = MonoStyles.small.copyWith(color: scheme.onSurface);
    final key = widget.label == null
        ? null
        : TextSpan(
            text: '${widget.label}: ',
            style: mono.copyWith(color: scheme.primary),
          );
    final value = widget.value;
    final entries = switch (value) {
      final Map<Object?, Object?> map => [
        for (final e in map.entries) (e.key.toString(), e.value),
      ],
      final List<Object?> list => [
        for (var i = 0; i < list.length; i++) ('$i', list[i]),
      ],
      _ => null,
    };
    if (entries == null) {
      return Text.rich(
        TextSpan(children: [?key, _scalar(value, mono, scheme)]),
      );
    }
    final brackets = value is Map ? ('{', '}') : ('[', ']');
    final summary = entries.isEmpty
        ? '${brackets.$1}${brackets.$2}'
        : '${brackets.$1} ${entries.length} '
              '${value is Map ? 'key' : 'item'}${entries.length == 1 ? '' : 's'} '
              '${brackets.$2}';
    final head = InkWell(
      onTap: entries.isEmpty ? null : () => setState(() => _open = !_open),
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _open ? AppIcons.caretDown : AppIcons.caretRight,
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
    );
    if (!_open) return head;
    final shown = entries.take(_shown);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        head,
        Padding(
          padding: const EdgeInsets.only(left: Insets.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (label, child) in shown)
                _JsonNode(
                  label: label,
                  value: child,
                  depth: widget.depth + 1,
                  openDepth: widget.openDepth,
                ),
              if (entries.length > _shown)
                TextButton(
                  onPressed: () => setState(() => _shown += kJsonTreePage),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: theme.textTheme.labelSmall,
                  ),
                  child: Text('${entries.length - _shown} more'),
                ),
            ],
          ),
        ),
      ],
    );
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
