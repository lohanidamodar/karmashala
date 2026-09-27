part of 'fake_data_server.dart';

/// The server's own SSH (slice 3a) as a test scripts it: what `ssh.test`
/// answers, the answers a window gave its questions, and the questions and
/// connection states the server tells every window.
class FakeSshWork {
  FakeSshWork._(this._server);

  final FakeDataServer _server;

  /// What `ssh.test` answers; a success by default.
  SshTestResult Function(SshTest request) onTest = (_) =>
      const SshTestResult(connected: true, message: 'Linux 6.18.0');

  /// Each `ssh.test` asked.
  final tests = <SshTest>[];

  /// Each `ssh.answerPrompt`, secret and all — what a window sent.
  final answers = <SshAnswerPrompt>[];

  /// Each `ssh.disconnect`, by host id.
  final disconnects = <String>[];

  /// The server tells every window: a connection moved, a question opened
  /// or closed.
  void tell(List<SshChange> changes) => _server._tell(null, changes);

  Object? _handle(SshWorkRequest<Object?> request) => switch (request) {
    final SshTest r => () {
      tests.add(r);
      return onTest(r);
    }(),
    SshDisconnect(:final hostId) => () {
      disconnects.add(hostId);
      return const DataAck();
    }(),
    final SshAnswerPrompt r => () {
      answers.add(r);
      return const DataAck();
    }(),
  };
}
