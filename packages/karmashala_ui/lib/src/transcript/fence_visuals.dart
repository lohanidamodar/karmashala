import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:karmashala_core/visuals.dart';

import '../app_icons.dart';
import '../charts/series_chart.dart';
import '../design_tokens.dart';
import 'ansi_text.dart';
import 'code_block.dart';
import 'diff_text.dart';
import 'json_tree.dart';

/// What a fence's language draws as, rather than as code.
enum FenceVisual { chart, math, diff, json, ansi }

/// The visual for a fence written in [language] holding [source], or null for
/// plain code. Code that carries escape sequences is drawn as ANSI whatever
/// its fence says.
FenceVisual? fenceVisualFor(String? language, String source) {
  switch (language?.trim().toLowerCase()) {
    case 'chart':
      return FenceVisual.chart;
    case 'math' || 'latex' || 'tex' || 'katex':
      return FenceVisual.math;
    case 'diff' || 'patch':
      return FenceVisual.diff;
    case 'json' || 'jsonc':
      return FenceVisual.json;
    case 'ansi':
      return FenceVisual.ansi;
  }
  return hasAnsi(source) ? FenceVisual.ansi : null;
}

/// A fence drawn as what it describes — a chart, an equation, a diff, a JSON
/// tree, coloured output — with Source and Copy above it. Anything that cannot
/// be drawn shows its source and why.
class VisualFenceBlock extends StatefulWidget {
  const VisualFenceBlock({
    required this.visual,
    required this.source,
    this.language,
    super.key,
  });

  final FenceVisual visual;
  final String source;
  final String? language;

  @override
  State<VisualFenceBlock> createState() => _VisualFenceBlockState();
}

class _VisualFenceBlockState extends State<VisualFenceBlock> {
  bool _wrap = false;

  @override
  Widget build(BuildContext context) {
    final source = widget.visual == FenceVisual.ansi
        ? stripAnsi(widget.source)
        : widget.source;
    return VisualFrame(
      key: ValueKey('fence-${widget.visual.name}'),
      label: widget.language ?? widget.visual.name,
      source: source,
      actions: [
        if (widget.visual == FenceVisual.diff)
          TextButton(
            key: const ValueKey('diff-wrap'),
            onPressed: () => setState(() => _wrap = !_wrap),
            style: VisualFrame.actionStyle(context),
            child: Text(_wrap ? 'No wrap' : 'Wrap'),
          ),
      ],
      draw: _drawn,
    );
  }

  Widget _drawn(BuildContext context) => switch (widget.visual) {
    FenceVisual.json => JsonTreeView(jsonDecode(widget.source), openDepth: 2),
    FenceVisual.ansi => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: AnsiText(widget.source, softWrap: false),
    ),
    FenceVisual.diff => DiffText(widget.source, wrap: _wrap),
    FenceVisual.math => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Math.tex(
        widget.source.trim(),
        mathStyle: MathStyle.display,
        textStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        onErrorFallback: (error) =>
            VisualFrame.failure(context, error.message, widget.source),
      ),
    ),
    FenceVisual.chart => ChartFence(spec: parseChartSpec(widget.source)),
  };
}

/// The box every drawn block sits in: a [label], the block's own [actions],
/// Source and Copy, and what [draw] builds — or, when it throws, why and the
/// source.
class VisualFrame extends StatefulWidget {
  const VisualFrame({
    required this.label,
    required this.source,
    required this.draw,
    this.actions = const [],
    this.leading,
    super.key,
  });

  final String label;

  /// What Source shows and Copy copies.
  final String source;
  final WidgetBuilder draw;
  final List<Widget> actions;

  /// Drawn before [label], as an icon saying what kind of block it is.
  final Widget? leading;

  /// How a header action looks, so a block's own matches Source.
  static ButtonStyle actionStyle(BuildContext context) => TextButton.styleFrom(
    visualDensity: VisualDensity.compact,
    textStyle: Theme.of(context).textTheme.labelSmall,
  );

  static Widget sourceText(BuildContext context, String source) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          source,
          style: MonoStyles.label.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      );

  /// Why [source] could not be drawn, above it.
  static Widget failure(BuildContext context, String reason, String source) {
    final failure = SemanticColors.of(context).failure;
    return Column(
      key: const ValueKey('fence-failed'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              AppIcons.warningCircle,
              size: Chrome.iconSmall,
              color: failure,
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(
                "Couldn't draw this: $reason",
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: failure),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        sourceText(context, source),
      ],
    );
  }

  @override
  State<VisualFrame> createState() => _VisualFrameState();
}

class _VisualFrameState extends State<VisualFrame> {
  bool _source = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    Widget body;
    if (_source) {
      body = VisualFrame.sourceText(context, widget.source);
    } else {
      try {
        body = widget.draw(context);
      } on Object catch (error) {
        final reason = error is FormatException ? error.message : '$error';
        body = VisualFrame.failure(context, reason, widget.source);
      }
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.only(left: Insets.sm),
              child: Row(
                children: [
                  if (widget.leading case final leading?) ...[
                    leading,
                    const SizedBox(width: Insets.xs),
                  ],
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                  if (!_source) ...widget.actions,
                  TextButton(
                    key: const ValueKey('fence-source'),
                    onPressed: () => setState(() => _source = !_source),
                    style: VisualFrame.actionStyle(context),
                    child: Text(_source ? 'Visual' : 'Source'),
                  ),
                  CopyTextButton(text: widget.source, tooltip: 'Copy source'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.sm,
              0,
              Insets.sm,
              Insets.sm,
            ),
            child: body,
          ),
        ],
      ),
    );
  }
}

/// A `chart` fence's source as a [ChartVisual] — the shape `visualize` takes;
/// throws a [FormatException] saying what is wrong.
ChartVisual parseChartSpec(String source) =>
    parseChartVisual(jsonDecode(source));

/// A [ChartVisual] under its title.
class ChartFence extends StatelessWidget {
  const ChartFence({required this.spec, this.showTitle = true, super.key});

  final ChartVisual spec;

  /// False where a frame above already names it.
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final title = showTitle ? spec.title : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.xs),
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
        SeriesChart(chart: spec),
      ],
    );
  }
}
