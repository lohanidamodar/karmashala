import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_cli/descriptors.dart'
    show
        AgentQuestionSet,
        AgentRegistry,
        AgentRewindPoints,
        AgentStoreServerClient,
        OwnRewindPoints,
        StoreServerFileChange,
        StoreServerFileChanges,
        TranscriptFileEdits,
        openQuestionIn;
import 'package:agent_cli/process.dart'
    show CommandRequest, CommandRunnerFactory;
import 'package:agent_cli/read.dart' show FileEditRecord;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;
import 'package:karmashala_session/delivery.dart' show SessionRecordGap;
import 'package:karmashala_session_engine/store.dart' show SessionDao;

import 'session_records.dart';

/// **The readers of a session's raw record lines, run here for any client**
/// (Stage 0 step 7): its agent's rewind points, the files it changed and the
/// question it has open. Each runs the agent adapter's own code over the
/// record [lookUp] finds, as the app ran it over its own disk.
class SessionRecordReadings {
  SessionRecordReadings({
    required this.lookUp,
    required this.registry,
    required this.sessions,
    required this.rows,
    required this.runners,
  });

  final Future<SessionRecordLookup> Function(String sessionId) lookUp;
  final AgentRegistry registry;
  final SessionDao sessions;
  final CheckoutRows rows;
  final CommandRunnerFactory runners;

  /// One store server per (environment, agent), opened on first use.
  final _storeServers = <(String, String), AgentStoreServerClient>{};

  Future<AgentRewindPoints?> rewindPoints(String sessionId) async {
    final found = await lookUp(sessionId);
    final path = found.path;
    final agentId = found.agentId;
    if (path == null || agentId == null) return null;
    final rewind = registry.adapterFor(agentId)?.rewind;
    if (rewind is! OwnRewindPoints) return null;
    final marker = rewind.lineMarker;
    final parse = rewind.parse;
    try {
      return await Isolate.run(() async {
        final lines = await File(path)
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((line) => line.contains(marker))
            .toList();
        return parse(lines);
      });
    } on FileSystemException {
      return null;
    }
  }

  Future<AgentFileChangesReading> changedFiles(String sessionId) async {
    final found = await lookUp(sessionId);
    final agentId = found.agentId;
    final record = agentId == null
        ? null
        : registry.adapterFor(agentId)?.fileChanges;
    switch (record) {
      case null:
        return const AgentFileChangesReading(
          gap: SessionRecordGap.agentKeepsNoRecord,
        );
      case StoreServerFileChanges():
        return _fromStoreServer(sessionId, agentId!);
      case TranscriptFileEdits(:final editsOnLine):
        final path = found.path;
        if (path == null) {
          final row = sessions.getById(sessionId);
          final conversation = row?.externalSessionId ?? '';
          return conversation.isEmpty
              ? const AgentFileChangesReading(
                  gap: SessionRecordGap.noConversationYet,
                )
              : const AgentFileChangesReading(
                  gap: SessionRecordGap.recordUnreadable,
                  detail:
                      'no transcript for this conversation in any store the '
                      'server can read',
                );
        }
        try {
          return AgentFileChangesReading(
            changes: await Isolate.run(() => _editsIn(path, editsOnLine)),
          );
        } on Object catch (error) {
          return AgentFileChangesReading(
            gap: SessionRecordGap.recordUnreadable,
            detail: '$error',
          );
        }
    }
  }

  Future<AgentQuestionSet?> openQuestion(String sessionId) async {
    final found = await lookUp(sessionId);
    final path = found.path;
    final agentId = found.agentId;
    if (path == null || agentId == null) return null;
    final support = registry.byId(agentId)?.questions;
    if (support == null) return null;
    try {
      return openQuestionIn(await _tail(File(path)), support);
    } on FileSystemException {
      return null;
    }
  }

  Future<void> close() async {
    final open = _storeServers.values.toList(growable: false);
    _storeServers.clear();
    for (final client in open) {
      await client.close();
    }
  }

  Future<AgentFileChangesReading> _fromStoreServer(
    String sessionId,
    String agentId,
  ) async {
    final row = sessions.getById(sessionId);
    final conversation = row?.externalSessionId ?? '';
    if (row == null || conversation.isEmpty) {
      return const AgentFileChangesReading(
        gap: SessionRecordGap.noConversationYet,
      );
    }
    final executable = rows.installation(row.agentInstallationId)?.executable;
    final environment = executable == null
        ? null
        : rows.environment(executable.environmentId);
    if (executable == null || environment == null) {
      return const AgentFileChangesReading(
        gap: SessionRecordGap.recordUnreadable,
        detail: 'no environment row',
      );
    }
    final key = (environment.id, agentId);
    var client = _storeServers[key];
    if (client == null) {
      final server = registry.adapterFor(agentId)?.storeServer;
      final name =
          registry.adapterFor(agentId)?.presentation.shortName ?? agentId;
      if (server == null) {
        return AgentFileChangesReading(
          gap: SessionRecordGap.recordUnreadable,
          detail: 'no $name to ask on ${environment.name}',
        );
      }
      try {
        final runner = runners.forEnvironment(environment);
        client = server.open(
          connect: () => runner.start(
            CommandRequest(
              executable: executable.path,
              arguments: server.arguments,
            ),
          ),
          clientVersion: kHostVersion,
        );
      } on Object catch (error) {
        return AgentFileChangesReading(
          gap: SessionRecordGap.recordUnreadable,
          detail: 'no $name to ask on ${environment.name}: $error',
        );
      }
      _storeServers[key] = client;
    }
    try {
      final result = await client.listFileChanges(conversation);
      final failure = result.failure;
      if (failure != null) {
        return AgentFileChangesReading(
          gap: SessionRecordGap.recordUnreadable,
          detail: failure,
        );
      }
      return AgentFileChangesReading(changes: result.changes);
    } on Object catch (error) {
      return AgentFileChangesReading(
        gap: SessionRecordGap.recordUnreadable,
        detail: '$error',
      );
    }
  }
}

/// Every edit [path]'s lines record, oldest first, streamed.
Future<List<StoreServerFileChange>> _editsIn(
  String path,
  List<FileEditRecord> Function(Map<String, Object?> json) editsOnLine,
) async {
  final changes = <StoreServerFileChange>[];
  await for (final line
      in File(
        path,
      ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    for (final edit in editsOnLine(decoded)) {
      changes.add(StoreServerFileChange(path: edit.path, kind: edit.kind));
    }
  }
  return changes;
}

/// The end of a record: a question is the newest thing in it while open.
Future<String> _tail(File file, {int bytes = 65536}) async {
  final handle = await file.open();
  try {
    final size = await handle.length();
    final start = size > bytes ? size - bytes : 0;
    await handle.setPosition(start);
    return const Utf8Decoder(
      allowMalformed: true,
    ).convert(await handle.read(size - start));
  } finally {
    await handle.close();
  }
}
