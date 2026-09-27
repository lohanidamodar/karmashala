part of '../data_change.dart';

// The server's own SSH connections (slice 3a): where each stands, and what it
// is waiting on a person for. No secret is ever in one of these.

DataChange? _sshChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'sshConnectionChanged' => SshConnectionChanged(
        json['hostId']! as String,
        sshConnectionStateFromJson(_row(json)),
      ),
      'sshPromptOpened' => SshPromptOpened(
        promptId: json['promptId']! as String,
        hostId: json['hostId']! as String,
        hostName: json['hostName']! as String,
        address: json['address']! as String,
        kind:
            SshPromptKind.fromName(json['kind']) ??
            (throw const FormatException('not a prompt kind')),
        presentation: json['presentation'] is Map
            ? hostKeyPresentationFromJson(
                (json['presentation']! as Map).cast<String, Object?>(),
              )
            : null,
      ),
      'sshPromptClosed' => SshPromptClosed(json['promptId']! as String),
      _ => null,
    };

/// What the server's SSH connections are doing, told to every desktop
/// client.
sealed class SshChange extends DataChange {
  const SshChange();
}

/// The server's connection to host [hostId] moved to [state].
final class SshConnectionChanged extends SshChange {
  const SshConnectionChanged(this.hostId, this.state);

  final String hostId;
  final SshConnectionState state;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sshConnectionChanged',
    'hostId': hostId,
    'row': sshConnectionStateToJson(state),
  };
}

/// A connection the server is making waits on a person: to trust a host key
/// ([presentation], fingerprints only) or to type a password or passphrase.
/// Answered with `ssh.answerPrompt` from any desktop client.
final class SshPromptOpened extends SshChange {
  const SshPromptOpened({
    required this.promptId,
    required this.hostId,
    required this.hostName,
    required this.address,
    required this.kind,
    this.presentation,
  });

  final String promptId;
  final String hostId;
  final String hostName;

  /// `user@host:port`.
  final String address;
  final SshPromptKind kind;
  final HostKeyPresentation? presentation;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sshPromptOpened',
    'promptId': promptId,
    'hostId': hostId,
    'hostName': hostName,
    'address': address,
    'kind': kind.name,
    if (presentation != null)
      'presentation': hostKeyPresentationToJson(presentation!),
  };
}

/// Prompt [promptId] is over: answered (here or by another client), or the
/// connection that asked gave up. A client closes its dialog.
final class SshPromptClosed extends SshChange {
  const SshPromptClosed(this.promptId);

  final String promptId;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sshPromptClosed',
    'promptId': promptId,
  };
}
