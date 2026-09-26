import '../../agents/data/agents_data.dart';
import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/presentation/usage_chip.dart' show formatResetClock;
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/application/session_status_providers.dart';
import 'package:karmashala_automations/resumes.dart';
import 'automation_providers.dart';
import 'scheduled_resume_providers.dart';
import 'scheduled_resume_runner.dart';

/// Keeps waiting resumes honest between arming and firing: a session its user
/// carried on with is let go, and a reading that moves the reset moves the
/// row. Listens only — it never asks for usage. Must be watched (Riverpod 3).
class ScheduledResumeObserver extends Notifier<int> {
  bool _swept = false;
  bool _disposed = false;

  @override
  int build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final revision = ref.watch(automationsRevisionProvider);
    ref.watchSessionKinds(const {
      SessionChangeKind.membership,
      SessionChangeKind.status,
      SessionChangeKind.placement,
    });

    // A fresh reading the server took, whoever asked for it.
    final readings = ref.watch(agentWorkProvider).usage.serverChanges.listen((
      change,
    ) {
      final reading = change.after?.usage;
      if (reading == null) return;
      if (identical(reading, change.before?.usage) ||
          reading.fetchedAt == change.before?.usage?.fetchedAt) {
        return;
      }
      _onReading(change.key, reading);
    });
    ref.onDispose(readings.cancel);

    for (final resume in _waiting()) {
      AgentActivityStatus? before;
      final statuses = ref
          .read(sessionStatusStreamProvider)(resume.sessionId)
          .listen((report) {
            // Into `working`, seen happen: a first observation is not a change.
            final from = before;
            before = report.status;
            if (from == null || from == AgentActivityStatus.working) return;
            if (report.status != AgentActivityStatus.working) return;
            _letGo(
              resume.sessionId,
              'The session carried on before its time, so the scheduled '
              'resume was cancelled and nothing was sent.',
            );
          });
      ref.onDispose(statuses.cancel);
    }

    // Deferred: it writes, and a provider must not change another mid-build.
    unawaited(
      Future<void>.microtask(() {
        if (!_disposed) _sweep();
      }),
    );
    return revision;
  }

  ScheduledResumeController get _controller =>
      ref.read(scheduledResumeControllerProvider);

  List<ScheduledResume> _waiting() => [
    for (final resume in ref.read(resumesDataProvider).live())
      if (resume.state != ScheduledResumeState.firing) resume,
  ];

  void _sweep() {
    final dao = ref.read(resumesDataProvider);
    if (!_swept) {
      _swept = true;
      // Only a process that died mid-resume leaves one here at boot.
      for (final resume in dao.inState(ScheduledResumeState.firing)) {
        final failed = _controller.end(
          resume,
          ScheduledResumeState.failed,
          'Karmashala stopped while this was being resumed. It was not tried '
          'again, because a second try could send the message twice.',
        );
        ref
            .read(resumeAnnouncerProvider)
            .announce(
              failed,
              ref.read(sessionsDataProvider).getById(resume.sessionId),
            );
      }
    }
    final launcher = ref.read(sessionLauncherProvider);
    for (final resume in _waiting()) {
      final session = ref.read(sessionsDataProvider).getById(resume.sessionId);
      if (session == null) continue;
      if (session.isArchived) {
        _letGo(session.id, 'The session was archived, so it was left alone.');
      } else if (!resume.liveWhenScheduled &&
          launcher.livePaneFor(session.id) != null) {
        _letGo(
          session.id,
          'You resumed this session yourself before its time, so the '
          'scheduled resume was cancelled and nothing was sent.',
        );
      }
    }
  }

  void _letGo(String sessionId, String reason) {
    final resume = ref.read(resumesDataProvider).liveFor(sessionId);
    if (resume == null || resume.state == ScheduledResumeState.firing) return;
    final ended = _controller.end(
      resume,
      ScheduledResumeState.cancelled,
      reason,
    );
    ref
        .read(resumeAnnouncerProvider)
        .announce(ended, ref.read(sessionsDataProvider).getById(sessionId));
  }

  /// A reading that came off the wire anyway. Costs no request of its own.
  void _onReading(String key, AgentUsage reading) {
    if (_disposed) return;
    final now = ref.read(clockProvider).nowUtc();
    for (final resume in _waiting()) {
      if (resume.state != ScheduledResumeState.pending) continue;
      if (resume.windowLabel == null || resume.accountKey != key) continue;
      if (!resume.fireAt.isAfter(now)) continue;

      final switched =
          resume.accountEmail != null &&
          reading.email != null &&
          reading.email != resume.accountEmail;
      if (switched || windowRolledOverEarly(resume, reading, now: now)) {
        // Due now; the fire path reads this same reading and decides.
        _controller.reschedule(
          resume,
          fireAt: now,
          resetsAt: resume.resetsAt,
          reason: switched
              ? 'The signed-in account changed, so this is being looked at '
                    'again now.'
              : 'The ${resume.windowLabel} window reset early, so this is '
                    'going ahead now.',
        );
        continue;
      }

      final moved = _movedReset(resume, reading);
      if (moved != null) {
        _controller.reschedule(
          resume,
          fireAt: moved.add(kResumeResetMargin),
          resetsAt: moved,
          reason:
              'The provider moved the reset to '
              '${formatResetClock(moved, now.toLocal())}.',
        );
      }
    }
  }

  /// The window's reset when it is still spent and no longer where this row
  /// expected it, or null.
  DateTime? _movedReset(ScheduledResume resume, AgentUsage reading) {
    final expected = resume.resetsAt;
    if (expected == null) return null;
    for (final window in reading.windows) {
      if (window.label != resume.windowLabel) continue;
      final resets = window.resetsAt;
      if (resets == null || !isSpent(window)) return null;
      return resets.difference(expected).abs() > kResumeSameReset
          ? resets
          : null;
    }
    return null;
  }
}

final scheduledResumeObserverProvider =
    NotifierProvider<ScheduledResumeObserver, int>(ScheduledResumeObserver.new);
