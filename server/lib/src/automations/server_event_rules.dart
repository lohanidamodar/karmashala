import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/events.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/scheduler.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused, SessionSent, SessionStatusEntry;
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';

/// Sends [String] text to row [String] the way every other sender does.
typedef SessionMessageSender =
    Future<SessionSent> Function(String sessionId, String text);

/// **Automations that answer events, answered by the server** (slice 5c) —
/// the app's `AutomationEventRouter`, moved: every status move the server
/// keeps is looked at ([observe]); a turn that finished or failed is an event
/// ([automationEventOf]), planned against every enabled rule (the origin
/// chain, the per-rule rate limit — [planAutomationEvent]) and acted on:
/// a new session queued behind its checkout (the scheduler starts it), or the
/// rule's prompt sent to the session the server runs. With every app closed.
class ServerEventRules {
  ServerEventRules({
    required this.automations,
    required this.scheduler,
    required this.preflight,
    required this.sessionOf,
    required this.isLive,
    required this.now,
    required this.newId,
    this.statusOf,
    this.send,
    this.log,
    this.afterRun,
    AutomationRateLimiter? limiter,
  }) : limiter = limiter ?? AutomationRateLimiter();

  final AutomationRecords automations;
  final AutomationScheduler scheduler;
  final UnattendedPreflight preflight;
  final Session? Function(String sessionId) sessionOf;

  /// Whether this server runs row [String] now, over a PTY or ACP.
  final bool Function(String sessionId) isLive;

  /// What the server's reading says row [String]'s agent is doing.
  final AgentStatusReport? Function(String sessionId)? statusOf;
  final DateTime Function() now;
  final String Function() newId;

  /// The server's one send path — the dashboard's and `session_send`'s, which
  /// reaches chat and terminal sessions alike and queues while a turn runs.
  /// Set once the server has built it; null sends nothing.
  SessionMessageSender? send;
  final void Function(String message)? log;

  /// The steps after a run that started nothing: a notify-only rule's.
  final void Function(AutomationRun run)? afterRun;
  final AutomationRateLimiter limiter;

  final Map<AgentSessionKey, AgentActivityStatus> _last = {};
  final Map<AgentSessionKey, bool> _waiting = {};

  /// Events acted on, for tests and diagnostics.
  int fired = 0;

  /// One status move; an event is answered after this turn (it writes).
  void observe(SessionStatusEntry entry) {
    if (entry.session.imported) return;
    final previous = _last[entry.key];
    final wasWaiting = _waiting[entry.key] ?? false;
    _last[entry.key] = entry.report.status;
    _waiting[entry.key] = waitsOnPerson(entry.report);
    final kind = automationEventWithWait(
      previous,
      entry.report,
      wasWaiting: wasWaiting,
    );
    if (kind == null) return;
    final sessionId = entry.openId;
    scheduleMicrotask(() async {
      try {
        await handle(kind, sessionId);
      } on Object catch (error) {
        log?.call('automations: event ${kind.storedName} failed ($error)');
      }
    });
  }

  /// Answers one witnessed event: every rule's verdict, and the actions of
  /// those that fire.
  Future<List<EventRuleVerdict>> handle(
    AutomationEventKind kind,
    String sessionId,
  ) async {
    final session = sessionOf(sessionId);
    if (session == null) return const [];
    final lifetime = automations.originOfSession(sessionId);
    final messaged = automations.messagedOrigin(sessionId, consume: true);
    final event = AutomationEvent(
      kind: kind,
      sessionId: sessionId,
      repositoryId: session.repositoryId,
      at: now(),
      origin: List.unmodifiable([
        ...lifetime,
        for (final id in messaged)
          if (!lifetime.contains(id)) id,
      ]),
    );
    final verdicts = planAutomationEvent(
      rules: automations.eventRules(),
      event: event,
      limiter: limiter,
    );
    for (final verdict in verdicts) {
      switch (verdict.outcome) {
        case EventRuleOutcome.fires:
          fired++;
          await _act(verdict, event, session);
        case EventRuleOutcome.inOriginChain || EventRuleOutcome.rateLimited:
          log?.call(
            'automations: "${verdict.automation.name}" did not answer '
            '${kind.storedName} in $sessionId: ${verdict.reason}',
          );
        case EventRuleOutcome.otherEvent ||
            EventRuleOutcome.otherCheckout ||
            EventRuleOutcome.paused:
          break;
      }
    }
    return verdicts;
  }

  Future<void> _act(
    EventRuleVerdict verdict,
    AutomationEvent event,
    Session session,
  ) async {
    final rule = verdict.automation;
    final run = AutomationRun(
      id: newId(),
      automationId: rule.id,
      scheduledFor: event.at,
      firedAt: now(),
      state: AutomationRunState.running,
      reason: 'Because "${session.title}" ${event.kind.phrase}.',
      origin: verdict.origin,
      eventSessionId: event.sessionId,
    );
    final action = rule.trigger!.action;
    if (action != AutomationEventAction.startSession) {
      final overHour = hourlyRefusal(
        rule,
        recent: automations.runsFor(rule.id, limit: recentRunsToRead(rule)),
        now: run.firedAt,
      );
      if (overHour != null) {
        automations.insertRun(
          run.copyWith(state: AutomationRunState.missed, reason: overHour),
        );
        return;
      }
    }
    switch (action) {
      case AutomationEventAction.startSession:
        // Queued behind the checkout; the scheduler starts it when it is free.
        scheduler.queueEventRun(rule, run);
        await scheduler.drain(rule.repositoryId);
      case AutomationEventAction.messageSession:
        await _message(rule, run, session);
      case AutomationEventAction.notifyOnly:
        final done = run.copyWith(
          state: AutomationRunState.finished,
          finishedAt: now(),
        );
        automations.insertRun(done);
        afterRun?.call(done);
    }
  }

  /// Why a message cannot go into [session] now, or null — the app's
  /// refusals, with "a live pane" read as "a session this server runs".
  ({AutomationRunState state, String reason})? messageRefusal(Session session) {
    if (session.isArchived) {
      return (
        state: AutomationRunState.missed,
        reason: 'The session was archived, so nothing was sent.',
      );
    }
    if (!isLive(session.id)) {
      return (
        state: AutomationRunState.missed,
        reason:
            'The session is not running, and an automation never restarts an '
            'ended session to deliver a message. Nothing was sent.',
      );
    }
    final gate = preflight.refusalForResume(session);
    if (gate != null) {
      return (state: AutomationRunState.failed, reason: gate.reason);
    }
    // A turn that runs again is no refusal: the send path queues behind it.
    final report = statusOf?.call(session.id);
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

  /// Sends the rule's prompt, under its "Sent by automation" line, to
  /// [session]. The chain is recorded first so the turn it causes carries it.
  Future<void> _message(
    Automation rule,
    AutomationRun run,
    Session session,
  ) async {
    final at = now();
    final refusal = messageRefusal(session);
    if (refusal != null) {
      automations.insertRun(
        run.copyWith(
          state: refusal.state,
          reason: '${run.reason} ${refusal.reason}',
          finishedAt: at,
        ),
      );
      return;
    }
    final send = this.send;
    if (send == null) {
      automations.insertRun(
        run.copyWith(
          state: AutomationRunState.failed,
          reason:
              '${run.reason} This server has no way to send messages yet, '
              'so nothing was sent.',
          finishedAt: at,
        ),
      );
      return;
    }
    automations.markMessaged(session.id, run.origin, at);
    String reason;
    var state = AutomationRunState.finished;
    try {
      final sent = await send(session.id, automationMessage(rule));
      reason = sent.via == SessionSent.queuedVia
          ? '${run.reason} Queued "${rule.prompt}" for "${session.title}", '
                'which was working; it goes in when that turn ends'
                '${sent.position == null ? '' : ' (number ${sent.position} '
                          'in its queue)'}.'
          : '${run.reason} Sent "${rule.prompt}" to "${session.title}".';
    } on Object catch (error) {
      automations.clearMessaged(session.id);
      state = AutomationRunState.failed;
      final words = error is DataRefused ? error.message : '$error';
      reason = '${run.reason} The send was refused: $words.';
    }
    automations.insertRun(
      run.copyWith(state: state, reason: reason, finishedAt: now()),
    );
  }
}
