import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'package:agent_cli/process.dart';

/// Exit code reported when a remote process ends without one — the connection
/// dropped, or the server never sent an exit status. It is `ssh(1)`'s own code
/// for "something went wrong with the connection itself", and it is deliberately
/// non-zero: a lost link must never read as a command that succeeded.
const int kSshConnectionLostExitCode = 255;

/// [ProcessHandle] backed by a `dartssh2` [SSHSession].
///
/// The remote side speaks bytes on a channel rather than a `dart:io` pipe, so
/// this is the SSH counterpart of `IoProcessHandle`: same contract,
/// line-buffered text in and out, different transport.
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
    // The channel's EOF. `dartssh2` pipes this sink into the channel, so
    // closing it is what tells the remote process no more input is coming —
    // `codex exec` and the package's one-shot `ask` wait on stdin forever
    // without it. Already closed, or a session that is gone, is not an error.
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
