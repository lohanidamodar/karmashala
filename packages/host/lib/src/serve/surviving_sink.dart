import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The daemon's stdout or stderr, which may lose its reader at any moment and
/// must never take the daemon with it.
///
/// The app starts `serve` with pipes on both (`detachedWithStdio`, to read the
/// banner) and then quits, leaving the host running with nobody at the other
/// end. The next line the host wrote failed with a broken pipe, and a
/// `dart:io` sink reports that as an error on its `done` future — which no one
/// was listening to, so it was an **unhandled error that killed the main
/// isolate**. The VM then waited, for ever, for the pty readers blocked in
/// `read()` to stop, so the process neither served nor exited (2026-09-25: an
/// automation's "run is blocked" line was the first thing logged after the app
/// quit; the host went silent and kept its sockets).
///
/// This writes until the first failure, then quietly drops everything: a log
/// line is worth less than every session on the machine. Nothing here throws,
/// and [done] never completes with an error.
class SurvivingSink implements IOSink {
  SurvivingSink(this._inner) {
    // Listened to at once: an error that reaches `done` unobserved is fatal.
    _done = _inner.done.then<void>((_) {}, onError: (Object _) => _lost());
  }

  final IOSink _inner;
  late final Future<void> _done;
  var _dead = false;

  /// True once a write has failed; everything since was dropped.
  bool get lost => _dead;

  void _lost() => _dead = true;

  void _guard(void Function() write) {
    if (_dead) return;
    try {
      write();
    } on Object {
      _lost();
    }
  }

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _guard(() => _inner.add(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    // An error on a log is not something to hand to the pipe.
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    if (_dead) return stream.drain<void>();
    await _settled(() => _inner.addStream(stream));
  }

  @override
  void write(Object? object) => _guard(() => _inner.write(object));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _guard(() => _inner.writeAll(objects, separator));

  @override
  void writeCharCode(int charCode) =>
      _guard(() => _inner.writeCharCode(charCode));

  @override
  void writeln([Object? object = '']) => _guard(() => _inner.writeln(object));

  @override
  Future<void> flush() => _settled(_inner.flush);

  @override
  Future<void> close() => _settled(_inner.close);

  /// [action], or the pipe breaking — whichever comes first: a sink whose
  /// target failed may never finish a flush it was asked for.
  Future<void> _settled(Future<void> Function() action) async {
    if (_dead) return;
    try {
      await Future.any([action(), _done]);
    } on Object {
      _lost();
    }
  }

  @override
  Future<void> get done => _done;
}
