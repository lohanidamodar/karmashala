import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runs.dart';

/// The automations domain as a client copies it: every automation, the runs
/// worth holding (every live one and the newest of each automation), their
/// checks, the origin chains messages left, every project check, which
/// checkouts have verification on, and the resumes worth holding (every live
/// one, each session's last ended one, the newest ended).
final class AutomationsSnapshot {
  const AutomationsSnapshot({
    this.automations = const [],
    this.runs = const [],
    this.checks = const {},
    this.origins = const {},
    this.projectChecks = const [],
    this.verified = const {},
    this.resumes = const [],
  });

  final List<Automation> automations;
  final List<AutomationRun> runs;
  final Map<String, List<AutomationCheckVerdict>> checks;
  final Map<String, List<String>> origins;
  final List<ProjectCheck> projectChecks;
  final Set<String> verified;
  final List<ScheduledResume> resumes;

  Map<String, Object?> toJson() => {
    'automations': [for (final a in automations) automationToJson(a)],
    'runs': [for (final r in runs) automationRunToJson(r)],
    'checks': {
      for (final e in checks.entries)
        e.key: [for (final v in e.value) checkVerdictToJson(v)],
    },
    'origins': origins,
    'projectChecks': [for (final c in projectChecks) projectCheckToJson(c)],
    'verified': [...verified],
    'resumes': [for (final r in resumes) scheduledResumeToJson(r)],
  };

  static AutomationsSnapshot fromJson(Map<String, Object?> json) {
    List<Map<String, Object?>> objects(Object? value) => [
      for (final item in value as List? ?? const [])
        (item as Map).cast<String, Object?>(),
    ];
    return AutomationsSnapshot(
      automations: objects(
        json['automations'],
      ).map(automationFromJson).toList(),
      runs: objects(json['runs']).map(automationRunFromJson).toList(),
      checks: {
        for (final e in (json['checks'] as Map? ?? const {}).entries)
          e.key as String: objects(e.value).map(checkVerdictFromJson).toList(),
      },
      origins: {
        for (final e in (json['origins'] as Map? ?? const {}).entries)
          e.key as String: (e.value as List).cast<String>(),
      },
      projectChecks: objects(
        json['projectChecks'],
      ).map(projectCheckFromJson).toList(),
      verified: {...(json['verified'] as List? ?? const []).cast<String>()},
      resumes: objects(json['resumes']).map(scheduledResumeFromJson).toList(),
    );
  }
}
