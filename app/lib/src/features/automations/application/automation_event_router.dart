import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/events.dart';

import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../notifications/application/session_status_registry.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../data/automations_data.dart';
import 'unattended_preflight.dart';
import 'usage_limit_watcher.dart' show sessionStatusChangesProvider;

/// Per-rule rate limiting, one per process. A provider so a test can read what
/// a dry run left behind.
final automationRateLimiterProvider = Provider<AutomationRateLimiter>(
  (ref) => AutomationRateLimiter(),
);

/// The event [report] is, given the status last witnessed before it — or null.
///
/// Stricter than the notification policy on purpose: a turn only *finished* if
/// it was seen working or waiting first, and a report carrying a session ending
/// (`SessionEnd` — a `/clear`, a `/resume`, a quit) is never a turn at all.
AutomationEventKind? automationEventOf(
  AgentActivityStatus? previous,
  AgentStatusReport report,
) {
  if (report.ending != null) return null;
  if (previous == null || previous == AgentActivityStatus.unknown) return null;
  if (previous == report.status) return null;
  return switch (report.status) {
    AgentActivityStatus.idle
        when previous == AgentActivityStatus.working ||
            previous == AgentActivityStatus.awaitingApproval =>
      AutomationEventKind.turnFinished,
    AgentActivityStatus.failed => AutomationEventKind.turnFailed,
    _ => null,
  };
}

/// One rule's dry-run answer: the verdict, and what firing would do.
class EventRuleRehearsal {
  const EventRuleRehearsal({
    required this.verdict,
    required this.action,
    this.refusal,
  });

  final EventRuleVerdict verdict;

  /// What the rule's action would do, in a sentence.
  final String action;

  /// Why the action would be refused at fire time, when it would be.
  final String? refusal;
}

/// Turns witnessed status changes into automation events and answers them.
/// Must be watched (Riverpod 3), like the scheduler.
class AutomationEventRouter extends Notifier<int> {
  static final _log = AppLogger.named('automations');

  final Map<AgentSessionKey, AgentActivityStatus> _last = {};
  int _fired = 0;
  bool _disposed = false;

  @override
  int build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final changes = ref.watch(sessionStatusChangesProvider).listen(_observe);
    ref.onDispose(changes.cancel);
    return _fired;
  }

  AutomationsData get _dao => ref.read(automationsDataProvider);
  DateTime get _now => ref.read(clockProvider).nowUtc();

  void _observe(SessionStatusEntry entry) {
    if (entry.session.imported) return;
    final previous = _last[entry.key];
    _last[entry.key] = entry.report.status;
    final kind = automationEventOf(previous, entry.report);
    if (kind == null) return;
    final sessionId = entry.session.openId;
    // The stream is synchronous and may fire mid-build; answering writes.
    unawaited(
      Future<void>.microtask(() async {
        if (_disposed) return;
        try {
          await handle(kind, sessionId);
        } on Object catch (error, stack) {
          _log.warning(
            'automations: event ${kind.storedName} failed',
            error,
            stack,
          );
        }
      }),
    );
  }

  /// The event as it stands for [sessionId], origin resolved. [consume] spends
  /// a pending message's chain, which only a real event may do.
  AutomationEvent? eventFor(
    AutomationEventKind kind,
    String sessionId, {
    bool consume = false,
  }) {
    final session = ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return null;
    final lifetime = _dao.originOfSession(sessionId);
    final messaged = _dao.messagedOrigin(sessionId, consume: consume);
    return AutomationEvent(
      kind: kind,
      sessionId: sessionId,
      repositoryId: session.repositoryId,
      at: _now,
      origin: List.unmodifiable([
        ...lifetime,
        for (final id in messaged)
          if (!lifetime.contains(id)) id,
      ]),
    );
  }

  /// Answers one witnessed event: every rule's verdict, and the actions of
  /// those that fire.
  Future<List<EventRuleVerdict>> handle(
    AutomationEventKind kind,
    String sessionId,
  ) async {
    final event = eventFor(kind, sessionId, consume: true);
    if (event == null) return const [];
    final verdicts = planAutomationEvent(
      rules: _dao.eventRules(),
      event: event,
      limiter: ref.read(automationRateLimiterProvider),
    );
    for (final verdict in verdicts) {
      switch (verdict.outcome) {
        case EventRuleOutcome.fires:
          await _act(verdict, event);
        case EventRuleOutcome.inOriginChain:
        case EventRuleOutcome.rateLimited:
          _log.info(
            'automations: "${verdict.automation.name}" did not answer '
            '${kind.storedName} in $sessionId: ${verdict.reason}',
          );
        case EventRuleOutcome.otherEvent:
        case EventRuleOutcome.otherCheckout:
        case EventRuleOutcome.paused:
          break;
      }
    }
    if (verdicts.any((v) => v.fires) && !_disposed) state = ++_fired;
    return verdicts;
  }

  /// What [event] would do, touching nothing: no pending chain is spent, no
  /// rate-limit budget is used, no run is written and nothing is sent.
  List<EventRuleRehearsal> dryRun(AutomationEvent event) => [
    for (final verdict in planAutomationEvent(
      rules: _dao.eventRules(),
      event: event,
      limiter: ref.read(automationRateLimiterProvider),
      dryRun: true,
    ))
      EventRuleRehearsal(
        verdict: verdict,
        action: _describeAction(verdict.automation, event),
        refusal: verdict.fires ? _refusalFor(verdict.automation, event) : null,
      ),
  ];

  String _describeAction(Automation rule, AutomationEvent event) {
    final title =
        ref.read(sessionsDataProvider).getById(event.sessionId)?.title ??
        'that session';
    return switch (rule.trigger?.action) {
      AutomationEventAction.messageSession =>
        'Would send "${rule.prompt}" to "$title".',
      _ => 'Would start a new session in this checkout told "${rule.prompt}".',
    };
  }

  String? _refusalFor(Automation rule, AutomationEvent event) {
    if (rule.trigger?.action == AutomationEventAction.messageSession) {
      return messageRefusal(
        ref.read(sessionsDataProvider).getById(event.sessionId),
      )?.reason;
    }
    return ref.read(unattendedPreflightProvider).refusalFor(rule)?.reason;
  }

  Future<void> _act(EventRuleVerdict verdict, AutomationEvent event) async {
    final rule = verdict.automation;
    final session = ref.read(sessionsDataProvider).getById(event.sessionId);
    final run = AutomationRun(
      id: ref.read(idGeneratorProvider).newId(),
      automationId: rule.id,
      scheduledFor: event.at,
      firedAt: _now,
      state: AutomationRunState.running,
      reason:
          'Because "${session?.title ?? event.sessionId}" '
          '${event.kind.phrase}.',
      origin: verdict.origin,
      eventSessionId: event.sessionId,
    );
    switch (rule.trigger!.action) {
      case AutomationEventAction.startSession:
        // Queued at the server, which starts it when the checkout is free.
        await _dao.queueEventRun(run);
      case AutomationEventAction.messageSession:
        _message(rule, run, session);
    }
  }

  /// Why a message cannot go into [session] now, or null. The same refusals a
  /// scheduled resume makes, and one more: an ended session is never restarted
  /// by an event.
  ({AutomationRunState state, String reason})? messageRefusal(
    Session? session,
  ) {
    if (session == null) {
      return (
        state: AutomationRunState.failed,
        reason: 'The session is no longer in the workspace.',
      );
    }
    if (session.isArchived) {
      return (
        state: AutomationRunState.missed,
        reason: 'The session was archived, so nothing was sent.',
      );
    }
    if (ref.read(sessionLauncherProvider).livePaneFor(session.id) == null) {
      return (
        state: AutomationRunState.missed,
        reason:
            'The session has no live pane, and an automation never restarts '
            'an ended session to deliver a message. Nothing was sent.',
      );
    }
    final gate = ref
        .read(unattendedPreflightProvider)
        .refusalForResume(session);
    if (gate != null) {
      return (state: AutomationRunState.failed, reason: gate.reason);
    }
    final report = ref.read(sessionStatusLookupProvider)(session.id);
    if (report?.status == AgentActivityStatus.working) {
      return (
        state: AutomationRunState.missed,
        reason: 'The session was working again by then, so nothing was sent.',
      );
    }
    if (report != null && (report.hasOpenPrompt || report.hasOpenQuestion)) {
      return (
        state: AutomationRunState.missed,
        reason:
            'The agent has a prompt open, and a message typed there would '
            'answer it. Nothing was sent.',
      );
    }
    return null;
  }

  /// Types the rule's prompt into [session] — no focus moves, nothing is
  /// selected. The chain is recorded first so the turn it causes carries it.
  void _message(Automation rule, AutomationRun run, Session? session) {
    final now = _now;
    final refusal = messageRefusal(session);
    if (refusal != null) {
      _dao.insertRun(
        run.copyWith(
          state: refusal.state,
          reason: '${run.reason} ${refusal.reason}',
          finishedAt: now,
        ),
      );
      return;
    }
    final target = session!;
    _dao.markMessaged(target.id, run.origin, now);
    final sent = ref
        .read(sessionLauncherProvider)
        .sendTo(target.id, automationMessage(rule));
    if (!sent) _dao.clearMessaged(target.id);
    _dao.insertRun(
      run.copyWith(
        state: sent ? AutomationRunState.finished : AutomationRunState.failed,
        reason: sent
            ? '${run.reason} Sent "${rule.prompt}" to "${target.title}".'
            : '${run.reason} The session had no live pane to type into, so '
                  'nothing was sent.',
        finishedAt: now,
      ),
    );
  }
}

/// What an event rule types: its prompt, with who sent it on the same line so
/// the agent and the person reading the pane both know it was not typed.
String automationMessage(Automation rule) =>
    '[from the Karmashala automation "${rule.name}"] ${rule.prompt}';

final automationEventRouterProvider =
    NotifierProvider<AutomationEventRouter, int>(AutomationEventRouter.new);
