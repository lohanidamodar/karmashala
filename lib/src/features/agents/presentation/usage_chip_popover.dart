import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../environments/application/environments_controller.dart';
import '../application/usage_history.dart';
import '../domain/usage_sample.dart';
import 'usage_chip.dart';
import 'usage_history_charts.dart';
import 'usage_window_meter.dart';

/// The width the hover card is laid out at, at most.
const double kUsagePopoverWidth = 300;

/// **The usage chip's hover card**: every window of the account as a meter
/// with its countdown and pace, a sparkline of its recent history, and the
/// reading's age. Falls back to the chip's own sentence when there is no
/// reading to draw.
class UsageChipPopover extends ConsumerWidget {
  const UsageChipPopover({
    required this.view,
    required this.accountKey,
    required this.agentId,
    required this.environmentId,
    super.key,
  });

  final UsageChipView view;
  final String accountKey;
  final String agentId;
  final String environmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final muted = small?.copyWith(color: scheme.onSurfaceVariant);
    final now = ref.watch(clockProvider).nowUtc();
    final reading = view.reading;
    final title =
        '${AgentRegistry.builtIn.displayNameFor(agentId)} · '
        '${ref.watch(environmentLabelForIdProvider(environmentId))}';

    final header = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );
    final body = <Widget>[];
    if (reading == null || reading.windows.every((w) => w.percent == null)) {
      body.add(Text(view.tooltip, style: small));
    } else {
      final history = ref.watch(
        usageHistoryProvider(usageHistoryQuery(accountKey, now)),
      );
      for (final window in reading.windows) {
        body.add(
          UsageWindowMeter(
            window: window,
            readAt: reading.fetchedAt,
            now: now,
            trailing: _sparkline(context, history, window, now),
          ),
        );
      }
      for (final note in view.notes) {
        body.add(Text(note, style: muted));
      }
    }
    // A card taller than the window cannot be scrolled — it is a hover — so
    // the windows give way and the header and the way on stay.
    final maxHeight = MediaQuery.sizeOf(context).height - Insets.xl * 2;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: kUsagePopoverWidth,
        maxHeight: maxHeight < 120 ? 120 : maxHeight,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(Radii.md),
          boxShadow: const [
            BoxShadow(
              color: Color(0x2E000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: DefaultTextStyle(
          style: small ?? const TextStyle(),
          child: Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                const SizedBox(height: Insets.xs),
                Flexible(
                  child: SingleChildScrollView(
                    primary: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: body,
                    ),
                  ),
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  'Click for usage & limits',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The window's recent readings as a sparkline, ending at the reading on
  /// screen; nothing when fewer than two points exist.
  Widget? _sparkline(
    BuildContext context,
    List<UsageSample> history,
    UsageWindow window,
    DateTime now,
  ) {
    final percent = window.percent;
    if (percent == null) return null;
    final from = now.subtract(window.span ?? const Duration(hours: 24));
    final values = [
      for (final sample in samplesOf(history, window.label, from: from))
        sample.percent,
    ];
    if (values.isEmpty || values.last != percent) values.add(percent);
    if (values.length < 2) return null;
    return Sparkline(
      values: values,
      width: 64,
      height: 16,
      maxValue: 100,
      color: usageSeverityColor(context, usageSeverityFor(percent)),
      semanticsLabel:
          '${window.label} over the last '
          '${formatUsageDuration(now.difference(from))}',
    );
  }
}
