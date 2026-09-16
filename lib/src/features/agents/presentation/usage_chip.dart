import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../../app/shell/workbench_tabs.dart';
import '../../settings/presentation/settings_nav.dart';
import '../application/agent_usage_providers.dart';
import '../application/usage_refresh_policy.dart';
import '../domain/usage_pace.dart';
import 'package:agent_cli/usage.dart';
import 'usage_chip_popover.dart';

export '../domain/usage_pace.dart'
    show kUsageWarningPercent, kUsageCriticalPercent;

/// The glyph size and gap the status bar's other items use. Named rather than
/// re-guessed so the chip cannot drift away from the row it sits in.
const double _glyph = 12;
const double _glyphGap = 5;

/// How loud the chip is. Maps to [SemanticColors], never to a raw colour, and
/// never carries the state on its own — see [UsageChipView.label].
enum UsageTone { healthy, warning, critical, muted }

/// **What the glyph claims**: a gauge is a measurement, a history clock a
/// reading with an age, a question mark nothing observed at all.
enum UsageMark {
  /// A number the current read produced, or is producing while the first
  /// answer is still in flight.
  live,

  /// A number the app has, that the current read did not confirm.
  stale,

  /// No number at all. The chip says why in its tooltip and claims nothing.
  unknown,
}

/// Everything the chip draws, resolved from one usage snapshot. A value, so the
/// thresholds and the four states can be asserted without pumping a frame.
@immutable
class UsageChipView {
  const UsageChipView({
    required this.label,
    required this.tooltip,
    required this.tone,
    this.longLabel,
    this.mark = UsageMark.live,
    this.reading,
    this.notes = const [],
  });

  /// The reading the words were taken from — live or remembered — for the
  /// hover card's meters. Null when nothing was observed.
  final AgentUsage? reading;

  /// The lines about the reading rather than its windows: the account, the
  /// sign-in's lifetime, the reading's age and any failure.
  final List<String> notes;

  /// The words on the chip; **always spells out the number**, because colour is
  /// a second signal. The **shorter** period when two are known.
  final String label;

  /// The longer period, drawn after [label]. Null when the reading names only
  /// one — never a placeholder, since an unread period says nothing at all.
  final String? longLabel;

  final String tooltip;
  final UsageTone tone;

  /// What the glyph may claim about the label. A glyph and not a colour, since
  /// the colour carries the quota; the age itself is in the tooltip.
  final UsageMark mark;
}

/// What the chip should say about [usage], as of [now]: live, checking, unknown
/// or stale. [remembered] is what makes stale survive a pane switch.
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
  final mark = error != null || live == null ? UsageMark.stale : UsageMark.live;
  final worst = _tightest(value.windows);
  final age = _ago(now.difference(value.fetchedAt));
  final expiry = value.tokenExpiresAt;
  final notes = [
    if (value.email != null) value.email!,
    if (expiry != null) _expiryLine(expiry, now),
    if (mark == UsageMark.stale) 'Last checked $age' else 'Checked $age',
    if (error != null) _failureLine(error),
  ];
  final detail = [
    for (final w in value.windows) _windowLine(w, now),
    ...notes,
  ].join('\n');

  if (worst == null) {
    // A reply that measured nothing. Not an error, so muted and marked with the
    // question glyph — there is no number here for a gauge to be about.
    final headline = value.isEmpty
        ? 'No usage windows reported.'
        : 'No quota reported for this account.';
    return UsageChipView(
      label: 'usage —',
      tooltip: '$headline\n$detail',
      tone: UsageTone.muted,
      mark: UsageMark.unknown,
      reading: value,
      notes: notes,
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
    reading: value,
    notes: notes,
  );
}

/// **The two periods the chip draws**, shortest then longest, chosen by
/// [UsageWindow.span] — ordering by the countdown would swap them every week.
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

/// A window **and the reading it carries** — [UsageWindow.percent] is nullable,
/// and everything downstream of here is about a number.
typedef _Reading = ({UsageWindow window, double percent});

/// The window nearest its limit **among those that carry a reading**. Null when
/// nothing was measured, which is a different answer from zero.
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

/// **When the sign-in behind this reading lapses**, shaped like a window's
/// reset. Its own line, because it is emphatically not a quota reset.
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
/// rate limit already says what it is doing, so a prefix would bury that.
String _failureLine(Object error) =>
    error is UsageException && error.kind == UsageFailureKind.rateLimited
    ? error.message
    : 'Refresh failed: ${_messageOf(error)}';

String _ago(Duration since) => since < const Duration(minutes: 1)
    ? 'just now'
    : '${formatUsageDuration(since)} ago';

/// The clock time [when] falls at. **`toLocal()` is the whole correctness**: a
/// `Z` string parses to UTC and Codex's epoch seconds parse to local.
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

/// **What the account behind one session has left**, in that session's own bar:
/// the reading is per account (`usageAccountKey`), the display per session.
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

  /// Holds [policy] and lets go of the one held before, when they differ. The
  /// hold moves when the chip's account does, not on every build: retaining on
  /// each build and releasing only the latest policy kept a chip's first
  /// account's timer running after its session moved to another.
  void _hold(UsageRefreshController? policy) {
    if (identical(policy, _policy)) return;
    _policy?.release(this);
    _policy = policy;
    policy?.retain(this);
  }

  @override
  void dispose() {
    // The only teardown hook that always runs. Released, not stopped: the timer
    // belongs to the *account*, and a sibling pane may still be on screen.
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
    if (installation == null) {
      _hold(null);
      return const SizedBox.shrink();
    }

    // Keeps this **account's** timer alive while a chip on it is on screen.
    final account = usageAccountKey(installation);
    ref.watch(usageRefreshProvider(account));
    final policy = ref.read(usageRefreshProvider(account).notifier);
    _hold(policy);

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
        openSettingsTab(ref, anchor: SettingsAnchor.usage);
      },
      // The hover card is pictures; the plain sentence is what a screen reader
      // is given instead.
      child: Semantics(
        tooltip: view.tooltip,
        child: Tooltip(
          excludeFromSemantics: true,
          padding: EdgeInsets.zero,
          decoration: const BoxDecoration(),
          richMessage: WidgetSpan(
            child: UsageChipPopover(
              view: view,
              accountKey: account,
              agentId: installation.agentId,
              environmentId: installation.environmentId,
            ),
          ),
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
                // rather than overflow, each period giving up its own.
                Flexible(child: _words(view.label, colour)),
                if (view.longLabel case final longer?) ...[
                  // A gap rather than another `·`: the dot already separates the
                  // halves *inside* a fact. It also costs no height.
                  const SizedBox(width: Insets.sm),
                  Flexible(child: _words(longer, colour)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
