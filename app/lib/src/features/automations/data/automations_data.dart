import 'dart:async';

import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/webhooks.dart' show WebhookCall;
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/automations_copy.dart';
import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

final _log = AppLogger.named('automations.data');

/// Sends [write] without waiting: the copy already has it; a refusal is
/// logged, and the client reads the domain again.
void _send(Future<Object?> write, String what) => unawaited(
  write.then<void>(
    (_) {},
    onError: (Object error) => _log.warning('The server refused $what: $error'),
  ),
);

Future<R> _write<R>(DataClient client, DataRequest<R> request) =>
    client.write(request, domain: DataDomain.automations);

/// The automations, their runs, checks and origin chains as the server keeps
/// them: read at once from this app's copy, written through the server. A
/// `void` write lands in the copy now and is sent behind it.
class AutomationsData extends AutomationCopyReads {
  AutomationsData(this._client);

  final DataClient _client;
  AutomationsCopy get _copy => _client.automations;

  @override
  Iterable<Automation> get automationRows => _copy.rules.values;

  @override
  Iterable<AutomationRun> get runRows => _copy.runs.values;

  @override
  Automation? automationRow(String id) => _copy.rules[id];

  @override
  AutomationRun? runRow(String id) => _copy.runs[id];

  @override
  List<AutomationCheckVerdict>? checkRows(String runId) => _copy.checks[runId];

  @override
  List<String>? originRow(String sessionId) => _copy.origins[sessionId];

  // A person's writes, awaited by nobody: the page follows the copy.

  void save(Automation automation) {
    _copy.rules.setLocal(automation.id, automation);
    _send(_write(_client, AutomationSave(automation)), automation.name);
  }

  // Webhooks: their saves are awaited, since the server chooses the hook id
  // and a secret can only be made for a webhook it has stored.

  /// Saves [automation] and answers it as the server stored it; throws the
  /// server's refusal.
  Future<Automation> saveAndWait(Automation automation) =>
      _write(_client, AutomationSave(automation));

  /// A new signing secret for webhook [automationId] — the only time it is
  /// ever sent — replacing the old one at once.
  Future<WebhookIssued> rotateWebhook(String automationId) async =>
      (await _client.send(WebhookRotate(automationId))).value;

  /// Webhook [automationId]'s URL, whether it is listened for, and its log.
  Future<WebhookStatus> webhookStatus(String automationId) async =>
      (await _client.send(WebhookStatusRead(automationId))).value;

  /// Each call the server logs, as it is told.
  Stream<WebhookCall> get webhookCalls => _copy.webhookCalls;

  void delete(String id) {
    _copy.rules.setLocal(id, null);
    _send(_write(_client, AutomationDelete(id)), 'deleting automation $id');
  }

  @override
  void setEnabled(String id, {required bool enabled}) {
    final row = _copy.rules[id];
    if (row != null) _copy.rules.setLocal(id, row.copyWith(enabled: enabled));
    _send(
      _write(_client, AutomationSetEnabled(id, enabled: enabled)),
      'switching automation $id',
    );
  }

  @override
  void recordOutcome(String id, {required bool failed}) {
    final row = _copy.rules[id];
    if (row != null) {
      // The store's rule, so the settler's next read sees it.
      _copy.rules.setLocal(
        id,
        failed
            ? row.copyWith(consecutiveFailures: row.consecutiveFailures + 1)
            : row.copyWith(consecutiveFailures: 0, clearDisabledReason: true),
      );
    }
    _send(
      _write(_client, AutomationRecordOutcome(id, failed: failed)),
      'an outcome of automation $id',
    );
  }

  @override
  void disable(String id, String reason) {
    final row = _copy.rules[id];
    if (row != null) {
      _copy.rules.setLocal(
        id,
        row.copyWith(enabled: false, disabledReason: reason),
      );
    }
    _send(_write(_client, AutomationDisable(id, reason)), 'disabling $id');
  }

  // Runs this app fired or settled.

  @override
  void insertRun(AutomationRun run) => _putRun(run);

  @override
  void updateRun(AutomationRun run) => _putRun(run);

  void _putRun(AutomationRun run) {
    _copy.runs.setLocal(run.id, run);
    _send(_write(_client, AutomationRunPut(run)), 'run ${run.id}');
  }

  /// An event rule's run, queued at the server behind whatever holds its
  /// checkout; the server starts it when the checkout comes free.
  Future<AutomationRun> queueEventRun(AutomationRun run) =>
      _write(_client, AutomationEventRunQueue(run));

  @override
  void insertRunCheck(AutomationCheckVerdict verdict) {
    _copy.checks.setLocal(verdict.runId, [
      ...?_copy.checks[verdict.runId],
      verdict,
    ]);
    _send(
      _write(_client, AutomationRunCheckAdd(verdict)),
      'a check of run ${verdict.runId}',
    );
  }

  @override
  void noteChecksObserved(String runId, DateTime at) {
    final run = _copy.runs[runId];
    if (run != null) {
      _copy.runs.setLocal(runId, run.copyWith(checksObservedAt: at));
    }
    _send(
      _write(_client, AutomationRunChecksObserved(runId, at)),
      'the checks of run $runId',
    );
  }

  @override
  void markMessaged(String sessionId, List<String> origin, DateTime at) {
    _copy.origins.setLocal(sessionId, origin);
    _send(
      _write(_client, AutomationOriginMark(sessionId, origin)),
      'the origin of a message to $sessionId',
    );
  }

  @override
  List<String> messagedOrigin(String sessionId, {bool consume = false}) {
    final origin = _copy.origins[sessionId] ?? const [];
    if (consume && origin.isNotEmpty) clearMessaged(sessionId);
    return origin;
  }

  @override
  void clearMessaged(String sessionId) {
    _copy.origins.setLocal(sessionId, null);
    _send(
      _write(_client, AutomationOriginClear(sessionId)),
      'clearing the origin of $sessionId',
    );
  }
}

/// Scheduled resumes as the server keeps them, written through it.
class ResumesData extends ResumeCopyReads {
  ResumesData(this._client);

  final DataClient _client;
  AutomationsCopy get _copy => _client.automations;

  @override
  Iterable<ScheduledResume> get resumeRows => _copy.resumes.values;

  @override
  ScheduledResume? resumeRow(String id) => _copy.resumes[id];

  @override
  void replaceFor(ScheduledResume resume, {required DateTime now}) {
    final replaced = liveFor(resume.sessionId);
    if (replaced != null) {
      _copy.resumes.setLocal(
        replaced.id,
        replaced.copyWith(
          state: ScheduledResumeState.cancelled,
          reason: 'Replaced by a newer schedule.',
          finishedAt: now,
        ),
      );
    }
    _copy.resumes.setLocal(resume.id, resume);
    _send(_write(_client, ResumeSchedule(resume)), 'resume ${resume.id}');
  }

  @override
  void update(ScheduledResume resume) {
    _copy.resumes.setLocal(resume.id, resume);
    _send(_write(_client, ResumeUpdate(resume)), 'resume ${resume.id}');
  }

  /// Guarded in this copy — the one that fires resumes — and again at the
  /// server.
  @override
  bool transition(
    String id, {
    required ScheduledResumeState from,
    required ScheduledResumeState to,
  }) {
    final row = _copy.resumes[id];
    if (row == null || row.state != from) return false;
    _copy.resumes.setLocal(id, row.copyWith(state: to));
    _send(
      _write(_client, ResumeTransition(id, from: from, to: to)),
      'resume $id moving to ${to.name}',
    );
    return true;
  }

  @override
  void delete(String id) {
    _copy.resumes.setLocal(id, null);
    _send(_write(_client, ResumeDelete(id)), 'deleting resume $id');
  }
}

/// A checkout's project checks and its verification switch.
class ProjectChecksData extends ProjectCheckCopyReads {
  ProjectChecksData(this._client);

  final DataClient _client;
  AutomationsCopy get _copy => _client.automations;

  @override
  Iterable<ProjectCheck> get checkRowsAll => _copy.projectChecks.values;

  @override
  Set<String> get verifiedRows => _copy.verified.view.keys.toSet();

  void add(ProjectCheck check) {
    _copy.projectChecks.setLocal(check.id, check);
    _send(_write(_client, ProjectCheckAdd(check)), 'check ${check.name}');
  }

  void remove(String id) {
    _copy.projectChecks.setLocal(id, null);
    _send(_write(_client, ProjectCheckDelete(id)), 'deleting check $id');
  }

  void setVerification(String repositoryId, {required bool enabled}) {
    _copy.verified.setLocal(repositoryId, enabled ? true : null);
    _send(
      _write(_client, ProjectVerificationSet(repositoryId, enabled: enabled)),
      'verification of $repositoryId',
    );
  }
}

final automationsDataProvider = Provider<AutomationsData>(
  (ref) => AutomationsData(ref.watch(dataClientProvider)),
);

final resumesDataProvider = Provider<ResumesData>(
  (ref) => ResumesData(ref.watch(dataClientProvider)),
);

final projectChecksDataProvider = Provider<ProjectChecksData>(
  (ref) => ProjectChecksData(ref.watch(dataClientProvider)),
);

/// Moves whenever any row of the automations domain changed — here or at the
/// server — once per batch the server told.
class AutomationsRevision extends Notifier<int> {
  @override
  int build() {
    final client = ref.watch(dataClientProvider);
    var pending = false;
    void moved() {
      if (client.applyingBatch) {
        pending = true;
        return;
      }
      state = state + 1;
    }

    final changes = client.automations.changes.listen((_) => moved());
    final ends = client.batchEnds.listen((_) {
      if (!pending) return;
      pending = false;
      state = state + 1;
    });
    ref.onDispose(() {
      unawaited(changes.cancel());
      unawaited(ends.cancel());
    });
    return 0;
  }
}

final automationsRevisionProvider = NotifierProvider<AutomationsRevision, int>(
  AutomationsRevision.new,
);
