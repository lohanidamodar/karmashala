import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// An [SSHSocket] whose teardown cannot throw into nowhere: `dartssh2` closes
/// from a stream callback without awaiting, so a failed close escapes.
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
