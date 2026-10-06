part of '../data_change.dart';

// Automations, their runs and checks, scheduled resumes, project checks.

DataChange? _automationsChangeFromJson(
  String name,
  Map<String, Object?> json,
) => switch (name) {
  'automationChanged' => AutomationChanged(automationFromJson(_row(json))),
  'automationRemoved' => AutomationRemoved(json['id']! as String),
  'automationRunChanged' => AutomationRunChanged(
    automationRunFromJson(_row(json)),
  ),
  'automationRunCheckAdded' => AutomationRunCheckAdded(
    checkVerdictFromJson(_row(json)),
  ),
  'automationOriginChanged' => AutomationOriginChanged(
    json['id']! as String,
    (json['origin']! as List).cast<String>(),
  ),
  'projectCheckChanged' => ProjectCheckChanged(
    projectCheckFromJson(_row(json)),
  ),
  'projectCheckRemoved' => ProjectCheckRemoved(json['id']! as String),
  'projectVerificationChanged' => ProjectVerificationChanged(
    json['id']! as String,
    enabled: json['enabled']! as bool,
  ),
  'resumeChanged' => ResumeChanged(scheduledResumeFromJson(_row(json))),
  'resumeRemoved' => ResumeRemoved(json['id']! as String),
  'webhookCallRecorded' => WebhookCallRecorded(webhookCallFromJson(_row(json))),
  _ => null,
};

/// A change to the automations domain.
sealed class AutomationsChange extends DataChange {
  const AutomationsChange();
}

final class AutomationChanged extends AutomationsChange {
  const AutomationChanged(this.automation);

  final Automation automation;

  @override
  Map<String, Object?> toJson() => {
    'change': 'automationChanged',
    'row': automationToJson(automation),
  };
}

/// An automation deleted; its runs and their checks went with it.
final class AutomationRemoved extends AutomationsChange {
  const AutomationRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'automationRemoved', 'id': id};
}

/// A run recorded or moved on — fired, queued, missed, settled.
final class AutomationRunChanged extends AutomationsChange {
  const AutomationRunChanged(this.run);

  final AutomationRun run;

  @override
  Map<String, Object?> toJson() => {
    'change': 'automationRunChanged',
    'row': automationRunToJson(run),
  };
}

final class AutomationRunCheckAdded extends AutomationsChange {
  const AutomationRunCheckAdded(this.verdict);

  final AutomationCheckVerdict verdict;

  @override
  Map<String, Object?> toJson() => {
    'change': 'automationRunCheckAdded',
    'row': checkVerdictToJson(verdict),
  };
}

/// The chain a message left on session [sessionId]; empty once spent.
final class AutomationOriginChanged extends AutomationsChange {
  const AutomationOriginChanged(this.sessionId, this.origin);

  final String sessionId;
  final List<String> origin;

  @override
  Map<String, Object?> toJson() => {
    'change': 'automationOriginChanged',
    'id': sessionId,
    'origin': origin,
  };
}

final class ProjectCheckChanged extends AutomationsChange {
  const ProjectCheckChanged(this.check);

  final ProjectCheck check;

  @override
  Map<String, Object?> toJson() => {
    'change': 'projectCheckChanged',
    'row': projectCheckToJson(check),
  };
}

final class ProjectCheckRemoved extends AutomationsChange {
  const ProjectCheckRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'projectCheckRemoved', 'id': id};
}

final class ProjectVerificationChanged extends AutomationsChange {
  const ProjectVerificationChanged(this.repositoryId, {required this.enabled});

  final String repositoryId;
  final bool enabled;

  @override
  Map<String, Object?> toJson() => {
    'change': 'projectVerificationChanged',
    'id': repositoryId,
    'enabled': enabled,
  };
}

/// A scheduled resume armed, moved on or ended.
final class ResumeChanged extends AutomationsChange {
  const ResumeChanged(this.resume);

  final ScheduledResume resume;

  @override
  Map<String, Object?> toJson() => {
    'change': 'resumeChanged',
    'row': scheduledResumeToJson(resume),
  };
}

final class ResumeRemoved extends AutomationsChange {
  const ResumeRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'resumeRemoved', 'id': id};
}

/// A call to a webhook, accepted or refused, was logged. Never its body.
final class WebhookCallRecorded extends AutomationsChange {
  const WebhookCallRecorded(this.call);

  final WebhookCall call;

  @override
  Map<String, Object?> toJson() => {
    'change': 'webhookCallRecorded',
    'row': webhookCallToJson(call),
  };
}
