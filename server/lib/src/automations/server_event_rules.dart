import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/events.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/scheduler.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionStatusEntry;
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';

import '../domain/host_session.dart';

/// **Automations that answer events, answered by the server** (slice 5c) —
/// the app's `AutomationEventRouter`, moved: every status move the server
/// keeps is looked at ([observe]); a turn that finished or failed is an event
/// ([automationEventOf]), planned against every enabled rule (the origin
/// chain, the per-rule rate limit — [planAutomationEvent]) and acted on:
/// a new session queued behind its checkout (the scheduler starts it), or the
/// rule's prompt typed into the session the server runs. With every app
/// closed.
class ServerEventRules {
  ServerEventRules({
    required this.automations,
    required this.scheduler,
    required this.preflight,
    required this.sessionOf,
    required this.runningOf,
    required this.now,
    required this.newId,
    this.statusOf,
    this.enterDelay = const Duration(milliseconds: 150),
    this.log,
    AutomationRateLimiter? limiter,
  }) : limiter = limiter ?? AutomationRateLimiter();

  final AutomationRecords automations;
  final AutomationScheduler scheduler;
  final UnattendedPreflight preflight;
  final Session? Function(String sessionId) sessionOf;

  /// The running host session of row [String], or null.
  final HostSession? Function(String sessionId) runningOf;

  /// What the server's reading says row [String]'s agent is doing.
  final AgentStatusReport? Function(String sessionId)? statusOf;
  final DateTime Function() now;
  final String Function() newId;
  final Duration enterDelay;
  final void Function(String message)? log;
  final AutomationRateLimiter limiter;

  final Map<AgentSessionKey, AgentActivityStatus> _last = {};

  /// Events acted on, for tests and diagnostics.
  int fired = 0;

  /// One status move; an event is answered after this turn (it writes).
  void observe(SessionStatusEntry entry) {
    if (entry.session.imported) return;
    final previous = _last[entry.key];
    _last[entry.key] = entry.report.status;
    final kind = automationEventOf(previous, entry.report);
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
    switch (rule.trigger!.action) {
      case AutomationEventAction.startSession:
        // Queued behind the checkout; the scheduler starts it when it is free.
        scheduler.queueEventRun(rule, run);
        await scheduler.drain(rule.repositoryId);
      case AutomationEventAction.messageSession:
        _message(rule, run, session);
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
    if (runningOf(session.id) == null) {
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
    final report = statusOf?.call(session.id);
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

  /// Types the rule's prompt into [session], then Enter. The chain is
  /// recorded first so the turn it causes carries it.
  void _message(Automation rule, AutomationRun run, Session session) {
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
    automations.markMessaged(session.id, run.origin, at);
    final running = runningOf(session.id);
    final sent =
        running != null &&
        running.typeAsHost(utf8.encode(automationMessage(rule)));
    if (sent) {
      unawaited(
        Future<void>.delayed(enterDelay, () {
          runningOf(session.id)?.typeAsHost(utf8.encode('\r'));
        }),
      );
    } else {
      automations.clearMessaged(session.id);
    }
    automations.insertRun(
      run.copyWith(
        state: sent ? AutomationRunState.finished : AutomationRunState.failed,
        reason: sent
            ? '${run.reason} Sent "${rule.prompt}" to "${session.title}".'
            : '${run.reason} The session had nothing running to type into, '
                  'so nothing was sent.',
        finishedAt: at,
      ),
    );
  }
}
