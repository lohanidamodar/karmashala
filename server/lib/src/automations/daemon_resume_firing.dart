import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/scheduler.dart';

import '../protocol/messages.dart';
import 'automation_app_relay.dart';

/// A scheduled resume coming due in the host. Resuming a conversation needs
/// the app (its launcher, its reading of the session, the usage check), so
/// the host forwards it; with no app it waits, `queued` with the reason, and
/// goes when the app opens if that is still in time.
class DaemonResumeFiring implements ScheduledResumeFiring {
  DaemonResumeFiring({
    required this.relay,
    required this.resumes,
    required this.now,
    required this.onChanged,
  });

  final AutomationAppRelay relay;
  final ResumeRecords resumes;
  final DateTime Function() now;
  final void Function(String sessionId) onChanged;

  /// Set once the scheduler exists: a late resume is ended through it, so the
  /// app hears how it ended.
  late AutomationScheduler scheduler;

  @override
  Future<void> fire(ScheduledResume resume, {String note = ''}) async {
    if (!relay.connected) {
      _wait(resume);
      return;
    }
    if (_waited(resume)) {
      final late = lateForDeferredResume(resume, now());
      if (late != null) {
        scheduler.endResume(resume, ScheduledResumeState.missed, late);
        return;
      }
    }
    try {
      await relay.call(AutomationCallKind.fireResume, resume.id, note: note);
    } on AutomationRelayFailure {
      // Only if nothing took it: a row the app claimed is the app's to end.
      final current = resumes.getById(resume.id);
      if (current != null &&
          (current.state == ScheduledResumeState.pending ||
              current.state == ScheduledResumeState.queued)) {
        _wait(current);
      }
    }
  }

  static bool _waited(ScheduledResume resume) =>
      resume.state == ScheduledResumeState.queued &&
      resume.reason == kResumeWaitingForApp;

  void _wait(ScheduledResume resume) {
    if (_waited(resume)) return;
    resumes.update(
      resume.copyWith(
        state: ScheduledResumeState.queued,
        reason: kResumeWaitingForApp,
      ),
    );
    onChanged(resume.sessionId);
  }
}
