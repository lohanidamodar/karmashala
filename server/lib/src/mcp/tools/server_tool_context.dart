import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_store/database.dart';

import '../../data/data_service.dart';
import '../../domain/uuid.dart';

/// What the server's own agent tools read and write through: the store for
/// reads (the DAOs, synchronous), the data service for writes — so every
/// client is told of a tool's write exactly as of its own — the agents'
/// adapters, and the server's clock and ids.
class ServerToolContext {
  ServerToolContext({
    required this.database,
    required this.data,
    required this.dataDirectory,
    this.agents = AgentRegistry.builtIn,
    DateTime Function()? clock,
    String Function()? newId,
    void Function(String message)? log,
  }) : _now = clock ?? _utcNow,
       newId = newId ?? newUuid,
       log = log ?? _silent,
       _writes = data.open(_ignore);

  final AppDatabase database;
  final DataService data;

  /// `<data dir>`: verification evidence, attachments, MCP configs.
  final String dataDirectory;
  final AgentRegistry agents;
  final String Function() newId;
  final void Function(String message) log;
  final DateTime Function() _now;

  /// The tools' own link: never subscribed, so nothing is delivered to it —
  /// its writes are told to every client that is.
  final DataSession _writes;

  DateTime now() => _now().toUtc();

  /// Asks the data service [request] as a client would, and answers its
  /// value. A refusal is thrown as it is ([DataRefused]), which is what an
  /// agent read when the app made the same request.
  R write<R>(DataRequest<R> request) => _writes.handle(request).value;

  /// [write] for a request answered when its work is done (a catch-up).
  Future<R> writeLater<R>(DataRequest<R> request) async =>
      (await _writes.handleLater(request)).value;

  void close() => _writes.close();

  static DateTime _utcNow() => DateTime.now().toUtc();
  static void _silent(String _) {}
  static void _ignore(DataChanges _) {}
}
