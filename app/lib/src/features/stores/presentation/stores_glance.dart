import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../application/store_glance.dart';

/// How wide the glance's rating sparkline is drawn, and how tall.
const double kGlanceSparklineWidth = 72;
const double kGlanceSparklineHeight = 18;

/// **The Stores glance** for the dashboard: how many apps need attention and
/// the first of them, the newest release change, and the rating's month.
/// Read-only; a tap opens the Stores tab through [onOpen].
class StoresGlance extends ConsumerWidget {
  const StoresGlance({required this.onOpen, super.key});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(storesGlanceProvider);
    final now = ref.watch(clockProvider).nowUtc();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final lines = <Widget>[];
    final spoken = <String>['Stores'];
    if (data == null) {
      const text = 'No store connected';
      lines.add(Text(text, style: muted));
      spoken.add(text);
    } else {
      final attention = data.attention == 0
          ? 'Nothing needs you'
          : '${data.attention} need${data.attention == 1 ? 's' : ''} '
                'attention · ${data.firstAttention}';
      spoken.add(attention);
      lines.add(
        Row(
          children: [
            Icon(
              data.attention == 0 ? AppIcons.checkCircle : AppIcons.warning,
              size: Chrome.iconAction,
              color: data.attention == 0 ? semantic.idle : semantic.failure,
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(
                attention,
                key: const ValueKey('stores-glance-attention'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
      if (data.newestRelease case final release?) {
        final text =
            '${release.text} · ${compactAge(now.difference(release.at))}';
        spoken.add('${release.app}: $text');
        lines.add(
          Tooltip(
            message: release.app,
            child: Text(
              text,
              key: const ValueKey('stores-glance-release'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
        );
      }
      if (data.rating case final rating?) {
        spoken.add('${data.ratingApp} rated ${rating.toStringAsFixed(1)}');
        lines.add(
          Row(
            children: [
              Icon(
                AppIcons.star,
                size: Chrome.iconAction,
                color: semantic.attention,
              ),
              const SizedBox(width: Insets.xxs),
              Text(rating.toStringAsFixed(1), style: muted),
              if (data.ratingTrend.length > 1) ...[
                const SizedBox(width: Insets.sm),
                Sparkline(
                  key: const ValueKey('stores-glance-sparkline'),
                  values: data.ratingTrend,
                  color: scheme.primary,
                  minValue: 1,
                  maxValue: 5,
                  width: kGlanceSparklineWidth,
                  height: kGlanceSparklineHeight,
                  area: false,
                  semanticsLabel: 'Rating over the last 30 days',
                ),
              ],
              const SizedBox(width: Insets.xs),
              Flexible(
                child: Text(
                  data.ratingApp ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ),
            ],
          ),
        );
      }
    }

    return Semantics(
      button: true,
      label: spoken.join(', '),
      child: ExcludeSemantics(
        child: Material(
          key: const ValueKey('stores-glance'),
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.all(Insets.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        AppIcons.package,
                        size: Chrome.iconTitle,
                        color: scheme.tertiary,
                      ),
                      const SizedBox(width: Insets.sm),
                      Text('Stores', style: theme.textTheme.titleSmall),
                    ],
                  ),
                  for (final line in lines) ...[
                    const SizedBox(height: Insets.xs),
                    line,
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
