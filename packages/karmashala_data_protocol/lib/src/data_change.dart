import 'package:karmashala_files/values.dart' show FileStamp;
import 'package:karmashala_git/cleanup.dart' show WorktreeCleanupLog;
import 'package:karmashala_git/git.dart'
    show
        ReviewThread,
        WorktreeCreationRecord,
        WorktreeSetup,
        WorktreeSetupReport;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_remote/remote.dart'
    show PairedDevice, pairedDeviceFromJson, pairedDeviceToJson;
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart'
    show FlutterAppRegistry;

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_checkpoints/checkpoints.dart'
    show Checkpoint, checkpointFromJson, checkpointToJson;
import 'package:karmashala_comparisons/comparisons.dart'
    show Comparison, comparisonFromJson, comparisonToJson;
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_verification/verification.dart'
    show
        VerificationRun,
        verificationHeaderOf,
        verificationRunFromJson,
        verificationRunToJson;

import 'agent_work_values.dart';
import 'git_values.dart';
import 'session_values.dart';
import 'ssh_values.dart';
import 'worktree_values.dart';
import 'flutter_values.dart';
import 'browser_values.dart';
import 'device_values.dart';
import 'terminal_values.dart';
import 'env_values.dart';
import 'store_values.dart';
import 'attention_values.dart';
import 'usage_limit_values.dart';
import 'files_values.dart' show QuickAccessPin;
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;

part 'changes/automations_changes.dart';
part 'changes/checkpoints_changes.dart';
part 'changes/worktrees_changes.dart';
part 'changes/snippets_changes.dart';
part 'changes/pairings_changes.dart';
part 'changes/ssh_changes.dart';
part 'changes/git_changes.dart';
part 'changes/flutter_changes.dart';
part 'changes/browser_changes.dart';
part 'changes/files_changes.dart';
part 'changes/devices_changes.dart';
part 'changes/terminals_changes.dart';
part 'changes/env_changes.dart';
part 'changes/stores_changes.dart';
part 'changes/attention_changes.dart';
part 'changes/intents_changes.dart';
part 'changes/transcripts_changes.dart';
part 'changes/quick_access_changes.dart';

/// One row a server wrote or removed, as it now stands.
sealed class DataChange {
  const DataChange();

  Map<String, Object?> toJson();

  /// Null for a change this client does not know — a newer server's domain,
  /// which it can safely ignore.
  static DataChange? fromJson(
    Map<String, Object?> json,
  ) => switch (json['change']) {
    'noteChanged' => NoteChanged(
      Note.fromJson((json['note']! as Map).cast<String, Object?>()),
    ),
    'noteRemoved' => NoteRemoved(json['id']! as String),
    'todoChanged' => TodoChanged(
      Todo.fromJson((json['todo']! as Map).cast<String, Object?>()),
    ),
    'todoRemoved' => TodoRemoved(json['id']! as String),
    'preferenceChanged' => PreferenceChanged(
      json['key']! as String,
      json['value'] as String?,
    ),
    'workspaceChanged' => WorkspaceChanged(Workspace.fromJson(_row(json))),
    'workspaceRemoved' => WorkspaceRemoved(json['id']! as String),
    'projectChanged' => ProjectChanged(Project.fromJson(_row(json))),
    'projectRemoved' => ProjectRemoved(json['id']! as String),
    'repositoryChanged' => RepositoryChanged(repositoryFromJson(json['row'])),
    'repositoryRemoved' => RepositoryRemoved(json['id']! as String),
    'sectionChanged' => SectionChanged(StoredSection.fromJson(_row(json))),
    'sectionRemoved' => SectionRemoved(json['id']! as String),
    'sessionRowChanged' => SessionRowChanged(Session.fromJson(_row(json))),
    'sessionRowRemoved' => SessionRowRemoved(json['id']! as String),
    'sessionLinksChanged' => SessionLinksChanged(json['id']! as String, [
      for (final link in json['links']! as List)
        SessionRepositoryLink.fromJson((link as Map).cast<String, Object?>()),
    ]),
    'importedChanged' => ImportedChanged(importedFromJson(_row(json))),
    'importedRemoved' => ImportedRemoved(json['id']! as String),
    'decisionRecorded' => DecisionRecorded(DecisionRecord.fromJson(_row(json))),
    'decisionRemoved' => DecisionRemoved(json['id']! as int),
    'recapChanged' => RecapChanged(SessionRecap.fromJson(_row(json))),
    'recapRemoved' => RecapRemoved(json['id']! as String),
    'followUpChanged' => FollowUpChanged(FollowUp.fromJson(_row(json))),
    'environmentChanged' => EnvironmentChanged(environmentFromJson(_row(json))),
    'environmentRemoved' => EnvironmentRemoved(json['id']! as String),
    'sshHostTouched' => SshHostTouched(json['id']! as String),
    'sshHostRemoved' => SshHostRemoved(json['id']! as String),
    'knownHostChanged' => KnownHostChanged(knownHostFromJson(_row(json))),
    'knownHostRemoved' => KnownHostRemoved(
      json['host']! as String,
      json['port']! as int,
    ),
    'installationChanged' => InstallationChanged(
      installationFromJson(_row(json)),
    ),
    'installationRemoved' => InstallationRemoved(json['id']! as String),
    'claudeAccountChanged' => ClaudeAccountChanged(
      claudeAccountFromJson(_row(json)),
    ),
    'claudeAccountRemoved' => ClaudeAccountRemoved(json['id']! as String),
    'codexAccountChanged' => CodexAccountChanged(
      codexAccountFromJson(_row(json)),
    ),
    'codexAccountRemoved' => CodexAccountRemoved(json['id']! as String),
    'usageRecorded' => UsageRecorded(json['accountKey']! as String),
    'usageStateChanged' => UsageStateChanged(
      AccountUsageState.fromJson(_row(json)),
    ),
    final String name => _domainChangeFromJson(name, json),
    _ => null,
  };
}

/// A sessions-domain row as it now stands, or its key when it went. Each
/// travels as `{change, row}` / `{change, id}`.
sealed class SessionDomainChange extends DataChange {
  const SessionDomainChange();
}

/// A session row as the server now holds it — created, edited, or given a
/// new status by the server that runs it.
final class SessionRowChanged extends SessionDomainChange {
  const SessionRowChanged(this.session);

  final Session session;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionRowChanged',
    'row': session.toJson(),
  };
}

final class SessionRowRemoved extends SessionDomainChange {
  const SessionRowRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'sessionRowRemoved', 'id': id};
}

/// Every checkout session [sessionId] now spans, the primary first; empty
/// once it spans none.
final class SessionLinksChanged extends SessionDomainChange {
  const SessionLinksChanged(this.sessionId, this.links);

  final String sessionId;
  final List<SessionRepositoryLink> links;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionLinksChanged',
    'id': sessionId,
    'links': [for (final link in links) link.toJson()],
  };
}

final class ImportedChanged extends SessionDomainChange {
  const ImportedChanged(this.session);

  final ImportedSession session;

  @override
  Map<String, Object?> toJson() => {
    'change': 'importedChanged',
    'row': importedToJson(session),
  };
}

final class ImportedRemoved extends SessionDomainChange {
  const ImportedRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'importedRemoved', 'id': id};
}

final class DecisionRecorded extends SessionDomainChange {
  const DecisionRecorded(this.decision);

  final DecisionRecord decision;

  @override
  Map<String, Object?> toJson() => {
    'change': 'decisionRecorded',
    'row': decision.toJson(),
  };
}

/// A decision that went with its session.
final class DecisionRemoved extends SessionDomainChange {
  const DecisionRemoved(this.id);

  final int id;

  @override
  Map<String, Object?> toJson() => {'change': 'decisionRemoved', 'id': id};
}

final class RecapChanged extends SessionDomainChange {
  const RecapChanged(this.recap);

  final SessionRecap recap;

  @override
  Map<String, Object?> toJson() => {
    'change': 'recapChanged',
    'row': recap.toJson(),
  };
}

/// Session [sessionId]'s recap went: dismissed, or with its session.
final class RecapRemoved extends SessionDomainChange {
  const RecapRemoved(this.sessionId);

  final String sessionId;

  @override
  Map<String, Object?> toJson() => {'change': 'recapRemoved', 'id': sessionId};
}

/// A follow-up raised or resolved. Never removed: a disappearance has an
/// answer.
final class FollowUpChanged extends SessionDomainChange {
  const FollowUpChanged(this.followUp);

  final FollowUp followUp;

  @override
  Map<String, Object?> toJson() => {
    'change': 'followUpChanged',
    'row': followUp.toJson(),
  };
}

/// A change to where agents run — an environment, a saved SSH host, a
/// trusted host key — or to the agents: an installation, a saved account,
/// the usage history. **No change carries a credential or a key's
/// location**: a saved account is told without its token bundle, and a
/// saved SSH host only by id (a client asks for its hosts again).
sealed class HostsDomainChange extends DataChange {
  const HostsDomainChange();
}

final class EnvironmentChanged extends HostsDomainChange {
  const EnvironmentChanged(this.environment);

  final ExecutionEnvironment environment;

  @override
  Map<String, Object?> toJson() => {
    'change': 'environmentChanged',
    'row': environmentToJson(environment),
  };
}

final class EnvironmentRemoved extends HostsDomainChange {
  const EnvironmentRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'environmentRemoved', 'id': id};
}

/// Saved SSH host [id] was written. Told by id alone: the row names where
/// its private key is, which only a client that asks for its hosts is told.
final class SshHostTouched extends HostsDomainChange {
  const SshHostTouched(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'sshHostTouched', 'id': id};
}

final class SshHostRemoved extends HostsDomainChange {
  const SshHostRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'sshHostRemoved', 'id': id};
}

/// A host key now trusted — a fingerprint, safe to show.
final class KnownHostChanged extends HostsDomainChange {
  const KnownHostChanged(this.key);

  final KnownHostKey key;

  @override
  Map<String, Object?> toJson() => {
    'change': 'knownHostChanged',
    'row': knownHostToJson(key),
  };
}

final class KnownHostRemoved extends HostsDomainChange {
  const KnownHostRemoved(this.host, this.port);

  final String host;
  final int port;

  @override
  Map<String, Object?> toJson() => {
    'change': 'knownHostRemoved',
    'host': host,
    'port': port,
  };
}

final class InstallationChanged extends HostsDomainChange {
  const InstallationChanged(this.installation);

  final AgentInstallation installation;

  @override
  Map<String, Object?> toJson() => {
    'change': 'installationChanged',
    'row': installationToJson(installation),
  };
}

final class InstallationRemoved extends HostsDomainChange {
  const InstallationRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'installationRemoved', 'id': id};
}

/// A saved Claude account as it now stands, **without its credentials**.
final class ClaudeAccountChanged extends HostsDomainChange {
  const ClaudeAccountChanged(this.account);

  final ClaudeAccount account;

  @override
  Map<String, Object?> toJson() => {
    'change': 'claudeAccountChanged',
    'row': claudeAccountToJson(account),
  };
}

final class ClaudeAccountRemoved extends HostsDomainChange {
  const ClaudeAccountRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'claudeAccountRemoved', 'id': id};
}

/// A saved Codex account as it now stands, **without its credentials**.
final class CodexAccountChanged extends HostsDomainChange {
  const CodexAccountChanged(this.account);

  final CodexAccount account;

  @override
  Map<String, Object?> toJson() => {
    'change': 'codexAccountChanged',
    'row': codexAccountToJson(account),
  };
}

final class CodexAccountRemoved extends HostsDomainChange {
  const CodexAccountRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'codexAccountRemoved', 'id': id};
}

/// The usage history of [accountKey] gained rows: a chart over it reads
/// again.
final class UsageRecorded extends HostsDomainChange {
  const UsageRecorded(this.accountKey);

  final String accountKey;

  @override
  Map<String, Object?> toJson() => {
    'change': 'usageRecorded',
    'accountKey': accountKey,
  };
}

/// An account's usage as the server now holds it: a new reading, a failed
/// attempt, or a new time it asks next.
final class UsageStateChanged extends HostsDomainChange {
  const UsageStateChanged(this.state);

  final AccountUsageState state;

  @override
  Map<String, Object?> toJson() => {
    'change': 'usageStateChanged',
    'row': state.toJson(),
  };
}

final class NoteChanged extends DataChange {
  const NoteChanged(this.note);

  final Note note;

  @override
  Map<String, Object?> toJson() => {
    'change': 'noteChanged',
    'note': note.toJson(),
  };
}

final class NoteRemoved extends DataChange {
  const NoteRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'noteRemoved', 'id': id};
}

final class TodoChanged extends DataChange {
  const TodoChanged(this.todo);

  final Todo todo;

  @override
  Map<String, Object?> toJson() => {
    'change': 'todoChanged',
    'todo': todo.toJson(),
  };
}

final class TodoRemoved extends DataChange {
  const TodoRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'todoRemoved', 'id': id};
}

/// A preference now holding [value], or — null — forgotten.
final class PreferenceChanged extends DataChange {
  const PreferenceChanged(this.key, this.value);

  final String key;
  final String? value;

  @override
  Map<String, Object?> toJson() => {
    'change': 'preferenceChanged',
    'key': key,
    'value': value,
  };
}

/// A workspace-domain row as it now stands, or its id when it went. Each
/// travels as `{change, row}` / `{change, id}`.
sealed class RowChange extends DataChange {
  const RowChange();

  String get name;
}

final class WorkspaceChanged extends RowChange {
  const WorkspaceChanged(this.workspace);

  final Workspace workspace;

  @override
  String get name => 'workspaceChanged';

  @override
  Map<String, Object?> toJson() => {'change': name, 'row': workspace.toJson()};
}

final class ProjectChanged extends RowChange {
  const ProjectChanged(this.project);

  final Project project;

  @override
  String get name => 'projectChanged';

  @override
  Map<String, Object?> toJson() => {'change': name, 'row': project.toJson()};
}

final class RepositoryChanged extends RowChange {
  const RepositoryChanged(this.repository);

  final Repository repository;

  @override
  String get name => 'repositoryChanged';

  @override
  Map<String, Object?> toJson() => {
    'change': name,
    'row': repositoryToJson(repository),
  };
}

final class SectionChanged extends RowChange {
  const SectionChanged(this.section);

  final StoredSection section;

  @override
  String get name => 'sectionChanged';

  @override
  Map<String, Object?> toJson() => {'change': name, 'row': section.toJson()};
}

/// A workspace-domain row that went, by id.
sealed class RowRemoved extends RowChange {
  const RowRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': name, 'id': id};
}

final class WorkspaceRemoved extends RowRemoved {
  const WorkspaceRemoved(super.id);

  @override
  String get name => 'workspaceRemoved';
}

final class ProjectRemoved extends RowRemoved {
  const ProjectRemoved(super.id);

  @override
  String get name => 'projectRemoved';
}

final class RepositoryRemoved extends RowRemoved {
  const RepositoryRemoved(super.id);

  @override
  String get name => 'repositoryRemoved';
}

final class SectionRemoved extends RowRemoved {
  const SectionRemoved(super.id);

  @override
  String get name => 'sectionRemoved';
}

/// A change of the domains slice 1e moved, each family read by its own part
/// file; null when none knows [name] (a newer server's domain).
DataChange? _domainChangeFromJson(String name, Map<String, Object?> json) =>
    _automationsChangeFromJson(name, json) ??
    _checkpointsChangeFromJson(name, json) ??
    _worktreesChangeFromJson(name, json) ??
    _snippetsChangeFromJson(name, json) ??
    _pairingsChangeFromJson(name, json) ??
    _sshChangeFromJson(name, json) ??
    _gitChangeFromJson(name, json) ??
    _flutterChangeFromJson(name, json) ??
    _browserChangeFromJson(name, json) ??
    _filesChangeFromJson(name, json) ??
    _devicesChangeFromJson(name, json) ??
    _terminalsChangeFromJson(name, json) ??
    _envChangeFromJson(name, json) ??
    _storesChangeFromJson(name, json) ??
    _attentionChangeFromJson(name, json) ??
    _intentsChangeFromJson(name, json) ??
    _transcriptsChangeFromJson(name, json) ??
    _quickAccessChangeFromJson(name, json);

Map<String, Object?> _row(Map<String, Object?> json) =>
    (json['row']! as Map).cast<String, Object?>();

/// Everything one write changed, under the server's [revision] for it.
/// Revisions only grow for the life of one server process, so a copy can
/// tell a late answer from a newer change.
final class DataChanges {
  const DataChanges(this.revision, this.changes);

  final int revision;
  final List<DataChange> changes;

  Map<String, Object?> toJson() => {
    'revision': revision,
    'changes': [for (final change in changes) change.toJson()],
  };

  /// Throws [FormatException] on a batch out of shape.
  static DataChanges fromJson(Map<String, Object?> json) {
    final revision = json['revision'];
    final changes = json['changes'];
    if (revision is! int || changes is! List) {
      throw const FormatException('not a data change batch');
    }
    return DataChanges(revision, [
      for (final change in changes)
        ?DataChange.fromJson((change as Map).cast<String, Object?>()),
    ]);
  }
}
