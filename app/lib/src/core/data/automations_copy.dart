import 'dart:async';
import 'dart:convert';

import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/webhooks.dart' show WebhookCall;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'keyed_replica.dart';

/// This app's copy of the automations domain: every automation, the runs the
/// server says are worth holding and their checks, the origin chains, the
/// project checks, which checkouts verify, and the resumes worth holding.
class AutomationsCopy {
  static bool Function(T a, T b) _sameJson<T>(
    Map<String, Object?> Function(T value) toJson,
  ) =>
      (a, b) => jsonEncode(toJson(a)) == jsonEncode(toJson(b));

  final rules = KeyedReplica<Automation>(_sameJson(automationToJson));
  final runs = KeyedReplica<AutomationRun>(_sameJson(automationRunToJson));

  /// Each run's verdicts, in the order they were added.
  final checks = KeyedReplica<List<AutomationCheckVerdict>>(
    (a, b) =>
        jsonEncode([for (final v in a) checkVerdictToJson(v)]) ==
        jsonEncode([for (final v in b) checkVerdictToJson(v)]),
  );
  final origins = KeyedReplica<List<String>>((a, b) => a.join() == b.join());
  final projectChecks = KeyedReplica<ProjectCheck>();

  /// The checkouts whose verification is on (present means on).
  final verified = KeyedReplica<bool>();
  final resumes = KeyedReplica<ScheduledResume>(
    _sameJson(scheduledResumeToJson),
  );

  List<KeyedReplica<Object>> get _all => [
    rules,
    runs,
    checks,
    origins,
    projectChecks,
    verified,
    resumes,
  ];

  bool get isPrimed => rules.isPrimed;

  /// Fires after any row of the domain changed.
  Stream<void> get changes => _merge([for (final r in _all) r.changes]);

  /// Each webhook call the server logged, as it is told. Not a row: the log
  /// is read whole with `webhooks.status` when a person opens it.
  Stream<WebhookCall> get webhookCalls => _webhookCalls.stream;
  final _webhookCalls = StreamController<WebhookCall>.broadcast();

  void replace(AutomationsSnapshot snapshot, int revision) {
    checks.replaceAll(snapshot.checks, revision);
    origins.replaceAll(snapshot.origins, revision);
    projectChecks.replaceAll({
      for (final c in snapshot.projectChecks) c.id: c,
    }, revision);
    verified.replaceAll({
      for (final id in snapshot.verified) id: true,
    }, revision);
    resumes.replaceAll({for (final r in snapshot.resumes) r.id: r}, revision);
    runs.replaceAll({for (final r in snapshot.runs) r.id: r}, revision);
    rules.replaceAll({for (final a in snapshot.automations) a.id: a}, revision);
  }

  void apply(AutomationsChange change, int revision) {
    switch (change) {
      case AutomationChanged(:final automation):
        rules.applyAt(automation.id, automation, revision);
      case AutomationRemoved(:final id):
        for (final run in [...runs.values]) {
          if (run.automationId == id) _removeRun(run.id, revision);
        }
        rules.applyAt(id, null, revision);
      case AutomationRunChanged(:final run):
        runs.applyAt(run.id, run, revision);
      case AutomationRunCheckAdded(:final verdict):
        checks.applyAt(verdict.runId, [
          for (final v in checks[verdict.runId] ?? const [])
            if (v.ordinal != verdict.ordinal) v,
          verdict,
        ], revision);
      case AutomationOriginChanged(:final sessionId, :final origin):
        origins.applyAt(sessionId, origin.isEmpty ? null : origin, revision);
      case ProjectCheckChanged(:final check):
        projectChecks.applyAt(check.id, check, revision);
      case ProjectCheckRemoved(:final id):
        projectChecks.applyAt(id, null, revision);
      case ProjectVerificationChanged(:final repositoryId, :final enabled):
        verified.applyAt(repositoryId, enabled ? true : null, revision);
      case ResumeChanged(:final resume):
        resumes.applyAt(resume.id, resume, revision);
      case ResumeRemoved(:final id):
        resumes.applyAt(id, null, revision);
      case WebhookCallRecorded(:final call):
        _webhookCalls.add(call);
    }
  }

  void _removeRun(String id, int revision) {
    runs.applyAt(id, null, revision);
    checks.applyAt(id, null, revision);
  }

  /// Checkout [repositoryId] went, and with it (the schema's cascade) its
  /// automations, their runs, its checks and its verification switch.
  void checkoutRemoved(String repositoryId, int revision) {
    for (final rule in [...rules.values]) {
      if (rule.repositoryId == repositoryId) {
        apply(AutomationRemoved(rule.id), revision);
      }
    }
    for (final check in [...projectChecks.values]) {
      if (check.repositoryId == repositoryId) {
        projectChecks.applyAt(check.id, null, revision);
      }
    }
    verified.applyAt(repositoryId, null, revision);
  }

  /// Session [sessionId] went, and with it its resumes and origin chain.
  void sessionRemoved(String sessionId, int revision) {
    for (final resume in [...resumes.values]) {
      if (resume.sessionId == sessionId) {
        resumes.applyAt(resume.id, null, revision);
      }
    }
    origins.applyAt(sessionId, null, revision);
  }

  void dispose() {
    unawaited(_webhookCalls.close());
    for (final replica in _all) {
      unawaited(replica.dispose());
    }
  }
}

/// The broadcast [streams] as one.
Stream<void> _merge(List<Stream<void>> streams) {
  late final StreamController<void> out;
  final subscriptions = <StreamSubscription<void>>[];
  out = StreamController<void>.broadcast(
    sync: true,
    onListen: () {
      for (final s in streams) {
        subscriptions.add(s.listen(out.add));
      }
    },
    onCancel: () {
      for (final s in subscriptions) {
        unawaited(s.cancel());
      }
      subscriptions.clear();
    },
  );
  return out.stream;
}
