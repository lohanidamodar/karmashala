import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart';

import 'link_trust.dart';
import 'transport.dart';

/// A desktop client on another machine (slice 5e): the companion's sealed
/// channel after `host.attach`, served like any other connection with what
/// its pairing grants.
class SealedHostConnection implements HostConnection {
  SealedHostConnection(this._link);

  final SealedHostLink _link;

  /// What this link may do: the grants its pairing names.
  LinkTrust get trust => LinkTrust.remote(
    admin: _link.capabilities.has(Capability.serverAdmin),
    sshPrompts: _link.capabilities.has(Capability.sshPrompts),
    label: _link.deviceName,
  );

  @override
  String get description =>
      'remote:${_link.deviceName ?? _link.deviceId ?? 'device'}';

  @override
  Stream<Uint8List> get incoming => _link.incoming;

  @override
  void add(Uint8List bytes) => _link.add(bytes);

  @override
  Future<void> flush() => _link.flush();

  @override
  Future<void> close() async => _link.close('the server hung up');

  @override
  Future<void> get done => _link.done;
}
