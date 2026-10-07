/// The words a person reads for an automation: its schedule, its trigger,
/// and the whole thing in one line. Never raw cron.
library;

import 'automation.dart';
import 'automation_steps.dart';
import 'automation_trigger.dart';
import 'cron_schedule.dart';

const _dayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _dayPlural = [
  'Mondays',
  'Tuesdays',
  'Wednesdays',
  'Thursdays',
  'Fridays',
  'Saturdays',
  'Sundays',
];
const _monthShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const Set<int> kWeekdays = {1, 2, 3, 4, 5};
const Set<int> kEveryDay = {1, 2, 3, 4, 5, 6, 7};

String _two(int n) => n.toString().padLeft(2, '0');

/// `09:05`.
String clockWords(int hour, int minute) => '${_two(hour)}:${_two(minute)}';

/// "Every day", "Weekdays", "Weekends", "Mondays", "Mon, Wed and Fri" — for
/// ISO weekdays, Monday 1 to Sunday 7.
String weekdayWords(Set<int> days) {
  if (days.length == 7) return 'Every day';
  if (days.length == 5 && days.containsAll(kWeekdays)) return 'Weekdays';
  if (days.length == 2 && days.containsAll(const {6, 7})) return 'Weekends';
  final sorted = [...days]..sort();
  if (sorted.isEmpty) return 'No day';
  if (sorted.length == 1) return _dayPlural[sorted.single - 1];
  final names = [for (final d in sorted) _dayShort[d - 1]];
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// A time on some weekdays — the shape the editor writes — or null when
/// [cron] says something else.
({int hour, int minute, Set<int> days})? timeOfWeekCron(String cron) {
  final fields = cron.trim().split(RegExp(r'\s+'));
  if (fields.length != 5) return null;
  final minute = int.tryParse(fields[0]);
  final hour = int.tryParse(fields[1]);
  if (minute == null || hour == null) return null;
  if (minute < 0 || minute > 59 || hour < 0 || hour > 23) return null;
  if (fields[2] != '*' || fields[3] != '*') return null;
  final days = _weekdaysOf(fields[4]);
  if (days == null || days.isEmpty) return null;
  return (hour: hour, minute: minute, days: days);
}

/// The cron the editor writes for a time on [days] (ISO weekdays).
String cronForTimeOfWeek(int hour, int minute, Set<int> days) {
  final sorted = [...days]..sort();
  final field = sorted.length == 7
      ? '*'
      : sorted.length == 5 && days.containsAll(kWeekdays)
      ? '1-5'
      : sorted.map((d) => d == 7 ? 0 : d).join(',');
  return '$minute $hour * * $field';
}

Set<int>? _weekdaysOf(String field) {
  if (field == '*') return {...kEveryDay};
  final days = <int>{};
  for (final part in field.split(',')) {
    final range = part.split('-');
    final low = int.tryParse(range.first);
    final high = range.length == 2 ? int.tryParse(range.last) : low;
    if (low == null || high == null || range.length > 2) return null;
    if (low < 0 || high > 7 || low > high) return null;
    for (var d = low; d <= high; d++) {
      days.add(d == 0 ? 7 : d);
    }
  }
  return days;
}

/// [cron] in words, or why it cannot be read. Shapes the editor writes read
/// exactly; anything else reads by when it next comes round.
String cronWords(String cron, {DateTime? now}) {
  final week = timeOfWeekCron(cron);
  if (week != null) {
    return '${weekdayWords(week.days)} at ${clockWords(week.hour, week.minute)}';
  }
  final fields = cron.trim().split(RegExp(r'\s+'));
  if (fields.length == 5 && fields.skip(1).every((f) => f == '*')) {
    final minute = int.tryParse(fields[0]);
    if (minute != null) {
      return minute == 0
          ? 'Every hour, on the hour'
          : 'Every hour at ${_two(minute)} past';
    }
    final step = RegExp(r'^\*/(\d+)$').firstMatch(fields[0]);
    if (step != null) return 'Every ${step[1]} minutes';
  }
  final schedule = CronSchedule.parse(cron);
  if (schedule == null) return 'A schedule this build cannot read';
  final next = now == null ? null : schedule.nextAfter(now);
  return next == null
      ? 'On a schedule of its own'
      : 'On a schedule of its own, next ${momentWords(next.toLocal())}';
}

/// "Tue 7 Oct at 09:00".
String momentWords(DateTime local) =>
    '${_dayShort[local.weekday - 1]} ${local.day} ${_monthShort[local.month - 1]} '
    'at ${clockWords(local.hour, local.minute)}';

/// "Every 90 min after each run".
String gapWords(Duration gap) {
  if (gap.inMinutes % 60 == 0 && gap.inHours >= 1) {
    return gap.inHours == 1
        ? 'Every hour after each run'
        : 'Every ${gap.inHours} hours after each run';
  }
  return 'Every ${gap.inMinutes} min after each run';
}

/// When [automation] starts, in words, without the checkout.
String triggerWords(Automation automation, {DateTime? now}) {
  if (automation.webhook != null) {
    final signed = automation.webhook!.requireSignature ? ' (signed)' : '';
    return 'When its webhook URL is called$signed';
  }
  if (automation.github case final github?) {
    return 'When ${github.kind.phrase} in ${github.repository}';
  }
  final trigger = automation.trigger;
  if (trigger != null) return 'When ${_eventWords(trigger.kind)}';
  final schedule = automation.schedule;
  if (schedule.isOnce) {
    return 'Once, ${momentWords(schedule.firesAt!.toLocal())}';
  }
  if (schedule.isInterval) return gapWords(schedule.gap!);
  return cronWords(schedule.cron!, now: now);
}

String _eventWords(AutomationEventKind kind) => switch (kind) {
  AutomationEventKind.turnFinished => 'a session finishes a turn',
  AutomationEventKind.turnFailed => 'a session\'s turn fails',
  AutomationEventKind.needsYou => 'a session needs you',
};

/// The whole automation in one line: "Weekdays at 09:00, in app → start
/// Claude Code in a worktree → check the result → if it fails, tell the agent".
String automationWords(
  Automation automation, {
  required String checkout,
  required String agent,
  DateTime? now,
}) {
  final parts = <String>[
    '${triggerWords(automation, now: now)}, in $checkout',
    switch (automation.github?.action ?? automation.trigger?.action) {
      AutomationEventAction.notifyOnly => 'start nothing',
      AutomationEventAction.messageSession when automation.isGithub =>
        'tell the session on its branch, or start $agent there',
      AutomationEventAction.messageSession => 'tell that session',
      _ => 'start $agent${automation.worktree ? ' in a worktree' : ''}',
    },
    for (final step in automation.steps.after) _stepWords(step),
  ];
  return parts.join(' → ');
}

String _stepWords(AutomationStep step) {
  final what = switch (step.kind) {
    AutomationStepKind.check => 'check the result',
    AutomationStepKind.command => 'run a command',
    AutomationStepKind.webhook => 'call a webhook',
    AutomationStepKind.tell => 'tell the agent',
    AutomationStepKind.notify => 'notify me',
  };
  if (step.kind == AutomationStepKind.check) return what;
  return switch (step.when) {
    AutomationStepWhen.success => 'if it succeeded, $what',
    AutomationStepWhen.failure => 'if it fails, $what',
    AutomationStepWhen.always => 'always $what',
  };
}

/// What a list row says about the next run: a schedule in words, "Listening",
/// "On the next event", or why it will not run.
String nextRunWords(Automation automation, {required DateTime now}) {
  if (!automation.enabled) {
    return automation.disabledReason == null
        ? 'Paused'
        : 'Stopped after failures';
  }
  if (automation.webhook != null) return 'Listening';
  if (automation.github != null) return 'Watching GitHub';
  if (automation.trigger != null) return 'On the next event';
  final schedule = automation.schedule;
  if (schedule.isOnce) {
    return schedule.firesAt!.isAfter(now)
        ? momentWords(schedule.firesAt!.toLocal())
        : 'Done';
  }
  return triggerWords(automation, now: now);
}
