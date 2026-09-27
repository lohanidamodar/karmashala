part of '../data_request.dart';

// SSH reached by the server itself (slice 3a). The connection is the
// server's; what it cannot decide alone — an unknown host key, a password, a
// key passphrase — is put to every desktop client as `SshPromptOpened`, and
// the first answer wins. A secret travels client → server in
// `ssh.answerPrompt` only: never in an answer, a change, a log line or a
// `toString` (a request prints its kind alone). Phones are forwarded none of
// these.

DataRequest<Object?>? _sshRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      SshTest.name => SshTest(
        hostId: args.optionalString('hostId'),
        draft: args.values['draft'] == null
            ? null
            : args.value('draft', sshHostFromJson),
      ),
      SshDisconnect.name => SshDisconnect(args.string('hostId')),
      SshAnswerPrompt.name => SshAnswerPrompt(
        args.string('promptId'),
        trust: args.values['trust'] == null ? null : args.boolean('trust'),
        secret: args.optionalString('secret'),
      ),
      _ => null,
    };

/// Work the server does on an SSH connection of its own; answered when done.
sealed class SshWorkRequest<R> extends DataRequest<R> {
  const SshWorkRequest();
}

/// Connects to saved host [hostId] — or to [draft], settings not yet saved —
/// once, runs one command and hangs up. A prompt it needs is put to the
/// clients. Answers what happened, a failure included.
final class SshTest extends SshWorkRequest<SshTestResult> {
  const SshTest({this.hostId, this.draft})
    : assert((hostId == null) != (draft == null), 'a host id or a draft');

  static const String name = 'ssh.test';

  final String? hostId;
  final SshHost? draft;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'hostId': ?hostId,
    if (draft != null) 'draft': sshHostToJson(draft!),
  };

  @override
  Object? resultToJson(SshTestResult result) => result.toJson();

  @override
  SshTestResult resultFromJson(Object? json) =>
      _decode(kind, () => SshTestResult.fromJson(_object(json, kind)));
}

/// Closes the server's connection to host [hostId]; the next use dials again.
final class SshDisconnect extends SshWorkRequest<DataAck> {
  const SshDisconnect(this.hostId);

  static const String name = 'ssh.disconnect';

  final String hostId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'hostId': hostId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Answers prompt [promptId]: [trust] for a host key, [secret] for a password
/// or passphrase (null for "cancelled"). The first answer wins; a later one
/// is refused `notFound`. [secret] is used for one connection attempt and
/// never kept.
final class SshAnswerPrompt extends SshWorkRequest<DataAck> {
  const SshAnswerPrompt(this.promptId, {this.trust, this.secret});

  static const String name = 'ssh.answerPrompt';

  final String promptId;
  final bool? trust;
  final String? secret;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'promptId': promptId,
    'trust': ?trust,
    'secret': ?secret,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
