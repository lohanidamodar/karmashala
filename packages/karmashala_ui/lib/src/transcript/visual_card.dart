import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:karmashala_core/visuals.dart';

import '../app_icons.dart';
import '../charts/meters.dart';
import '../charts/series_chart.dart';
import '../charts/stat_tile.dart';
import '../design_tokens.dart';
import '../diagram/mermaid_model.dart';
import '../diagram/mermaid_view.dart';
import 'data_table_view.dart';
import 'fence_visuals.dart';
import 'json_tree.dart';

/// Builds an image visual whose bytes the server keeps; the app fetches them.
typedef VisualImageBuilder =
    Widget Function(BuildContext context, ImageVisual image);

/// The tallest an image visual is drawn; it keeps its aspect inside.
const double kVisualImageHeight = 360;

/// What an agent drew with `visualize`, in the same frame as a drawn fence:
/// its title, Source and Copy, and the visual — or, when it cannot be
/// drawn, why and its source.
class VisualCard extends StatelessWidget {
  const VisualCard({
    required this.kind,
    required this.data,
    this.title,
    this.image,
    super.key,
  });

  /// The kind's name, as the server keeps it.
  final String kind;
  final Object? data;
  final String? title;

  /// Draws an image the server holds; null shows its name only.
  final VisualImageBuilder? image;

  static IconData iconFor(VisualKind? kind) => switch (kind) {
    VisualKind.chart => AppIcons.chartBar,
    VisualKind.table => AppIcons.list,
    VisualKind.diagram => AppIcons.treeStructure,
    VisualKind.image => AppIcons.image,
    VisualKind.metric => AppIcons.squaresFour,
    VisualKind.progress => AppIcons.listChecks,
    VisualKind.tree || null => AppIcons.code,
    VisualKind.note => AppIcons.info,
  };

  @override
  Widget build(BuildContext context) {
    final visualKind = VisualKind.parse(kind);
    final scheme = Theme.of(context).colorScheme;
    // A note is a line in the conversation, not a card.
    if (visualKind == VisualKind.note) {
      try {
        return VisualNoteLine(parseNoteVisual(data).text);
      } on FormatException {
        // Drawn in the frame below, which says why.
      }
    }
    return VisualFrame(
      key: ValueKey('visual-card-$kind'),
      label: title ?? kind,
      leading: Icon(
        iconFor(visualKind),
        size: Chrome.iconSmall,
        color: scheme.onSurfaceVariant,
      ),
      source: const JsonEncoder.withIndent('  ').convert(data),
      draw: (context) {
        if (visualKind == null) {
          throw FormatException(
            '"$kind" visuals are not drawn by this version',
          );
        }
        return switch (parseVisualSpec(visualKind, data)) {
          final ChartVisual chart => SeriesChart(chart: chart),
          final TableVisual table => DataTableView(
            columns: table.columns,
            rows: table.rows,
          ),
          final DiagramVisual diagram => MermaidCanvas(
            parseMermaid(diagram.source),
          ),
          final ImageVisual picture => _ImageVisualView(picture, image),
          final MetricVisual metrics => _Metrics(metrics),
          final ProgressVisual progress => ProgressVisualView(progress),
          final TreeVisual tree => JsonTreeView(tree.value, openDepth: 2),
          final NoteVisual note => VisualNoteLine(note.text),
        };
      },
    );
  }
}

/// A [NoteVisual]: one muted line with a mark, quieter than any message.
class VisualNoteLine extends StatelessWidget {
  const VisualNoteLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      key: const ValueKey('visual-note'),
      children: [
        Icon(AppIcons.info, size: Chrome.iconSmall, color: muted),
        const SizedBox(width: Insets.sm),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics(this.metrics);

  final MetricVisual metrics;

  @override
  Widget build(BuildContext context) {
    String? delta(Metric m) => switch (m.delta) {
      null => null,
      final num n when n > 0 => '▲ ${formatChartValue(n.toDouble())}',
      final num n when n < 0 => '▼ ${formatChartValue(-n.toDouble())}',
      final num _ => '= 0',
      final Object words => '$words',
    };
    return StatTileGrid(
      key: const ValueKey('visual-metrics'),
      tiles: [
        for (final m in metrics.metrics)
          StatTile(
            label: m.label,
            value: switch (m.value) {
              null => null,
              final num n =>
                '${formatChartValue(n.toDouble())}'
                    '${m.unit == null ? '' : ' ${m.unit}'}',
              final Object v => '$v${m.unit == null ? '' : ' ${m.unit}'}',
            },
            caption: [?delta(m), ?m.caption].join('  '),
          ),
      ],
    );
  }
}

/// A [ProgressVisual]: its label and share, a bar in the colour of its
/// status, and its steps as a checklist.
class ProgressVisualView extends StatelessWidget {
  const ProgressVisualView(this.progress, {super.key});

  final ProgressVisual progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    Color colorOf(ProgressStatus s) => switch (s) {
      ProgressStatus.running => semantic.working,
      ProgressStatus.done => semantic.idle,
      ProgressStatus.failed => semantic.failure,
      ProgressStatus.paused => semantic.attention,
      ProgressStatus.pending || ProgressStatus.skipped => semantic.neutral,
    };
    IconData iconOf(ProgressStatus s) => switch (s) {
      ProgressStatus.done => AppIcons.checkCircle,
      ProgressStatus.failed => AppIcons.xCircle,
      ProgressStatus.running => AppIcons.playCircle,
      ProgressStatus.paused => AppIcons.pauseCircle,
      ProgressStatus.skipped => AppIcons.minusCircle,
      ProgressStatus.pending => AppIcons.circle,
    };
    final percent = (progress.fraction * 100).round();
    final amount = progress.max == 100
        ? '$percent%'
        : '${formatChartValue(progress.value)} of '
              '${formatChartValue(progress.max)}';
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Column(
      key: const ValueKey('visual-progress'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                progress.label ?? progress.status.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: Insets.sm),
            Text(
              amount,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        LinearMeter(
          value: progress.fraction,
          color: colorOf(progress.status),
          semanticsLabel:
              '${progress.label ?? 'Progress'}: $amount, ${progress.status.name}',
        ),
        for (final (label, status) in progress.steps)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Row(
              children: [
                Icon(
                  iconOf(status),
                  size: Chrome.iconSmall,
                  color: colorOf(status),
                  semanticLabel: status.name,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    label,
                    style: status == ProgressStatus.pending
                        ? muted
                        : theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ImageVisualView extends StatefulWidget {
  const _ImageVisualView(this.image, this.builder);

  final ImageVisual image;
  final VisualImageBuilder? builder;

  @override
  State<_ImageVisualView> createState() => _ImageVisualViewState();
}

class _ImageVisualViewState extends State<_ImageVisualView> {
  /// A web image is fetched only once asked: loading it tells that host the
  /// person is reading.
  bool _load = false;

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final url = image.url;
    Widget bounded(Widget child) => ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: kVisualImageHeight),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
    if (url != null) {
      if (!_load) {
        final host = Uri.tryParse(url)?.host ?? url;
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('visual-image-load'),
            onPressed: () => setState(() => _load = true),
            icon: const Icon(AppIcons.image, size: Chrome.iconSmall),
            label: Text('Load image from $host'),
          ),
        );
      }
      return bounded(
        Image.network(
          url,
          fit: BoxFit.contain,
          semanticLabel: image.alt,
          errorBuilder: (context, error, _) =>
              Text("Couldn't load $url", style: muted),
        ),
      );
    }
    final builder = widget.builder;
    final drawn = builder == null
        ? Text(image.fileName ?? 'image', style: muted)
        : bounded(builder(context, image));
    final alt = image.alt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        drawn,
        if (alt != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(alt, style: muted),
          ),
      ],
    );
  }
}
