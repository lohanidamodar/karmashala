import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_cli/descriptors.dart'
    show AgentQuestionSet, AgentRewindPoints;
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show questionFromJson, questionToJson;
import 'package:agent_cli/usage.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_checkpoints/checkpoints.dart'
    show
        Checkpoint,
        CheckpointRestoreAnswer,
        checkpointFromJson,
        checkpointToJson;
import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala_conversations/karmashala_conversations.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:karmashala_git/cleanup.dart'
    show WorktreeCleanupLog, WorktreeCleanupReport;
import 'package:karmashala_git/git.dart'
    show
        AheadBehind,
        FileChange,
        FileDiffStat,
        GitBranchRef,
        GitCommit,
        GitPresence,
        GitWorktree,
        RepositoryOrigin,
        ReviewAnchor,
        ReviewAuthorKind,
        ReviewThread,
        ReviewThreadStatus,
        WorkingTreeStatus,
        WorktreeSetup,
        WorktreeSetupReport;
import 'package:karmashala_git/github.dart' show WorkflowRun, WorkflowRunLog;
import 'package:karmashala_files/values.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart' show SessionSummary;
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart'
    show kDefaultRelayPort;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/delivery.dart' show SessionDelivery;
import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_remote/remote.dart'
    show CapabilitySet, PairedDevice, pairedDeviceFromJson, pairedDeviceToJson;
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session/lineage.dart' show HandoffSourceBrief;
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_launch/karmashala_launch.dart'
    show AgentPaneLaunch, TerminalProfile;

import 'acp_agent_values.dart';
import 'acp_auth_values.dart';
import 'agent_work_values.dart';
import 'automation_values.dart';
import 'environment_values.dart';
import 'files_values.dart';
import 'git_values.dart';
import 'listening_port_values.dart';
import 'refusal.dart';
import 'session_values.dart';
import 'ssh_values.dart';
import 'workspace_values.dart';
import 'worktree_values.dart';
import 'flutter_values.dart';
import 'browser_values.dart';
import 'terminal_values.dart';
import 'env_values.dart';
import 'store_values.dart';
import 'package:store_console/store_console.dart' show StoreKind;
import 'attention_values.dart';
import 'package:karmashala_notifications/attention.dart' show InboxItem;
import 'session_work_values.dart';
import 'subagent_values.dart';
import 'transcript_values.dart';

part 'requests/subscription_requests.dart';
part 'requests/sessions_requests.dart';
part 'requests/notes_requests.dart';
part 'requests/todos_requests.dart';
part 'requests/preferences_requests.dart';
part 'requests/workspace_requests.dart';
part 'requests/hosts_requests.dart';
part 'requests/automations_requests.dart';
part 'requests/checkpoints_requests.dart';
part 'requests/worktrees_requests.dart';
part 'requests/snippets_requests.dart';
part 'requests/pairings_requests.dart';
part 'requests/conversations_requests.dart';
part 'requests/agent_work_requests.dart';
part 'requests/ssh_requests.dart';
part 'requests/git_requests.dart';
part 'requests/flutter_requests.dart';
part 'requests/browser_requests.dart';
part 'requests/files_requests.dart';
part 'requests/terminals_requests.dart';
part 'requests/env_requests.dart';
part 'requests/stores_requests.dart';
part 'requests/attention_requests.dart';
part 'requests/sessions_work_requests.dart';
part 'requests/session_transcript_requests.dart';
part 'requests/session_media_requests.dart';
part 'requests/session_subagents_requests.dart';
part 'requests/intents_requests.dart';
part 'requests/quick_access_requests.dart';
part 'requests/acp_agent_requests.dart';

/// One question or change a client asks of a server's data, answered with an
/// [R] or refused with [DataRefused]. Typed per domain: no SQL crosses.
sealed class DataRequest<R> {
  const DataRequest();

  /// The request's name on the wire, `<domain>.<verb>`.
  String get kind;

  Map<String, Object?> argumentsToJson();

  Object? resultToJson(R result);

  /// Throws [DataRefused] ([DataRefusalCode.failed]) on an answer that is
  /// not an [R] — a server of another build.
  R resultFromJson(Object? json);

  /// The request [kind] names. Throws [DataRefused.invalid] for an unknown
  /// kind or arguments that do not fit it.
  static DataRequest<Object?> fromJson(
    String kind,
    Map<String, Object?> arguments,
  ) {
    final args = _Arguments(kind, arguments);
    return switch (kind) {
      DataSubscribe.name => const DataSubscribe(),
      NotesList.name => NotesList(sessionId: args.optionalString('sessionId')),
      NoteCapture.name => NoteCapture._from(args),
      NoteEdit.name => NoteEdit._from(args),
      NoteFile.name => NoteFile(
        id: args.string('id'),
        projectId: args.optionalString('projectId'),
      ),
      NoteDelete.name => NoteDelete(args.string('id')),
      TodosList.name => const TodosList(),
      TodoAdd.name => TodoAdd._from(args),
      TodoSetDone.name => TodoSetDone(
        id: args.string('id'),
        done: args.boolean('done'),
      ),
      TodoEdit.name => TodoEdit(
        id: args.string('id'),
        body: args.string('body'),
      ),
      TodoFile.name => TodoFile(
        id: args.string('id'),
        projectId: args.optionalString('projectId'),
      ),
      TodoMove.name => TodoMove(id: args.string('id'), up: args.boolean('up')),
      TodoDelete.name => TodoDelete(args.string('id')),
      TodosClearDone.name => TodosClearDone(args.strings('ids')),
      PreferencesGet.name => const PreferencesGet(),
      PreferenceSet.name => PreferenceSet(
        args.string('key'),
        args.string('value'),
      ),
      PreferenceRemove.name => PreferenceRemove(args.string('key')),
      WorkspaceList.name => const WorkspaceList(),
      WorkspacePut.name => WorkspacePut(
        id: args.string('id'),
        workspaceName: args.string('name'),
        description: args.optionalString('description'),
      ),
      WorkspaceSetColor.name => WorkspaceSetColor(
        id: args.string('id'),
        color: args.optionalString('color'),
      ),
      WorkspaceDelete.name => WorkspaceDelete(args.string('id')),
      ProjectCreate.name => ProjectCreate._from(args),
      ProjectUpdate.name => ProjectUpdate._from(args),
      ProjectsFile.name => ProjectsFile(args.placements('placements')),
      ProjectDelete.name => ProjectDelete(args.string('id')),
      ProjectsUsingEnvironment.name => ProjectsUsingEnvironment(
        args.string('environmentId'),
      ),
      CheckoutsAdd.name => CheckoutsAdd(
        projectId: args.string('projectId'),
        found: args.found(),
        orRoot: args.boolean('orRoot', orElse: true),
      ),
      CheckoutsRetire.name => CheckoutsRetire(args.strings('ids')),
      CheckoutsIdentify.name => CheckoutsIdentify(
        path: args.value('path', environmentPathFromJson),
        canonicalId: args.optionalString('canonicalId'),
      ),
      SectionPut.name => SectionPut(
        args.value('section', StoredSection.fromJson),
      ),
      SectionsReorder.name => SectionsReorder(args.strings('ids')),
      SectionDelete.name => SectionDelete(args.string('id')),
      SessionsList.name => const SessionsList(),
      SessionCreate.name => SessionCreate(
        args.value('session', Session.fromJson),
        repositories: args.strings('repositories', orEmpty: true),
      ),
      SessionEdit.name => SessionEdit(
        args.string('id'),
        args.value('patch', SessionPatch.fromJson),
      ),
      SessionDelete.name => SessionDelete(args.string('id')),
      SessionLinkAdd.name => SessionLinkAdd(
        sessionId: args.string('sessionId'),
        repositoryId: args.string('repositoryId'),
      ),
      SessionLinkRemove.name => SessionLinkRemove(
        sessionId: args.string('sessionId'),
        repositoryId: args.string('repositoryId'),
      ),
      SessionEvents.name => SessionEvents(args.string('sessionId')),
      SessionEventsLatest.name => SessionEventsLatest(
        args.strings('sessionIds'),
      ),
      SessionEventsAppend.name => SessionEventsAppend(
        args.objects('events', SessionEvent.fromJson),
      ),
      DecisionAppend.name => DecisionAppend(
        args.value('decision', DecisionRecord.fromJson),
      ),
      RecapWrite.name => RecapWrite(args.value('recap', SessionRecap.fromJson)),
      RecapDismiss.name => RecapDismiss(args.string('sessionId')),
      RelayRecord.name => RelayRecord(
        args.value('relay', SessionRelay.fromJson),
      ),
      RelaysTo.name => RelaysTo(args.string('to'), args.integer('limit')),
      RelayCount.name => RelayCount(
        fromSessionId: args.string('from'),
        toSessionId: args.string('to'),
        since: args.date('since'),
      ),
      FollowUpRaise.name => FollowUpRaise(
        args.value('followUp', FollowUp.fromJson),
      ),
      FollowUpResolve.name => FollowUpResolve(
        args.integer('id'),
        FollowUpResolution.fromName(args.string('resolution'))!,
      ),
      ImportedAdd.name => ImportedAdd(args.value('session', importedFromJson)),
      ImportedRename.name => ImportedRename(
        id: args.string('id'),
        title: args.string('title'),
      ),
      ImportedDelete.name => ImportedDelete(args.string('id')),
      EnvironmentsList.name => const EnvironmentsList(),
      EnvironmentPut.name => EnvironmentPut(
        args.value('environment', environmentFromJson),
      ),
      SshHostPut.name => SshHostPut(args.value('host', sshHostFromJson)),
      SshHostDelete.name => SshHostDelete(args.string('id')),
      KnownHostTrust.name => KnownHostTrust(
        args.value('key', knownHostFromJson),
      ),
      KnownHostForget.name => KnownHostForget(
        args.string('host'),
        args.integer('port'),
      ),
      AgentsList.name => const AgentsList(),
      InstallationSetPath.name => InstallationSetPath(
        id: args.string('id'),
        path: args.string('path'),
      ),
      ClaudeAccountDelete.name => ClaudeAccountDelete(args.string('id')),
      CodexAccountDelete.name => CodexAccountDelete(args.string('id')),
      UsageHistory.name => UsageHistory(
        args.string('accountKey'),
        args.date('since'),
      ),
      _ => _domainRequestFromJson(kind, args),
    };
  }

  @override
  String toString() => 'DataRequest($kind)';
}

/// A request of the domains slice 1e moved, each family read by its own part
/// file; refused when none knows [kind].
DataRequest<Object?> _domainRequestFromJson(String kind, _Arguments args) =>
    _automationsRequestFromJson(kind, args) ??
    _checkpointsRequestFromJson(kind, args) ??
    _worktreesRequestFromJson(kind, args) ??
    _snippetsRequestFromJson(kind, args) ??
    _pairingsRequestFromJson(kind, args) ??
    _conversationsRequestFromJson(kind, args) ??
    _agentWorkRequestFromJson(kind, args) ??
    _sshRequestFromJson(kind, args) ??
    _gitRequestFromJson(kind, args) ??
    _flutterRequestFromJson(kind, args) ??
    _browserRequestFromJson(kind, args) ??
    _filesRequestFromJson(kind, args) ??
    _terminalsRequestFromJson(kind, args) ??
    _envRequestFromJson(kind, args) ??
    _storesRequestFromJson(kind, args) ??
    _attentionRequestFromJson(kind, args) ??
    _sessionWorkRequestFromJson(kind, args) ??
    _sessionTranscriptRequestFromJson(kind, args) ??
    _sessionMediaRequestFromJson(kind, args) ??
    _sessionSubagentsRequestFromJson(kind, args) ??
    _intentsRequestFromJson(kind, args) ??
    _quickAccessRequestFromJson(kind, args) ??
    _acpAgentsRequestFromJson(kind, args) ??
    (throw DataRefused.invalid('no data request is called "$kind"'));

/// The answer to a request that changes something and reports nothing more.
final class DataAck {
  const DataAck();
}

/// Reads one request's arguments, refusing what does not fit.
final class _Arguments {
  _Arguments(this.kind, this.values);

  final String kind;
  final Map<String, Object?> values;

  String string(String key) {
    final value = values[key];
    if (value is String) return value;
    throw DataRefused.invalid('$kind: "$key" must be a string');
  }

  String? optionalString(String key) {
    final value = values[key];
    if (value == null || value is String) return value as String?;
    throw DataRefused.invalid('$kind: "$key" must be a string or absent');
  }

  /// A string or a bool: a `select` choice's value, or a flag.
  Object stringOrBool(String key) {
    final value = values[key];
    if (value is String || value is bool) return value!;
    throw DataRefused.invalid('$kind: "$key" must be a string or a bool');
  }

  int? optionalInt(String key) {
    final value = values[key];
    if (value == null || value is int) return value as int?;
    throw DataRefused.invalid('$kind: "$key" must be a whole number or absent');
  }

  bool boolean(String key, {bool? orElse}) {
    final value = values[key];
    if (value is bool) return value;
    if (value == null && orElse != null) return orElse;
    throw DataRefused.invalid('$kind: "$key" must be true or false');
  }

  /// The value under [key] as [read] makes it, refusing one out of shape.
  T value<T>(String key, T Function(Map<String, Object?> json) read) {
    final value = values[key];
    try {
      if (value is Map) return read(value.cast<String, Object?>());
    } on FormatException {
      // Refused below, in the same words.
    }
    throw DataRefused.invalid('$kind: "$key" is not what it should be');
  }

  /// Checkouts discovery found, under `found` — none when absent.
  List<DiscoveredRepository> found() {
    final value = values['found'] ?? const <Object?>[];
    try {
      if (value is List) {
        return [for (final item in value) discoveredFromJson(item)];
      }
    } on FormatException {
      // Refused below.
    }
    throw DataRefused.invalid('$kind: "found" must be a list of checkouts');
  }

  /// Ids mapped to an id or null.
  Map<String, String?> placements(String key) {
    final value = values[key];
    if (value is Map &&
        value.keys.every((k) => k is String) &&
        value.values.every((v) => v == null || v is String)) {
      return value.cast<String, String?>();
    }
    throw DataRefused.invalid('$kind: "$key" must map ids to an id or null');
  }

  List<String> strings(String key, {bool orEmpty = false}) {
    final value = values[key] ?? (orEmpty ? const <String>[] : null);
    if (value is List && value.every((item) => item is String)) {
      return value.cast<String>();
    }
    throw DataRefused.invalid('$kind: "$key" must be a list of strings');
  }

  int integer(String key) {
    final value = values[key];
    if (value is int) return value;
    throw DataRefused.invalid('$kind: "$key" must be a whole number');
  }

  DateTime date(String key) {
    final value = values[key];
    final parsed = value is String ? DateTime.tryParse(value) : null;
    if (parsed != null) return parsed.toUtc();
    throw DataRefused.invalid('$kind: "$key" must be a time');
  }

  /// Each object under [key] as [read] makes it, refusing the list whole for
  /// one out of shape.
  List<T> objects<T>(String key, T Function(Map<String, Object?> json) read) {
    final value = values[key];
    try {
      if (value is List) {
        return [
          for (final item in value)
            if (item is Map)
              read(item.cast<String, Object?>())
            else
              throw const FormatException('not an object'),
        ];
      }
    } on FormatException {
      // Refused below.
    }
    throw DataRefused.invalid('$kind: "$key" must be a list of objects');
  }
}

Never _badAnswer(String kind) => throw DataRefused(
  DataRefusalCode.failed,
  'the server answered $kind with something this client cannot read',
);

Map<String, Object?> _object(Object? json, String kind) =>
    json is Map ? json.cast<String, Object?>() : _badAnswer(kind);

List<Map<String, Object?>> _objects(Object? json, String kind) => json is List
    ? [for (final item in json) _object(item, kind)]
    : _badAnswer(kind);

T _decode<T>(String kind, T Function() read) {
  try {
    return read();
  } on DataRefused {
    rethrow;
  } on Object {
    _badAnswer(kind);
  }
}
