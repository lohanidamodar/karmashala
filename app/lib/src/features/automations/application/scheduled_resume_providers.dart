import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/foundation.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/presentation/usage_chip.dart' show formatResetClock;
import '../../environments/application/environment_providers.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/usage_limit_settings.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/unattended.dart';
import 'automation_providers.dart';
import 'unattended_preflight.dart';

final scheduledResumeDaoProvider = Provider<ScheduledResumeDao>(
  (ref) => ScheduledResumeDao(ref.watch(databaseProvider)),
);

/// Every resume still waiting, soonest first. Shares the automations revision:
/// the one scheduler re-arms on it, so a write here moves its timer too.
final liveScheduledResumesProvider = Provider<List<ScheduledResume>>((ref) {
  ref.watch(automationsRevisionProvider);
  return ref.watch(scheduledResumeDaoProvider).live();
});

final recentScheduledResumesProvider = Provider<List<ScheduledResume>>((ref) {
  ref.watch(automationsRevisionProvider);
  return ref.watch(scheduledResumeDaoProvider).recentEnded();
});

/// What a session row and its bar say about a waiting resume. A value type, so
/// a bump that did not change this session's words rebuilds nothing.
@immutable
class ResumeBadge {
  const ResumeBadge({
    required this.resumeId,
    required this.label,
    required this.tooltip,
    required this.queued,
  });

  final String resumeId;

  /// `resumes 14:05`. An absolute time on purpose: it does not tick.
  final String label;
  final String tooltip;
  final bool queued;

  @override
  bool operator ==(Object other) =>
      other is ResumeBadge &&
      other.resumeId == resumeId &&
      other.label == label &&
      other.tooltip == tooltip &&
      other.queued == queued;

  @override
  int get hashCode => Object.hash(resumeId, label, tooltip, queued);
}

/// Every waiting resume's badge by session id: one query per write, however
/// many rows are on screen.
final resumeBadgesProvider = Provider<Map<String, ResumeBadge>>((ref) {
  final now = ref.read(clockProvider).nowUtc().toLocal();
  return {
    for (final resume in ref.watch(liveScheduledResumesProvider))
      resume.sessionId: ResumeBadge(
        resumeId: resume.id,
        label: switch (resume.state) {
          ScheduledResumeState.queued => 'resume waiting',
          ScheduledResumeState.firing => 'resuming',
          _ => 'resumes ${formatResetClock(resume.fireAt, now)}',
        },
        tooltip: describeScheduledResume(resume, now: now),
        queued: resume.state == ScheduledResumeState.queued,
      ),
  };
});

/// One session's badge. Selected out of the map, so a row rebuilds only when
/// its own words change.
final sessionResumeBadgeProvider = Provider.autoDispose
    .family<ResumeBadge?, String>(
      (ref, sessionId) =>
          ref.watch(resumeBadgesProvider.select((badges) => badges[sessionId])),
    );

/// One sentence or two: when, on what, and what will be said.
String describeScheduledResume(
  ScheduledResume resume, {
  required DateTime now,
}) {
  final when = formatResetClock(resume.fireAt, now);
  final on = resume.windowLabel == null
      ? 'at a time you chose'
      : 'when the ${resume.windowLabel} window resets';
  final says = resume.sendsMessage
      ? 'then sends "${resume.message.trim()}"'
      : 'and sends nothing';
  final base = 'Resumes $when, $on, $says.';
  return resume.reason.isEmpty ? base : '$base ${resume.reason}';
}

/// Whether, and against which account, a session's usage can be read.
class ResumeUsageAccess {
  const ResumeUsageAccess({
    required this.installation,
    required this.accountKey,
    this.unreadableBecause,
  });

  final AgentInstallation? installation;
  final String accountKey;

  /// Why only a chosen time can be offered, or null when usage can be read.
  final String? unreadableBecause;

  bool get readable => unreadableBecause == null && installation != null;
}

ResumeUsageAccess resumeUsageAccess(Ref ref, Session session) {
  final installation = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId);
  if (installation == null) {
    return const ResumeUsageAccess(
      installation: null,
      accountKey: '',
      unreadableBecause:
          'The agent this session ran on is no longer installed, so there is '
          'no account to read limits for.',
    );
  }
  final key = usageAccountKey(installation);
  final registry = ref.read(agentRegistryProvider);
  final name = registry.displayNameFor(installation.agentId);
  final usage = registry.adapterFor(installation.agentId)?.usage;
  if (usage == null || !usage.reportsResetTime) {
    return ResumeUsageAccess(
      installation: installation,
      accountKey: key,
      unreadableBecause:
          '$name reports no quota with a reset time, so only a time you '
          'choose can be used.',
    );
  }
  final environment = ref
      .read(executionEnvironmentDaoProvider)
      .getById(installation.environmentId);
  if (environment == null || !cliStoreIsReachable(environment.kind)) {
    return ResumeUsageAccess(
      installation: installation,
      accountKey: key,
      unreadableBecause:
          "This session's agent signs in on "
          '${environment?.name ?? 'another machine'}, and its limits cannot '
          'be read from here, so only a time you choose can be used.',
    );
  }
  return ResumeUsageAccess(installation: installation, accountKey: key);
}

/// [resumeUsageAccess] for one session, for the dialog. Follows its row.
final resumeUsageAccessProvider = Provider.autoDispose
    .family<ResumeUsageAccess?, String>((ref, sessionId) {
      ref.watchSession(sessionId);
      final session = ref.read(sessionsDataProvider).getById(sessionId);
      return session == null ? null : resumeUsageAccess(ref, session);
    });

/// Thrown when a resume may not be armed. [reason] is the gate's own sentence.
class ScheduledResumeRefused implements Exception {
  const ScheduledResumeRefused(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// What the user chose in the dialog, or what one click's defaults stand for.
class ResumeRequest {
  const ResumeRequest({
    required this.sessionId,
    required this.fireAt,
    this.windowLabel,
    this.resetsAt,
    this.message = kDefaultResumeMessage,
    this.permissionMode,
    this.notify = true,
    this.latePolicy = ResumeLatePolicy.ask,
    this.scheduledBy = 'the user',
  });

  /// Waits on [window]'s reset, which must name one.
  ResumeRequest.atReset({
    required this.sessionId,
    required UsageWindow window,
    this.message = kDefaultResumeMessage,
    this.permissionMode,
    this.notify = true,
    this.latePolicy = ResumeLatePolicy.ask,
    this.scheduledBy = 'the user',
  }) : windowLabel = window.label,
       resetsAt = window.resetsAt,
       fireAt = window.resetsAt!.add(kResumeResetMargin);

  final String sessionId;
  final DateTime fireAt;
  final String? windowLabel;
  final DateTime? resetsAt;
  final String message;
  final String? permissionMode;
  final bool notify;
  final ResumeLatePolicy latePolicy;
  final String scheduledBy;
}

/// Arms, replaces and cancels scheduled resumes. A person's act, or the
/// setting a person chose — no MCP tool reaches it.
class ScheduledResumeController {
  ScheduledResumeController(this._ref);

  final Ref _ref;

  ScheduledResumeDao get _dao => _ref.read(scheduledResumeDaoProvider);
  DateTime get _now => _ref.read(clockProvider).nowUtc();

  /// Why [sessionId] may not be resumed unattended under [permissionMode].
  UnattendedRefusal? refusalFor(String sessionId, {String? permissionMode}) {
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return null;
    return _ref
        .read(unattendedPreflightProvider)
        .refusalForResume(session, permissionMode: permissionMode);
  }

  /// Arms [request], replacing whatever its session had waiting. Throws
  /// [ScheduledResumeRefused] with the gate's sentence when it may not be.
  ScheduledResume schedule(ResumeRequest request) {
    final session = _ref.read(sessionsDataProvider).getById(request.sessionId);
    if (session == null) {
      throw const ScheduledResumeRefused(
        'This session is no longer in the workspace.',
      );
    }
    final refusal = refusalFor(
      session.id,
      permissionMode: request.permissionMode,
    );
    if (refusal != null) throw ScheduledResumeRefused(refusal.reason);

    final access = resumeUsageAccess(_ref, session);
    final installation = access.installation;
    final remembered = installation == null || !access.readable
        ? null
        : _ref.read(agentUsageServiceProvider).remembered(installation);
    final now = _now;
    final resume = ScheduledResume(
      id: _ref.read(idGeneratorProvider).newId(),
      sessionId: session.id,
      accountKey: access.accountKey,
      accountEmail: remembered?.email,
      windowLabel: request.windowLabel,
      resetsAt: request.resetsAt?.toUtc(),
      fireAt: request.fireAt.toUtc(),
      message: request.message.trim(),
      permissionMode: request.permissionMode,
      notify: request.notify,
      latePolicy: request.latePolicy,
      state: ScheduledResumeState.pending,
      liveWhenScheduled:
          _ref.read(sessionLauncherProvider).livePaneFor(session.id) != null,
      scheduledBy: request.scheduledBy,
      scheduledAt: now,
    );
    _dao.replaceFor(resume, now: now);
    if (installation != null) {
      _ref
          .read(settingsControllerProvider.notifier)
          .rememberResumeMessage(installation.agentId, resume.message);
    }
    _changed(resume.sessionId);
    return resume;
  }

  /// Ends the live resume for [sessionId], if it has one that has not started.
  bool cancelFor(String sessionId, {String reason = 'Cancelled by you.'}) {
    final live = _dao.liveFor(sessionId);
    if (live == null || live.state == ScheduledResumeState.firing) return false;
    end(live, ScheduledResumeState.cancelled, reason);
    return true;
  }

  /// Writes how [resume] ended and tells the surfaces.
  ScheduledResume end(
    ScheduledResume resume,
    ScheduledResumeState state,
    String reason,
  ) {
    final ended = resume.copyWith(
      state: state,
      reason: reason,
      finishedAt: _now,
    );
    _dao.update(ended);
    _changed(ended.sessionId);
    return ended;
  }

  /// Puts [resume] back to wait for [fireAt].
  ScheduledResume reschedule(
    ScheduledResume resume, {
    required DateTime fireAt,
    required String reason,
    DateTime? resetsAt,
    int? attempts,
    String? accountKey,
    String? accountEmail,
  }) {
    final waiting = resume.copyWith(
      state: ScheduledResumeState.pending,
      fireAt: fireAt.toUtc(),
      resetsAt: resetsAt?.toUtc(),
      clearResetsAt: resetsAt == null,
      reason: reason,
      attempts: attempts,
      accountKey: accountKey,
      accountEmail: accountEmail,
    );
    _dao.update(waiting);
    _changed(waiting.sessionId);
    return waiting;
  }

  /// Arms [missed] again for this moment: what "ask me" asked for.
  ScheduledResume runNow(ScheduledResume missed) => schedule(
    ResumeRequest(
      sessionId: missed.sessionId,
      fireAt: _now,
      windowLabel: missed.windowLabel,
      resetsAt: missed.resetsAt,
      message: missed.message,
      permissionMode: missed.permissionMode,
      notify: missed.notify,
      // Asked for by hand, so it is not missed a second time.
      latePolicy: ResumeLatePolicy.resume,
      scheduledBy: missed.scheduledBy,
    ),
  );

  void forget(String id) {
    _dao.delete(id);
    _changed();
  }

  void _changed([String? sessionId]) {
    _ref.read(automationsRevisionProvider.notifier).bump();
    // The session's own row moved too: that is what a paired phone hears.
    if (sessionId != null) {
      _ref.publishSessionChange(SessionChange.reconfigured(sessionId));
    }
  }
}

final scheduledResumeControllerProvider = Provider<ScheduledResumeController>(
  ScheduledResumeController.new,
);
