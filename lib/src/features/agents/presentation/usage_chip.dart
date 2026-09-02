import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../settings/presentation/settings_nav.dart';
import '../../settings/presentation/settings_screen.dart';
import '../application/agent_usage_providers.dart';
import '../application/usage_refresh_policy.dart';
import '../data/agent_usage_service.dart';
import '../domain/agent_usage.dart';

/// Where a quota stops being background information.
///
/// The same two numbers Settings' usage bars use, named here because the chip
/// and the bars must not disagree about what "nearly out" means.
const double kUsageWarningPercent = 80;
const double kUsageCriticalPercent = 95;

/// The glyph size and gap the status bar's other items use. Named rather than
/// re-guessed so the chip cannot drift away from the row it sits in.
const double _glyph = 12;
const double _glyphGap = 5;

/// How loud the chip is. Maps to [SemanticColors], never to a raw colour, and
/// never carries the state on its own — see [UsageChipView.label].
enum UsageTone { healthy, warning, critical, muted }

/// Everything the chip draws, resolved from one usage snapshot.
///
/// A value rather than widget code so the thresholds, the wording and the four
/// states can be asserted without pumping a frame.
@immutable
class UsageChipView {
  const UsageChipView({
    required this.label,
    required this.tooltip,
    required this.tone,
  });

  /// The words on the chip. **Always spells out the number** when one is known:
  /// the colour is a second signal, never the only one.
  final String label;

  final String tooltip;
  final UsageTone tone;
}

/// What the chip should say about [usage], as of [now].
///
/// Four states, and the last two are the ones that matter:
///
/// * **live** — a number and how long until that window resets;
/// * **checking** — muted, before the first answer arrives;
/// * **muted** — the fetch failed and we have never had a number, so the
///   service's own sentence is all there is to show (an expired token tells the
///   user to run the agent once);
/// * **stale** — a refresh failed but a previous number is known. It keeps
///   being shown, and the tooltip says when it was read. Losing a number you
///   had is worse than showing an old one that admits it is old.
UsageChipView usageChipViewFor(AsyncValue<AgentUsage> usage, DateTime now) {
  final value = usage.value;
  final error = usage.error;
  if (value == null) {
    return UsageChipView(
      label: error == null ? 'usage …' : 'usage —',
      tooltip: error == null ? 'Checking agent usage…' : _messageOf(error),
      tone: UsageTone.muted,
    );
  }

  final window = _tightest(value.windows);
  final age = _ago(now.difference(value.fetchedAt));
  final detail = [
    for (final w in value.windows) _windowLine(w, now),
    if (value.email != null) value.email!,
    if (error == null) 'Checked $age' else 'Last checked $age',
    if (error != null) 'Refresh failed: ${_messageOf(error)}',
  ].join('\n');

  if (window == null) {
    // A successful fetch that reported no windows at all: honest, and not an
    // error, so it is muted rather than coloured.
    return UsageChipView(
      label: 'usage —',
      tooltip: 'No usage windows reported.\n$detail',
      tone: UsageTone.muted,
    );
  }

  final reset = window.resetsAt;
  return UsageChipView(
    label: reset == null
        ? '${window.percent.round()}%'
        : '${window.percent.round()}% · ${formatUsageDuration(reset.difference(now))}',
    tooltip: detail,
    tone: _toneFor(window.percent),
  );
}

/// The window nearest its limit — the one that will actually stop you.
///
/// Not the first: a 5-hour window at 4% says nothing useful while the weekly
/// cap sits at 97%, and the chip has room for exactly one number. Every window
/// is still listed in the tooltip.
UsageWindow? _tightest(List<UsageWindow> windows) {
  UsageWindow? tightest;
  for (final window in windows) {
    if (tightest == null || window.percent > tightest.percent) {
      tightest = window;
    }
  }
  return tightest;
}

UsageTone _toneFor(double percent) => switch (percent) {
  >= kUsageCriticalPercent => UsageTone.critical,
  >= kUsageWarningPercent => UsageTone.warning,
  _ => UsageTone.healthy,
};

String _windowLine(UsageWindow window, DateTime now) {
  final reset = window.resetsAt;
  final resets = reset == null
      ? ''
      : ' · resets in ${formatUsageDuration(reset.difference(now))}';
  return '${window.label} · ${window.percent.round()}%$resets';
}

String _messageOf(Object error) =>
    error is UsageException ? error.message : '$error';

String _ago(Duration since) => since < const Duration(minutes: 1)
    ? 'just now'
    : '${formatUsageDuration(since)} ago';

/// A countdown the width of a status bar: `2h11m`, `45m`, `3d4h`, `now`.
String formatUsageDuration(Duration span) {
  if (span <= Duration.zero) return 'now';
  if (span.inDays >= 1) {
    final hours = span.inHours - span.inDays * 24;
    return hours == 0 ? '${span.inDays}d' : '${span.inDays}d${hours}h';
  }
  if (span.inHours >= 1) {
    final minutes = span.inMinutes - span.inHours * 60;
    return minutes == 0 ? '${span.inHours}h' : '${span.inHours}h${minutes}m';
  }
  return '${span.inMinutes}m';
}

/// **Live quota for the agent you are looking at**, in the status bar.
///
/// Follows the focused session: a Claude pane shows Claude's windows, a Codex
/// pane shows Codex's, and a pane running anything else shows **nothing at
/// all** — [focusedUsageInstallationProvider] applies the same allowlist the
/// service does, so an agent we have no endpoint for produces an absent chip
/// rather than a permanent error.
///
/// It never raises a `SnackBar`. A stale token would nag once a minute; the
/// failure lives in the chip and in its tooltip, where the user can read it
/// when they choose to.
class UsageChip extends ConsumerStatefulWidget {
  const UsageChip({super.key});

  /// Builds of the chip, counted so the status bar's cost test can prove a
  /// usage change repaints this and nothing else in the row.
  @visibleForTesting
  static int debugBuildCount = 0;

  @override
  ConsumerState<UsageChip> createState() => _UsageChipState();
}

class _UsageChipState extends ConsumerState<UsageChip> {
  /// The policy this chip keeps alive, held as a plain object so it can be
  /// stopped from [dispose], where `ref` is no longer safe to read.
  UsageRefreshController? _policy;

  @override
  void dispose() {
    // The widget tree going away must take the timer with it. Riverpod's own
    // scheduled auto-dispose is cancelled when the surrounding `ProviderScope`
    // unmounts, so this is the only hook that always runs.
    _policy?.stopPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    UsageChip.debugBuildCount++;
    final installation = ref.watch(focusedUsageInstallationProvider);
    if (installation == null) return const SizedBox.shrink();

    // Keeps the one refresh timer alive for exactly as long as a chip is on
    // screen; the policy owns the ticking, this only asks for it to exist —
    // and re-arms the tick that this widget's own teardown cancelled.
    ref.watch(usageRefreshProvider);
    final policy = ref.read(usageRefreshProvider.notifier);
    _policy = policy;
    policy.ensurePolling();

    final view = usageChipViewFor(
      ref.watch(agentUsageProvider(installation)),
      ref.read(clockProvider).nowUtc(),
    );
    final semantic = SemanticColors.of(context);
    final colour = switch (view.tone) {
      UsageTone.healthy => semantic.idle,
      UsageTone.warning => semantic.attention,
      UsageTone.critical => semantic.failure,
      UsageTone.muted => semantic.neutral,
    };

    return InkWell(
      onTap: () {
        policy.refresh();
        SettingsScreen.show(context, section: SettingsSectionId.agents);
      },
      child: Tooltip(
        message: view.tooltip,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.circleHalf, size: _glyph, color: colour),
              const SizedBox(width: _glyphGap),
              Text(
                view.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colour),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
