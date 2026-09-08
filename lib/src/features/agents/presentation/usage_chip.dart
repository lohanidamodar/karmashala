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
import '../data/usage_throttle.dart';
import '../domain/agent_usage.dart';
import '../domain/usage_failure.dart';

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

/// **What the glyph claims**, in the system health panel's vocabulary.
///
/// A gauge says "this is a measurement"; a history clock says "this is a
/// reading, and it has an age"; a question mark says nothing was observed at
/// all. `HealthLevel.unknown` exists for the same reason: an unmeasured state
/// must never borrow the mark of a measured one.
enum UsageMark {
  /// A number that the current read produced — or is producing, while the first
  /// answer is still in flight and the label says so.
  live,

  /// A number the app has, that the current read did not confirm.
  stale,

  /// No number at all. The chip says why in its tooltip and claims nothing.
  unknown,
}

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
    this.mark = UsageMark.live,
  });

  /// The words on the chip. **Always spells out the number** when one is known:
  /// the colour is a second signal, never the only one.
  final String label;

  final String tooltip;
  final UsageTone tone;

  /// What the glyph is allowed to claim about the label beside it.
  ///
  /// A different glyph rather than a different colour, because the colour is
  /// carrying the quota: muting a 97% because it is four minutes old would hide
  /// the more important of the two facts. The age itself is in the tooltip,
  /// which is the only place in a status bar with room for it.
  final UsageMark mark;
}

/// What the chip should say about [usage], as of [now].
///
/// Four states, and the last two are the ones that matter:
///
/// * **live** — a number and how long until that window resets;
/// * **checking** — muted, before the first answer arrives;
/// * **unknown** — the lookup failed and no number has ever been read. It
///   claims nothing: a dash, the neutral colour, the question glyph, and the
///   service's own sentence in the tooltip (an expired token tells the user to
///   run the agent once; a rate limit says how long it is waiting);
/// * **stale** — a refresh failed but a number is known. It keeps being shown,
///   with a different glyph and its age in the tooltip. Losing a number you had
///   is worse than showing an old one that admits it is old.
///
/// [remembered] is the last reading the service holds for this account, and it
/// is what makes the stale state survive a pane switch: `agentUsageProvider` is
/// `autoDispose`, so `AsyncValue` alone carries a previous value only until the
/// chip leaves the tree. Without it, the first failure after coming back to a
/// pane blanked a number the app had read seconds earlier.
UsageChipView usageChipViewFor(
  AsyncValue<AgentUsage> usage,
  DateTime now, {
  AgentUsage? remembered,
}) {
  final live = usage.value;
  final value = live ?? remembered;
  final error = usage.error;
  if (value == null) {
    // Nothing was observed, so nothing is claimed: no gauge, no zero, and a
    // dash that is plainly not a reading. `HealthLevel.unknown` is the same
    // answer to the same question one panel over.
    return UsageChipView(
      label: error == null ? 'usage …' : 'usage —',
      tooltip: error == null ? 'Checking agent usage…' : _messageOf(error),
      tone: UsageTone.muted,
      mark: error == null ? UsageMark.live : UsageMark.unknown,
    );
  }

  // Anything not confirmed by the current read: a failed refresh, or one still
  // in flight over a number we already had.
  final mark = error != null || live == null
      ? UsageMark.stale
      : UsageMark.live;
  final window = _tightest(value.windows);
  final age = _ago(now.difference(value.fetchedAt));
  final detail = [
    for (final w in value.windows) _windowLine(w, now),
    if (value.email != null) value.email!,
    if (mark == UsageMark.stale) 'Last checked $age' else 'Checked $age',
    if (error != null) _failureLine(error),
  ].join('\n');

  if (window == null) {
    // A successful fetch that reported no windows at all: honest, and not an
    // error, so it is muted rather than coloured.
    return UsageChipView(
      label: 'usage —',
      tooltip: 'No usage windows reported.\n$detail',
      tone: UsageTone.muted,
      mark: mark,
    );
  }

  final reset = window.resetsAt;
  return UsageChipView(
    label: reset == null
        ? '${window.percent.round()}%'
        : '${window.percent.round()}% · ${formatUsageDuration(reset.difference(now))}',
    tooltip: detail,
    tone: _toneFor(window.percent),
    mark: mark,
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
      : ' · resets in ${formatUsageDuration(reset.difference(now))}'
            ' (${formatResetClock(reset, now)})';
  return '${window.label} · ${window.percent.round()}%$resets';
}

String _messageOf(Object error) =>
    error is UsageException ? error.message : '$error';

/// The one line the tooltip gives a failure that did not cost us the number.
///
/// A rate limit already says what happened *and* what the app is doing about
/// it, so prefixing "Refresh failed" would bury the only actionable half —
/// that nothing is wrong and nobody should keep clicking.
String _failureLine(Object error) =>
    error is UsageException && error.kind == UsageFailureKind.rateLimited
    ? error.message
    : 'Refresh failed: ${_messageOf(error)}';

String _ago(Duration since) => since < const Duration(minutes: 1)
    ? 'just now'
    : '${formatUsageDuration(since)} ago';

/// A countdown the width of a status bar: `2h11m`, `45m`, `3d4h`, `now`.
/// The clock time [when] falls at, for a reader who wants to plan around it.
///
/// "resets in 2h 14m" answers *how long*; it does not answer *when*, and a
/// quota you are waiting on is something people arrange the rest of an
/// afternoon around. Both are shown, never one instead of the other.
///
/// **`toLocal()` is the whole correctness of this function.** The two services
/// hand back reset times in different zones — an ISO string with a `Z` parses
/// to UTC, while Codex's epoch seconds parse to local. That difference is
/// invisible while the only use is `difference(now)`, which compares absolute
/// instants, and becomes a wrong hour on screen the moment one is formatted.
///
/// A weekday is prefixed only when the reset is not today, because "resets
/// 11:55" three days out is a worse answer than no answer.
String formatResetClock(DateTime when, DateTime now) {
  final local = when.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final clock =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  if (day == today) return clock;
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${names[local.weekday - 1]} $clock';
}

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

/// **What the account behind one session has left**, in that session's own bar.
///
/// It sits with the session's permission mode, its model and its delivery
/// actions, and not in the window's status bar, where it used to be. The
/// owner's words: *"move this usage to the terminal status bar so it's tied to
/// session not app because each session might be different one."* Panes run
/// different agents — Claude Code, Codex and Antigravity each have their own
/// quota — and more than one account of the same agent, so one figure in the
/// window's chrome attributed one account's remaining quota to a pane running a
/// different one. The model chip moved out of that row for the same reason and
/// is drawn a few pixels from this.
///
/// **The reading is per account; the display is per session.** [sessionId] only
/// chooses *which* account is described. The fetch, the schedule, the rate limit
/// and the timer all belong to `usageAccountKey` — the `(agent, environment)`
/// pair — so several panes on one account cost one request between them, and a
/// pane that is not on screen costs nothing at all, because nothing watches its
/// providers.
///
/// A session whose agent has **no usage endpoint** draws nothing:
/// [usageInstallationForSessionProvider] applies the service's own allowlist, so
/// the chip is absent rather than showing a dash that reads like data.
///
/// It never raises a `SnackBar`. A stale token would nag on every tick; the
/// failure lives in the chip and in its tooltip, where the user can read it
/// when they choose to.
class UsageChip extends ConsumerStatefulWidget {
  const UsageChip({required this.sessionId, super.key});

  /// The session whose account this describes.
  final String sessionId;

  /// Builds of the chip, counted so a cost test can prove a usage change
  /// repaints this and nothing else in the bar it sits in.
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
    // unmounts, so this is the only hook that always runs — but the timer now
    // belongs to the *account*, so it is released rather than stopped: a
    // sibling pane on the same account may still be on screen, and stopping
    // outright took the schedule away from it.
    _policy?.release(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    UsageChip.debugBuildCount++;
    final installation = ref.watch(
      usageInstallationForSessionProvider(widget.sessionId),
    );
    if (installation == null) return const SizedBox.shrink();

    // Keeps this **account's** refresh timer alive for exactly as long as a
    // chip on it is on screen; the policy owns the ticking, this only asks for
    // it to exist — and re-arms the tick that this widget's own teardown
    // cancelled. Keyed by account, so two panes on one account share one timer
    // and a second account brings its own.
    final account = usageAccountKey(installation);
    ref.watch(usageRefreshProvider(account));
    final policy = ref.read(usageRefreshProvider(account).notifier);
    _policy = policy;
    policy.retain(this);

    final view = usageChipViewFor(
      ref.watch(agentUsageProvider(installation)),
      ref.read(clockProvider).nowUtc(),
      // Survives what `AsyncValue` cannot: the chip is rebuilt from nothing
      // every time the focused pane moves to another account and back.
      remembered: ref.watch(agentUsageServiceProvider).remembered(installation),
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
              Icon(
                // The health panel's glyphs, on purpose: one vocabulary for
                // "this is a reading with an age" and for "nothing was
                // observed".
                switch (view.mark) {
                  UsageMark.live => AppIcons.circleHalf,
                  UsageMark.stale => AppIcons.clockCounterClockwise,
                  UsageMark.unknown => AppIcons.question,
                },
                size: _glyph,
                color: colour,
              ),
              const SizedBox(width: _glyphGap),
              // Flexible, so the chip can be given a bounded box and give up
              // its tail rather than overflow: a workspace group's bar is a
              // fraction of the window, and `51% · 28m` is wider than some of
              // them. The glyph and the tooltip survive the trim.
              Flexible(
                child: Text(
                  view.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colour),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
