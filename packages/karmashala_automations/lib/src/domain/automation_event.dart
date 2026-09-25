import 'automation.dart';
import 'automation_trigger.dart';

/// One observed moment an event-triggered automation may answer.
class AutomationEvent {
  const AutomationEvent({
    required this.kind,
    required this.sessionId,
    required this.repositoryId,
    required this.at,
    this.origin = const [],
  });

  final AutomationEventKind kind;

  /// The workspace session it happened in.
  final String sessionId;

  /// The checkout that session belongs to; a rule answers only its own.
  final String repositoryId;

  final DateTime at;

  /// The automations whose actions led to this event, oldest first. Empty for
  /// one a person caused.
  final List<String> origin;
}

/// The backstop behind the origin chain: at most one fire per rule per second.
const Duration kDefaultEventRateWindow = Duration(seconds: 1);
const int kDefaultEventRateLimit = 1;

/// Per-rule rate limiting, in memory. [allows] never mutates, so a dry run can
/// ask without spending anything.
class AutomationRateLimiter {
  AutomationRateLimiter({
    this.window = kDefaultEventRateWindow,
    this.limit = kDefaultEventRateLimit,
  });

  final Duration window;
  final int limit;
  final Map<String, List<DateTime>> _fires = {};

  bool allows(String ruleId, DateTime now) =>
      _recent(ruleId, now).length < limit;

  void record(String ruleId, DateTime now) {
    final recent = _recent(ruleId, now)..add(now);
    _fires[ruleId] = recent;
  }

  List<DateTime> _recent(String ruleId, DateTime now) => [
    for (final at in _fires[ruleId] ?? const <DateTime>[])
      if (now.difference(at) < window) at,
  ];
}

/// Why a rule did or did not answer an event.
enum EventRuleOutcome {
  fires,

  /// The rule listens for a different event.
  otherEvent,

  /// The event happened in a checkout this rule was not armed in.
  otherCheckout,

  paused,

  /// This rule's own action led to the event — firing again is the loop.
  inOriginChain,

  rateLimited,
}

/// One rule's answer to one event, with the sentence that explains it.
class EventRuleVerdict {
  const EventRuleVerdict({
    required this.automation,
    required this.outcome,
    required this.reason,
    required this.origin,
  });

  final Automation automation;
  final EventRuleOutcome outcome;
  final String reason;

  /// The chain an action taken for this verdict carries: the event's own
  /// origin with this rule appended.
  final List<String> origin;

  bool get fires => outcome == EventRuleOutcome.fires;
}

/// Every event-triggered rule's answer to [event]. Only a real run ([dryRun]
/// false) spends rate-limit budget; a dry run leaves [limiter] exactly as it
/// found it.
List<EventRuleVerdict> planAutomationEvent({
  required Iterable<Automation> rules,
  required AutomationEvent event,
  required AutomationRateLimiter limiter,
  bool dryRun = false,
}) {
  final verdicts = <EventRuleVerdict>[];
  for (final rule in rules) {
    final trigger = rule.trigger;
    if (trigger == null) continue;
    final origin = List<String>.unmodifiable([...event.origin, rule.id]);
    EventRuleVerdict verdict(EventRuleOutcome outcome, String reason) =>
        EventRuleVerdict(
          automation: rule,
          outcome: outcome,
          reason: reason,
          origin: origin,
        );
    if (trigger.kind != event.kind) {
      verdicts.add(
        verdict(
          EventRuleOutcome.otherEvent,
          'Listens for "${trigger.kind.label.toLowerCase()}", not this.',
        ),
      );
    } else if (rule.repositoryId != event.repositoryId) {
      verdicts.add(
        verdict(EventRuleOutcome.otherCheckout, 'Armed in another checkout.'),
      );
    } else if (!rule.enabled) {
      verdicts.add(verdict(EventRuleOutcome.paused, 'Paused.'));
    } else if (event.origin.contains(rule.id)) {
      verdicts.add(
        verdict(
          EventRuleOutcome.inOriginChain,
          'Skipped: this event follows from "${rule.name}"\'s own action, and '
          'answering it again is how a rule loops on itself.',
        ),
      );
    } else if (!limiter.allows(rule.id, event.at)) {
      verdicts.add(
        verdict(
          EventRuleOutcome.rateLimited,
          'Skipped: over its limit of ${limiter.limit} per '
          '${_window(limiter.window)} — the backstop against a loop the '
          'origin chain does not catch.',
        ),
      );
    } else {
      if (!dryRun) limiter.record(rule.id, event.at);
      verdicts.add(verdict(EventRuleOutcome.fires, 'Fires.'));
    }
  }
  return verdicts;
}

String _window(Duration window) => window.inMilliseconds % 1000 == 0
    ? (window.inSeconds == 1 ? 'second' : '${window.inSeconds} seconds')
    : '${window.inMilliseconds} ms';
