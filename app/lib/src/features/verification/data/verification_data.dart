import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// Verification runs as the server keeps them. Every run's header is copied
/// (a session's verdict reads at once); a run's steps and evidence rows are
/// asked for. The evidence files themselves stay on disk.
class VerificationData implements VerificationRecords {
  VerificationData(this._client);

  final DataClient _client;
  List<VerificationRun>? _sorted;
  var _sortedAt = -1;

  /// Fires after a header moved, here or at another client.
  Stream<void> get changes => _client.verificationRuns.changes;

  /// Every run's header, newest first.
  List<VerificationRun> headers() {
    final replica = _client.verificationRuns;
    if (_sortedAt != replica.version) {
      _sorted = List.unmodifiable(
        <VerificationRun>[...replica.values]..sort(compareVerificationRuns),
      );
      _sortedAt = replica.version;
    }
    return _sorted!;
  }

  /// [sessionId]'s run headers, newest first.
  List<VerificationRun> headersOf(String sessionId) => [
    for (final run in headers())
      if (run.sessionId == sessionId) run,
  ];

  /// The newest [limit] runs — of [sessionId] when given — whole.
  Future<List<VerificationRun>> recent({int limit = 50, String? sessionId}) =>
      _ask(VerificationRecent(limit: limit, sessionId: sessionId));

  Future<VerificationRun?> get(String id) => _ask(VerificationGet(id));

  /// Headers of the runs whose id starts with [prefix].
  Future<List<VerificationRun>> matching(String prefix) =>
      _ask(VerificationMatching(prefix));

  @override
  Future<VerificationRun> record(VerificationRun run) =>
      _write(VerificationRecord(run));

  Future<VerificationRun> attach(String id, String? sessionId) =>
      _write(VerificationAttach(id, sessionId));

  Future<void> delete(String id) => _write(VerificationDelete(id));

  Future<R> _ask<R>(DataRequest<R> request) async =>
      (await _client.send(request)).value;

  Future<R> _write<R>(DataRequest<R> request) =>
      _client.write(request, domain: DataDomain.evidence);
}

final verificationDataProvider = Provider<VerificationData>(
  (ref) => VerificationData(ref.watch(dataClientProvider)),
);
