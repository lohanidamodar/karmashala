import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'package:karmashala_ssh/connection.dart';

/// What one command said.
class RemoteRun {
  const RemoteRun(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
  String get output => '$stdout$stderr'.trim();
}

/// A long-lived exec channel: the transport the app speaks the host protocol
/// over. Bytes only, exactly as `karmashala_host attach` expects them.
abstract class RemoteChannel {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  void add(Uint8List bytes);
  Future<int> get exitCode;

  /// Ends our side. The host observes the disconnect and keeps the sessions.
  Future<void> close();
}

/// The three things deploying a host needs from a machine. A narrow interface
/// on purpose: the deployer's logic is then testable against a fake.
abstract class HostDeployTarget {
  String get address;

  Future<RemoteRun> run(String command);

  /// Writes a file and makes it executable. Overwrites.
  Future<void> upload(String remotePath, Uint8List bytes);

  Future<RemoteChannel> exec(String command);
}

/// [HostDeployTarget] over the app's [SshConnection]. **Untested**: it needs a
/// real sshd, and the stand-in WSL distribution does not run one.
class SshHostDeployTarget implements HostDeployTarget {
  SshHostDeployTarget(this._connection);

  final SshConnection _connection;

  @override
  String get address => _connection.host.address;

  @override
  Future<RemoteRun> run(String command) => _connection.runOnChannel((
    client,
  ) async {
    final session = await client.execute(command);
    final out = StringBuffer();
    final err = StringBuffer();
    final collecting = Future.wait([
      session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach(out.write),
      session.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach(err.write),
    ]);
    await session.done;
    await collecting;
    // A session that ends with no status is a lost link, never a success.
    return RemoteRun(session.exitCode ?? 255, out.toString(), err.toString());
  });

  @override
  Future<void> upload(String remotePath, Uint8List bytes) =>
      _connection.runOnChannel((client) async {
        final sftp = await client.sftp();
        try {
          final file = await sftp.open(
            remotePath,
            mode:
                SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.truncate,
          );
          try {
            await file.write(Stream.value(bytes));
          } finally {
            await file.close();
          }
          // 0o755. Written after the bytes so a half-uploaded binary is never
          // executable, which is the shape a killed upload takes.
          await sftp.setStat(
            remotePath,
            SftpFileAttrs(
              mode: SftpFileMode(
                userRead: true,
                userWrite: true,
                userExecute: true,
                groupRead: true,
                groupExecute: true,
                otherRead: true,
                otherExecute: true,
              ),
            ),
          );
        } finally {
          unawaited(sftp.close());
        }
      });

  /// Not run through [SshConnection.runOnChannel]: this channel lives as long
  /// as its pane, and queuing it behind the command slots would deadlock them.
  @override
  Future<RemoteChannel> exec(String command) async {
    final client = await _connection.client();
    return _SshRemoteChannel(await client.execute(command));
  }
}

class _SshRemoteChannel implements RemoteChannel {
  _SshRemoteChannel(this._session);

  final SSHSession _session;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  void add(Uint8List bytes) => _session.write(bytes);

  @override
  Future<int> get exitCode async {
    await _session.done;
    return _session.exitCode ?? 255;
  }

  @override
  Future<void> close() async {
    _session.close();
    await _session.done;
  }
}
