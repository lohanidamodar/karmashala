import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/workbench_tabs.dart' show openStoresTab;
import '../../../app/widgets/dashboard_glance.dart';
import '../../../core/util/clock_provider.dart';
import '../application/store_glance.dart';

/// How wide the glance's rating sparkline is drawn, and how tall.
const double kGlanceSparklineWidth = 72;
const double kGlanceSparklineHeight = 18;

/// **The Stores glance** for the dashboard: the apps needing attention, the
/// newest release change, and the rating's month. A tap opens the Stores tab.
const storesGlance = DashboardGlance(
  id: 'stores',
  title: 'Stores',
  icon: AppIcons.package,
  build: _body,
  onOpen: _open,
);

Widget _body(BuildContext context) => const StoresGlanceBody();

void _open(BuildContext context, WidgetRef ref) => openStoresTab(ref);

/// The glance's body alone: the dashboard draws the tile around it. One line
/// on a phone's strip ([GlanceScope.compactOf]).
class StoresGlanceBody extends ConsumerWidget {
  const StoresGlanceBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(storesGlanceProvider);
    final now = ref.watch(clockProvider).nowUtc();
    final compact = GlanceScope.compactOf(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    if (data == null) {
      return Text(
        'No store connected',
        key: const ValueKey('stores-glance-empty'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: muted,
      );
    }

    final attentionText = data.attention == 0
        ? 'Nothing needs you'
        : '${data.attention} need${data.attention == 1 ? 's' : ''} '
              'attention · ${data.firstAttention}';
    final attention = Row(
      children: [
        Icon(
          data.attention == 0 ? AppIcons.checkCircle : AppIcons.warning,
          size: Chrome.iconAction,
          color: data.attention == 0 ? semantic.idle : semantic.failure,
        ),
        const SizedBox(width: Insets.xs),
        Expanded(
          child: Text(
            attentionText,
            key: const ValueKey('stores-glance-attention'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
    if (compact) return attention;

    final release = data.newestRelease;
    final rating = data.rating;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        attention,
        if (release != null) ...[
          const SizedBox(height: Insets.xs),
          Tooltip(
            message: release.app,
            child: Text(
              '${release.text} · ${compactAge(now.difference(release.at))}',
              key: const ValueKey('stores-glance-release'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
        ],
        if (rating != null) ...[
          const SizedBox(height: Insets.xs),
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
                  semanticsLabel: '${data.ratingApp} rating, last 30 days',
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
        ],
      ],
    );
  }
}
