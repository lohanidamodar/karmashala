import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'package:agent_cli/process.dart';

/// Exit code when a remote process ends without one. `ssh(1)`'s own code for
/// the connection itself failing, and non-zero: a lost link is not a success.
const int kSshConnectionLostExitCode = 255;

/// [ProcessHandle] backed by a `dartssh2` [SSHSession]: the SSH counterpart of
/// `IoProcessHandle`, same contract over a channel rather than a pipe.
class SshProcessHandle implements ProcessHandle {
  SshProcessHandle(this._session);

  final SSHSession _session;

  @override
  Stream<String> get stdoutLines => _session.stdout
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  @override
  Stream<List<int>> get stdoutBytes => _session.stdout.cast<List<int>>();

  @override
  Stream<String> get stderrLines => _session.stderr
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  @override
  void writeLine(String line) {
    _session.write(Uint8List.fromList(utf8.encode('$line\n')));
  }

  @override
  Future<void> closeStdin() async {
    // The channel's EOF: closing this sink tells the remote process no more
    // input is coming, and `codex exec` waits on stdin for ever without it.
    try {
      await _session.stdin.close();
    } on Object {
      // Nothing left to close.
    }
  }

  @override
  Future<int> get exitCode async {
    await _session.done;
    return _session.exitCode ?? kSshConnectionLostExitCode;
  }

  @override
  Future<void> interrupt() async {
    _session.kill(SSHSignal.INT);
    try {
      await _session.done.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      await kill();
    }
  }

  @override
  Future<void> kill() async {
    _session.kill(SSHSignal.TERM);
    try {
      await _session.done.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _session.kill(SSHSignal.KILL);
      _session.close();
      await _session.done;
    }
  }
}
