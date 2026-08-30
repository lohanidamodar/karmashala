import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// An [SSHSocket] whose teardown cannot throw into nowhere.
///
/// When a peer hangs up mid-transfer, closing the socket fails because bytes
/// are still queued for a connection that no longer exists. `dartssh2` closes
/// the socket from a stream callback and does not await the result, so that
/// failure escapes as an unhandled asynchronous error — a remote host dropping
/// the link should be reported through [SshConnection]'s state machine, not
/// raised somewhere the app cannot see it.
///
/// Everything else is delegated untouched: this changes error plumbing, not
/// behaviour.
class ResilientSshSocket implements SSHSocket {
  ResilientSshSocket(this._inner);

  final SSHSocket _inner;

  @override
  Stream<Uint8List> get stream => _inner.stream;

  @override
  StreamSink<List<int>> get sink => _inner.sink;

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() async {
    try {
      await _inner.close();
    } on Object {
      // The connection is already gone; make sure the handle follows it.
      _inner.destroy();
    }
  }

  @override
  void destroy() => _inner.destroy();

  @override
  Future<void> flush() async {
    try {
      await _inner.flush();
    } on Object {
      // Nothing can be flushed to a dead socket; the drop is reported elsewhere.
    }
  }

  @override
  String toString() => 'ResilientSshSocket($_inner)';
}
