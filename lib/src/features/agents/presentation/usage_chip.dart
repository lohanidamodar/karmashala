import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../../app/shell/workbench_tabs.dart';
import '../../settings/presentation/settings_nav.dart';
import '../application/agent_usage_providers.dart';
import '../application/usage_refresh_policy.dart';
import 'package:agent_cli/usage.dart';

/// Where a quota stops being background information — the same two numbers
/// Settings' usage bars use, named here so the chip and the bars cannot
/// disagree about what "nearly out" means.
const double kUsageWarningPercent = 80;
const double kUsageCriticalPercent = 95;

/// The glyph size and gap the status bar's other items use. Named rather than
/// re-guessed so the chip cannot drift away from the row it sits in.
const double _glyph = 12;
const double _glyphGap = 5;

/// How loud the chip is. Maps to [SemanticColors], never to a raw colour, and
/// never carries the state on its own — see [UsageChipView.label].
enum UsageTone { healthy, warning, critical, muted }

/// **What the glyph claims**, in the system health panel's vocabulary: a gauge
/// is a measurement, a history clock a reading with an age, a question mark
/// nothing observed at all. An unmeasured state must never borrow the mark of a
/// measured one.
enum UsageMark {
  /// A number the current read produced, or is producing while the first
  /// answer is still in flight.
  live,

  /// A number the app has, that the current read did not confirm.
  stale,

  /// No number at all. The chip says why in its tooltip and claims nothing.
  unknown,
}

/// Everything the chip draws, resolved from one usage snapshot. A value rather
/// than widget code, so the thresholds, the wording and the four states can be
/// asserted without pumping a frame.
@immutable
class UsageChipView {
  const UsageChipView({
    required this.label,
    required this.tooltip,
    required this.tone,
    this.longLabel,
    this.mark = UsageMark.live,
  });

  /// The words on the chip. **Always spells out the number** when one is known:
  /// the colour is a second signal, never the only one. The **shorter** period
  /// when two are known — see [longLabel].
  final String label;

  /// The longer period, drawn after [label] as a second fact. Null when the
  /// reading names only one, and never a placeholder: a period nothing was read
  /// for says nothing at all.
  final String? longLabel;

  final String tooltip;
  final UsageTone tone;

  /// What the glyph is allowed to claim about the label beside it. A different
  /// glyph rather than a different colour, because the colour is carrying the
  /// quota — muting a 97% because it is four minutes old would hide the more
  /// important of the two facts. The age itself is in the tooltip.
  final UsageMark mark;
}

/// What the chip should say about [usage], as of [now].
///
/// Four states: **live**, each period's number and how long until it resets;
/// **checking**, muted, before the first answer arrives; **unknown**, where the
/// lookup failed or succeeded and measured nothing (Antigravity's
/// `loadCodeAssist` names the account's tiers and reports no quota against any
/// of them) — a dash, the neutral colour, the question glyph and everything that
/// *is* known in the tooltip; and **stale**, a failed refresh over a number we
/// have, kept with a different glyph and its age, because losing a number you
/// had is worse than showing an old one that admits it is old.
///
/// [remembered] is what makes stale survive a pane switch: `agentUsageProvider`
/// is `autoDispose`, so `AsyncValue` alone carries a previous value only until
/// the chip leaves the tree.
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
    // dash that is plainly not a reading.
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
  final worst = _tightest(value.windows);
  final age = _ago(now.difference(value.fetchedAt));
  final expiry = value.tokenExpiresAt;
  final detail = [
    for (final w in value.windows) _windowLine(w, now),
    if (value.email != null) value.email!,
    if (expiry != null) _expiryLine(expiry, now),
    if (mark == UsageMark.stale) 'Last checked $age' else 'Checked $age',
    if (error != null) _failureLine(error),
  ].join('\n');

  if (worst == null) {
    // A reply that measured nothing: no windows at all, or windows the endpoint
    // named and reported no quota against. Not an error, so muted, with the
    // question mark rather than a gauge — there is no number here for a gauge to
    // be about. The tooltip still carries everything that *is* known.
    final headline = value.isEmpty
        ? 'No usage windows reported.'
        : 'No quota reported for this account.';
    return UsageChipView(
      label: 'usage —',
      tooltip: '$headline\n$detail',
      tone: UsageTone.muted,
      mark: UsageMark.unknown,
    );
  }

  final (short, long) = _bothPeriods(value.windows, worst);
  return UsageChipView(
    label: _fact(short, now),
    longLabel: long == null ? null : _fact(long, now),
    tooltip: detail,
    // The worst number the account has, and always one of the numbers on
    // screen — the chip never colours a fact it does not spell out.
    tone: _toneFor(worst.percent),
    mark: mark,
  );
}

/// **The two periods the chip draws**: the shortest the reading names, then the
/// longest. One is not enough either way round — a five-hour window at 4% says
/// nothing while the weekly cap sits at 97%, and the weekly cap says nothing
/// about the hour you are in.
///
/// **Chosen by [UsageWindow.span]**, the period the endpoint's own key names,
/// never by which resets soonest: ordering by the countdown would swap the pair
/// at the end of every week. Several windows can share a period (Claude reports
/// `seven_day`, `seven_day_opus` and `seven_day_sonnet`), and the slot goes to
/// the tightest of them.
///
/// Falls back to the single number when there is no second period, or when a
/// period-less window is nonetheless the worst reading — the colour is the worst
/// window's, and it must never describe a number that is not on screen.
(_Reading, _Reading?) _bothPeriods(List<UsageWindow> windows, _Reading worst) {
  Duration? shortest;
  Duration? longest;
  for (final window in windows) {
    final span = window.span;
    // A window nothing measured cannot fill a slot: a slot is a number, and
    // this one has none. It is still named in the tooltip.
    if (span == null || window.percent == null) continue;
    if (shortest == null || span < shortest) shortest = span;
    if (longest == null || span > longest) longest = span;
  }
  if (shortest == null || shortest == longest) return (worst, null);
  final short = _tightest(windows.where((w) => w.span == shortest));
  final long = _tightest(windows.where((w) => w.span == longest));
  if (short == null || long == null) return (worst, null);
  if (worst.percent > short.percent && worst.percent > long.percent) {
    return (worst, null);
  }
  return (short, long);
}

/// One window as the chip says it: the number, and how long until it resets.
String _fact(_Reading reading, DateTime now) {
  final reset = reading.window.resetsAt;
  return reset == null
      ? '${reading.percent.round()}%'
      : '${reading.percent.round()}% · '
            '${formatUsageDuration(reset.difference(now))}';
}

/// A window **and the reading it carries**. A record rather than a bare
/// [UsageWindow] because [UsageWindow.percent] is nullable — every Antigravity
/// tier has none — and everything downstream of here is about a number, so the
/// type states once that there is one.
typedef _Reading = ({UsageWindow window, double percent});

/// The window nearest its limit **among those that carry a reading** — the one
/// that will actually stop you. It carries the chip's colour and is what the
/// chip draws alone when [_bothPeriods] has no pair. Null when nothing was
/// measured, which is a different answer from zero; every window is in the
/// tooltip regardless.
_Reading? _tightest(Iterable<UsageWindow> windows) {
  _Reading? tightest;
  for (final window in windows) {
    final percent = window.percent;
    if (percent == null) continue;
    if (tightest == null || percent > tightest.percent) {
      tightest = (window: window, percent: percent);
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
  final percent = window.percent;
  // A window the endpoint named and measured nothing for. Said in words, so the
  // one row of the tooltip that would otherwise be a number is plainly not one.
  if (percent == null) return '${window.label} · $kUsageNoQuotaReported';
  final reset = window.resetsAt;
  final resets = reset == null
      ? ''
      : ' · resets in ${formatUsageDuration(reset.difference(now))}'
            ' (${formatResetClock(reset, now)})';
  return '${window.label} · ${percent.round()}%$resets';
}

/// **When the sign-in behind this reading lapses**, in the same shape a window's
/// reset is given. Worth a line of its own because for an account that reports
/// no quota it is most of what is known — and because it is emphatically not a
/// quota reset, which is what it was being drawn as.
String _expiryLine(DateTime when, DateTime now) {
  final left = when.difference(now);
  return left <= Duration.zero
      ? 'Sign-in expired — run the agent once to refresh it'
      : 'Sign-in expires in ${formatUsageDuration(left)}'
            ' (${formatResetClock(when, now)})';
}

String _messageOf(Object error) =>
    error is UsageException ? error.message : '$error';

/// The one line the tooltip gives a failure that did not cost us the number. A
/// rate limit already says what happened *and* what the app is doing about it,
/// so a "Refresh failed" prefix would bury the actionable half.
String _failureLine(Object error) =>
    error is UsageException && error.kind == UsageFailureKind.rateLimited
    ? error.message
    : 'Refresh failed: ${_messageOf(error)}';

String _ago(Duration since) => since < const Duration(minutes: 1)
    ? 'just now'
    : '${formatUsageDuration(since)} ago';

/// The clock time [when] falls at, for a reader who wants to plan around it.
/// "resets in 2h 14m" answers *how long*; it does not answer *when*, and both
/// are shown.
///
/// **`toLocal()` is the whole correctness of this function.** An ISO string with
/// a `Z` parses to UTC and Codex's epoch seconds parse to local — invisible
/// while the only use is `difference(now)`, and a wrong hour on screen the
/// moment one is formatted. A weekday is prefixed only when the reset is not
/// today.
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

/// **What the account behind one session has left**, in that session's own bar.
///
/// It sits with the session's permission mode, model and delivery actions rather
/// than in the window's status bar, where it used to be: panes run different
/// agents and more than one account of the same agent, so one figure in the
/// window's chrome attributed one account's remaining quota to a pane running a
/// different one.
///
/// **The reading is per account; the display is per session.** [sessionId] only
/// chooses *which* account is described — the fetch, the schedule, the rate
/// limit and the timer all belong to `usageAccountKey`, so several panes on one
/// account cost one request between them and an off-screen pane costs nothing.
///
/// A session whose agent has **no usage endpoint** draws nothing rather than a
/// dash that reads like data, and a failure never raises a `SnackBar` — a stale
/// token would nag on every tick.
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
    // The widget tree going away must take the timer with it, and this is the
    // only hook that always runs. Released rather than stopped: the timer
    // belongs to the *account*, and a sibling pane on it may still be on screen.
    _policy?.release(this);
    super.dispose();
  }

  /// One period's words. Both slots are drawn in one colour — the worst
  /// window's — because two colours in a 12px row read as two chips.
  Widget _words(String fact, Color colour) => Text(
    fact,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(color: colour),
  );

  @override
  Widget build(BuildContext context) {
    UsageChip.debugBuildCount++;
    final installation = ref.watch(
      usageInstallationForSessionProvider(widget.sessionId),
    );
    if (installation == null) return const SizedBox.shrink();

    // Keeps this **account's** refresh timer alive for as long as a chip on it
    // is on screen, and re-arms the tick this widget's own teardown cancelled.
    // Keyed by account, so two panes on one account share one timer.
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
        openSettingsTab(ref, section: SettingsSectionId.agents);
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
                // "a reading with an age" and for "nothing was observed".
                switch (view.mark) {
                  UsageMark.live => AppIcons.circleHalf,
                  UsageMark.stale => AppIcons.clockCounterClockwise,
                  UsageMark.unknown => AppIcons.question,
                },
                size: _glyph,
                color: colour,
              ),
              const SizedBox(width: _glyphGap),
              // Flexible, so a bounded bar makes the chip give up its tail
              // rather than overflow, and each period gives up its own tail
              // rather than one crowding out the other.
              Flexible(child: _words(view.label, colour)),
              if (view.longLabel case final longer?) ...[
                // A gap rather than another `·`: the dot already separates the
                // halves *inside* a fact, so `12% · 4h · 59% · 3d` would read as
                // four things. It also costs no height, which a divider would.
                const SizedBox(width: Insets.sm),
                Flexible(child: _words(longer, colour)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
