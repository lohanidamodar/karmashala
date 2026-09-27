import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/events.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../data/automations_data.dart';
import 'unattended_preflight.dart';

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

/// **"What would fire if this happened?"** — every event rule's answer to one
/// event, over this client's copy of the rules, touching nothing: no pending
/// chain spent, no run written, nothing sent. Presentation only: the rules
/// fire at the server (slice 5c), which witnesses every status and keeps the
/// one rate-limit budget; this rehearsal starts each rule's budget fresh.
class AutomationRehearsal {
  const AutomationRehearsal(this._ref);

  final Ref _ref;

  AutomationsData get _dao => _ref.read(automationsDataProvider);

  /// The event as it stands for [sessionId], origin resolved (never spent).
  AutomationEvent? eventFor(AutomationEventKind kind, String sessionId) {
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return null;
    final lifetime = _dao.originOfSession(sessionId);
    final messaged = _dao.messagedOrigin(sessionId);
    return AutomationEvent(
      kind: kind,
      sessionId: sessionId,
      repositoryId: session.repositoryId,
      at: _ref.read(clockProvider).nowUtc(),
      origin: List.unmodifiable([
        ...lifetime,
        for (final id in messaged)
          if (!lifetime.contains(id)) id,
      ]),
    );
  }

  /// What [event] would do.
  List<EventRuleRehearsal> dryRun(AutomationEvent event) => [
    for (final verdict in planAutomationEvent(
      rules: _dao.eventRules(),
      event: event,
      limiter: AutomationRateLimiter(),
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
        _ref.read(sessionsDataProvider).getById(event.sessionId)?.title ??
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
        _ref.read(sessionsDataProvider).getById(event.sessionId),
      )?.reason;
    }
    return _ref.read(unattendedPreflightProvider).refusalFor(rule)?.reason;
  }

  /// Why a message could not go into [session] now, or null — the words the
  /// server would record, read here for the rehearsal.
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
    if (_ref.read(sessionLauncherProvider).livePaneFor(session.id) == null) {
      return (
        state: AutomationRunState.missed,
        reason:
            'The session has no live pane, and an automation never restarts '
            'an ended session to deliver a message. Nothing was sent.',
      );
    }
    final gate = _ref
        .read(unattendedPreflightProvider)
        .refusalForResume(session);
    if (gate != null) {
      return (state: AutomationRunState.failed, reason: gate.reason);
    }
    final report = _ref.read(sessionStatusLookupProvider)(session.id);
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
}

final automationRehearsalProvider = Provider<AutomationRehearsal>(
  AutomationRehearsal.new,
);
