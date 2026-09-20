/// Which usage window a resume should wait on, and whether a reading says the
/// wait is over. Pure, so the dialog and the fire path cannot disagree.
library;

import 'package:agent_cli/usage.dart';

import '../../agents/domain/usage_pace.dart';
import 'scheduled_resume.dart';

/// A window at or past this is spent: the provider refuses work until it resets.
const double kUsageSpentPercent = 100;

bool isSpent(UsageWindow window) => (window.percent ?? 0) >= kUsageSpentPercent;

/// Why [blockingWindow] picked the window it did, for the dialog's caption.
enum BlockingWindowReason { spent, named, nearLimit, soonestReset }

class BlockingWindow {
  const BlockingWindow(this.window, this.reason);

  final UsageWindow window;
  final BlockingWindowReason reason;
}

/// The windows a resume can wait on: those with a reset still to come.
List<UsageWindow> resumableWindows(List<UsageWindow> windows, DateTime now) => [
  for (final window in windows)
    if (window.resetsAt != null && window.resetsAt!.isAfter(now)) window,
];

/// The window to preselect. A spent one first — the *latest* to reset when
/// several are, since work is refused until all of them are back — then the
/// one the agent's own message named, then one near its limit, then the
/// soonest reset. Null when no window names a reset to come.
BlockingWindow? blockingWindow(
  List<UsageWindow> windows, {
  required DateTime now,
  String? namedLabel,
}) {
  final candidates = resumableWindows(windows, now);
  if (candidates.isEmpty) return null;

  final spent = candidates.where(isSpent).toList()
    ..sort((a, b) => b.resetsAt!.compareTo(a.resetsAt!));
  if (spent.isNotEmpty) {
    return BlockingWindow(spent.first, BlockingWindowReason.spent);
  }

  for (final window in candidates) {
    if (namedLabel != null && window.label == namedLabel) {
      return BlockingWindow(window, BlockingWindowReason.named);
    }
  }

  final near =
      candidates
          .where((window) => (window.percent ?? 0) >= kUsageCriticalPercent)
          .toList()
        ..sort((a, b) => b.percent!.compareTo(a.percent!));
  if (near.isNotEmpty) {
    return BlockingWindow(near.first, BlockingWindowReason.nearLimit);
  }

  final soonest = [...candidates]
    ..sort((a, b) => a.resetsAt!.compareTo(b.resetsAt!));
  return BlockingWindow(soonest.first, BlockingWindowReason.soonestReset);
}

/// What a usage reading says about a resume that has come due.
sealed class ResetCheck {
  const ResetCheck();
}

/// Nothing is spent: the account can work.
class ResetConfirmed extends ResetCheck {
  const ResetConfirmed();
}

/// The provider still refuses work. [until] is the latest reset among the
/// spent windows, or null when it named none to come.
class StillLimited extends ResetCheck {
  const StillLimited({required this.label, this.until});

  final String label;
  final DateTime? until;
}

/// The reading predates the reset it would have to describe, so it says
/// nothing about now. The ask floor served a remembered one.
class ReadingPredatesReset extends ResetCheck {
  const ReadingPredatesReset();
}

ResetCheck checkReset(AgentUsage reading, {required DateTime now}) {
  UsageWindow? blocking;
  var stale = false;
  for (final window in reading.windows) {
    if (!isSpent(window)) continue;
    final resets = window.resetsAt;
    if (resets != null && !resets.isAfter(now)) {
      // Spent as of a moment before its own reset: a remembered reading.
      if (reading.fetchedAt.isBefore(resets)) {
        stale = true;
        continue;
      }
    }
    if (blocking == null || _later(resets, blocking.resetsAt)) {
      blocking = window;
    }
  }
  if (blocking != null) {
    final resets = blocking.resetsAt;
    return StillLimited(
      label: blocking.label,
      until: resets != null && resets.isAfter(now) ? resets : null,
    );
  }
  return stale ? const ReadingPredatesReset() : const ResetConfirmed();
}

bool _later(DateTime? a, DateTime? b) {
  if (a == null) return false;
  return b == null || a.isAfter(b);
}

/// When to look again after a fire found the account still limited.
/// [attempts] counts the fire that just happened.
///
/// **Never gives up.** A resume armed at a reset is an arrangement to wait
/// out the limit, and a limit reached again is the thing it was armed for, so
/// there is no attempt at which giving up is the better answer — the row stays
/// visible with its Cancel, and cancelling is what ends it. A named reset is
/// aimed at however many times it has moved; without one the wait doubles up
/// to [kResumeRetryCeiling].
DateTime nextResumeAttempt({
  required int attempts,
  required DateTime now,
  DateTime? until,
}) {
  if (until != null) return until.add(kResumeResetMargin);
  final doubled = kResumeRetryBase * (1 << (attempts - 1).clamp(0, 8));
  return now.add(doubled > kResumeRetryCeiling ? kResumeRetryCeiling : doubled);
}

/// Whether a fresh reading shows [resume]'s window rolled over before its
/// time — providers do reset limits early — so there is nothing left to wait for.
bool windowRolledOverEarly(
  ScheduledResume resume,
  AgentUsage reading, {
  required DateTime now,
}) {
  final waitingFor = resume.resetsAt;
  if (resume.windowLabel == null || waitingFor == null) return false;
  if (!waitingFor.isAfter(now)) return false;
  for (final window in reading.windows) {
    if (window.label != resume.windowLabel) continue;
    final resets = window.resetsAt;
    if (resets == null || isSpent(window)) return false;
    return resets.difference(waitingFor) > kResumeSameReset &&
        checkReset(reading, now: now) is ResetConfirmed;
  }
  return false;
}
