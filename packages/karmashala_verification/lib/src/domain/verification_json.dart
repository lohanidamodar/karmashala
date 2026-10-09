import 'code_identity.dart';
import 'verification_artifact.dart';
import 'verification_run.dart';
import 'verification_step.dart';
import 'verification_target.dart';

// The wire shape of a verification run, its steps and its evidence rows. The
// evidence itself stays files on disk; only where they are travels. Each
// reader throws [FormatException] on a value out of shape.

String _time(DateTime at) => at.toUtc().toIso8601String();

DateTime _date(Object? value) => DateTime.parse(value! as String).toUtc();

Map<String, Object?> verificationRunToJson(VerificationRun run) => {
  'id': run.id,
  'title': run.title,
  'target': {
    'kind': run.target.kind.name,
    'url': ?run.target.url,
    'serial': ?run.target.serial,
    'package': ?run.target.packageName,
  },
  'sessionId': ?run.sessionId,
  'producedBySessionId': ?run.producedBySessionId,
  'startedAt': _time(run.startedAt),
  'finishedAt': ?run.finishedAt == null ? null : _time(run.finishedAt!),
  'verdict': ?run.verdict?.name,
  'reason': ?run.reason,
  'artifactDirectory': run.artifactDirectory,
  'identity': ?run.identity?.toJson(),
  if (run.steps.isNotEmpty)
    'steps': [for (final step in run.steps) verificationStepToJson(step)],
  if (run.artifacts.isNotEmpty)
    'artifacts': [for (final a in run.artifacts) verificationArtifactToJson(a)],
};

VerificationRun verificationRunFromJson(Map<String, Object?> json) {
  try {
    final target = json['target']! as Map;
    final kind = VerificationTargetKind.parse(target['kind'] as String?);
    return VerificationRun(
      id: json['id']! as String,
      title: json['title']! as String,
      target: switch (kind) {
        VerificationTargetKind.browser => VerificationTarget.browser(
          target['url'] as String? ?? '',
        ),
        VerificationTargetKind.device => VerificationTarget.device(
          serial: target['serial'] as String? ?? '',
          packageName: target['package'] as String?,
        ),
        VerificationTargetKind.change => const VerificationTarget.change(),
      },
      sessionId: json['sessionId'] as String?,
      producedBySessionId: json['producedBySessionId'] as String?,
      startedAt: _date(json['startedAt']),
      finishedAt: json['finishedAt'] == null ? null : _date(json['finishedAt']),
      verdict: VerificationVerdict.parse(json['verdict'] as String?),
      reason: json['reason'] as String?,
      artifactDirectory: json['artifactDirectory']! as String,
      identity: CodeIdentity.fromJson(json['identity']),
      steps: [
        for (final step in (json['steps'] as List? ?? const []))
          verificationStepFromJson((step as Map).cast<String, Object?>()),
      ],
      artifacts: [
        for (final a in (json['artifacts'] as List? ?? const []))
          verificationArtifactFromJson((a as Map).cast<String, Object?>()),
      ],
    );
  } on TypeError {
    throw const FormatException('not a verification run');
  }
}

Map<String, Object?> verificationStepToJson(VerificationStep step) => {
  'ordinal': step.ordinal,
  'kind': step.kind.name,
  'summary': step.summary,
  'detail': ?step.detail,
  'ok': step.ok,
  'at': _time(step.at),
};

VerificationStep verificationStepFromJson(Map<String, Object?> json) {
  try {
    return VerificationStep(
      ordinal: json['ordinal']! as int,
      kind: VerificationStepKind.parse(json['kind'] as String?),
      summary: json['summary']! as String,
      detail: json['detail'] as String?,
      ok: json['ok'] as bool? ?? true,
      at: _date(json['at']),
    );
  } on TypeError {
    throw const FormatException('not a verification step');
  }
}

Map<String, Object?> verificationArtifactToJson(VerificationArtifact a) => {
  'id': a.id,
  'runId': a.runId,
  'stepOrdinal': ?a.stepOrdinal,
  'kind': a.kind.name,
  'label': a.label,
  'relativePath': a.relativePath,
  'byteSize': a.byteSize,
  'at': _time(a.at),
};

VerificationArtifact verificationArtifactFromJson(Map<String, Object?> json) {
  try {
    return VerificationArtifact(
      id: json['id']! as String,
      runId: json['runId']! as String,
      stepOrdinal: json['stepOrdinal'] as int?,
      kind: VerificationArtifactKind.parse(json['kind'] as String?),
      label: json['label']! as String,
      relativePath: json['relativePath']! as String,
      byteSize: json['byteSize']! as int,
      at: _date(json['at']),
    );
  } on TypeError {
    throw const FormatException('not a verification artifact');
  }
}

/// [run] without its steps and artifacts: what a client keeps of every run.
VerificationRun verificationHeaderOf(VerificationRun run) =>
    run.steps.isEmpty && run.artifacts.isEmpty
    ? run
    : VerificationRun(
        id: run.id,
        title: run.title,
        target: run.target,
        startedAt: run.startedAt,
        artifactDirectory: run.artifactDirectory,
        sessionId: run.sessionId,
        producedBySessionId: run.producedBySessionId,
        finishedAt: run.finishedAt,
        verdict: run.verdict,
        reason: run.reason,
        identity: run.identity,
      );

/// Whether two run headers say the same thing.
bool sameVerificationHeader(VerificationRun a, VerificationRun b) =>
    a.id == b.id &&
    a.title == b.title &&
    a.target.kind == b.target.kind &&
    a.target.url == b.target.url &&
    a.target.serial == b.target.serial &&
    a.target.packageName == b.target.packageName &&
    a.sessionId == b.sessionId &&
    a.producedBySessionId == b.producedBySessionId &&
    a.startedAt == b.startedAt &&
    a.finishedAt == b.finishedAt &&
    a.verdict == b.verdict &&
    a.reason == b.reason &&
    a.artifactDirectory == b.artifactDirectory &&
    _sameIdentity(a.identity, b.identity);

bool _sameIdentity(CodeIdentity? a, CodeIdentity? b) => a == null || b == null
    ? a == b
    : a.sameCode(b) && a.changedDuringRun == b.changedDuringRun;

/// The store's order for runs: newest first, then by id descending.
int compareVerificationRuns(VerificationRun a, VerificationRun b) {
  final at = b.startedAt.compareTo(a.startedAt);
  return at != 0 ? at : b.id.compareTo(a.id);
}
