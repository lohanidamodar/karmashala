import 'dart:io';

import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import '../../../core/database/sqlite_writer.dart';
import 'agent_store_servers.dart';

/// What a batched delete could not remove. [label] is the session's own title,
/// or the store index, so the report reads as a list rather than a stack trace.
class CliDeleteFailure {
  const CliDeleteFailure({required this.label, required this.error});

  final String label;
  final Object error;

  @override
  String toString() => 'CliDeleteFailure($label, $error)';
}

/// The outcome of [CliSessionMutator.deleteAll]: what went, and what did not.
class CliDeleteReport {
  const CliDeleteReport({required this.deleted, required this.failures});

  static const empty = CliDeleteReport(deleted: 0, failures: []);

  /// Transcripts actually removed. Counted after the fact, never optimistically:
  /// this is the one operation here that nothing can put back.
  final int deleted;

  final List<CliDeleteFailure> failures;

  bool get isComplete => failures.isEmpty;
}

/// Renames and deletes detected CLI sessions the way each CLI does it — asked
/// of the agent's adapter (`AgentStore.editor`), never decided by its name. A
/// store with no editor is left alone.
class CliSessionMutator {
  CliSessionMutator({
    this.registry = AgentRegistry.builtIn,
    this.writeSqlite = writeSqliteStatements,
  });

  static final _log = AppLogger.named('cli.sessionMutator');

  final AgentRegistry registry;
  final SqliteWriter writeSqlite;

  /// What a delete actually costs the store, counted rather than timed: index
  /// walks, records decoded, index files rewritten, transcripts removed.
  final StoreEditCounters _counters = StoreEditCounters();
  int get storeScans => _counters.storeScans;
  int get indexEntriesRead => _counters.indexEntriesRead;
  int get indexWrites => _counters.indexWrites;
  int transcriptsDeleted = 0;

  StoreEditContext _context(AgentStoreServers? servers, String agentId) =>
      StoreEditContext(
        counters: _counters,
        writeSqlite: writeSqlite,
        serverFor: servers == null
            ? null
            : (environmentId, storeHome) => servers.forEnvironment(
                environmentId,
                agentId,
                storeHome: storeHome,
              ),
      );

  /// Renames one session in its CLI's own store. Without [servers] a store
  /// that must be asked to rename is skipped, never faked by writing a file
  /// the CLI ignores.
  Future<void> rename(
    DetectedSession session,
    String newTitle, {
    AgentStoreServers? servers,
  }) async {
    final title = newTitle.trim();
    if (title.isEmpty) {
      throw ArgumentError('Title cannot be empty');
    }
    final editor = registry.adapterFor(session.cli)?.store?.editor;
    if (editor == null) {
      _log.warning('No way to rename a ${session.cli} conversation in place');
      return;
    }
    await editor.rename(session, title, _context(servers, session.cli));
  }

  /// Deletes one session, throwing if it could not be removed. Implemented as
  /// [deleteAll] of one, so the two cannot treat a store differently.
  Future<void> delete(DetectedSession session) async {
    final report = await deleteAll([session]);
    final failure = report.failures.firstOrNull;
    if (failure != null) throw failure.error;
  }

  /// Deletes every session in [sessions], walking each store's index once
  /// rather than once per session. Never throws: what failed comes back listed.
  Future<CliDeleteReport> deleteAll(Iterable<DetectedSession> sessions) async {
    final groups = <(String, String), List<DetectedSession>>{};
    for (final session in sessions) {
      groups
          .putIfAbsent((session.cli, session.storeHome), () => [])
          .add(session);
    }
    var deleted = 0;
    final failures = <CliDeleteFailure>[];
    for (final entry in groups.entries) {
      final (cli, storeHome) = entry.key;
      final group = entry.value;
      final removed = <String>{};
      for (final session in group) {
        try {
          final file = File(session.filePath);
          if (await file.exists()) {
            await file.delete();
            transcriptsDeleted++;
          }
          removed.add(session.sessionId);
          deleted++;
        } catch (error) {
          failures.add(
            CliDeleteFailure(label: session.displayTitle, error: error),
          );
        }
      }
      if (removed.isEmpty) continue;
      final editor = registry.adapterFor(cli)?.store?.editor;
      if (editor == null) continue;
      try {
        await editor.prune(storeHome, removed, _context(null, cli));
      } catch (error) {
        // The transcripts are gone either way; a stale index entry is a lesser
        // problem than a silent one, so it is still reported.
        failures.add(
          CliDeleteFailure(label: '$cli session index', error: error),
        );
      }
    }
    return CliDeleteReport(deleted: deleted, failures: failures);
  }
}
