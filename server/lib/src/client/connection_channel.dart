import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host_protocol/host_access.dart';

import '../transport/transport.dart';

/// A [HostConnection] as the byte channel a [HostClientLink] runs over, so a
/// client built on a socket or a pipe shares the one multiplexed link.
class ConnectionChannel implements RemoteChannel {
  ConnectionChannel(this._connection);

  final HostConnection _connection;

  @override
  Stream<Uint8List> get stdout => _connection.incoming;

  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  void add(Uint8List bytes) => _connection.add(bytes);

  @override
  Future<int> get exitCode => _connection.done.then((_) => 0);

  @override
  Future<void> close() => _connection.close();
}
