import 'dart:typed_data';

/// What one command said.
class RemoteRun {
  const RemoteRun(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
  String get output => '$stdout$stderr'.trim();
}

/// A long-lived byte channel the host protocol is spoken over: a unix socket
/// to this machine's server, or an exec channel running `karmashala_host
/// attach` on a box. Bytes only, exactly as the host expects them.
abstract class RemoteChannel {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  void add(Uint8List bytes);
  Future<int> get exitCode;

  /// Ends our side. The host observes the disconnect and keeps the sessions.
  Future<void> close();
}
