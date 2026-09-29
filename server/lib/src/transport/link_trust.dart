import 'package:karmashala_remote/remote.dart' show Capability, CapabilitySet;

/// What one connection may do (slice 5e). The local socket's peer is this OS
/// user, so it may do everything; a client on another machine, over the
/// companion's sealed channel, gets only what its pairing grants.
class LinkTrust {
  const LinkTrust._({
    required this.remote,
    required this.admin,
    required this.sshPrompts,
    required this.transcripts,
  }) : phone = false,
       grants = null,
       label = null,
       deviceId = null;

  /// This machine's own user, over the owner-only socket.
  static const local = LinkTrust._(
    remote: false,
    admin: true,
    sshPrompts: true,
    transcripts: true,
  );

  /// A paired client elsewhere: [admin] for `serverCall` and device writes,
  /// [sshPrompts] to be asked (and answer) the server's SSH questions,
  /// [transcripts] to read sessions' transcripts (`sessions.transcript`).
  /// A [phone] never holds [admin] or [sshPrompts], whatever it was granted:
  /// `desktop_client` is the way to those.
  const LinkTrust.remote({
    required bool admin,
    required bool sshPrompts,
    required this.transcripts,
    this.phone = false,
    this.grants,
    this.label,
    this.deviceId,
  }) : remote = true,
       admin = admin && !phone,
       sshPrompts = sshPrompts && !phone;

  final bool remote;
  final bool admin;
  final bool sshPrompts;
  final bool transcripts;

  /// The app on a phone (`phone_client`): the data API also refuses it the
  /// server's secrets, SSH hosts and agent-account deletes.
  final bool phone;

  /// A [phone]'s pairing grants, each refused in words when left out (Stage 3
  /// step 3). Ignored for a desktop client, which may do all a desktop does.
  final CapabilitySet? grants;

  /// Whether this link holds [capability]: always, unless it is a phone
  /// whose pairing leaves it out.
  bool may(Capability capability) =>
      !phone || (grants?.has(capability) ?? true);

  /// The paired device's name, for a client that names itself nothing.
  final String? label;

  /// The paired device's id: what outlives a reconnect, so a resend on a new
  /// link is still known as that device's (`sessions.send`). Null locally.
  final String? deviceId;

  @override
  String toString() => remote
      ? 'remote(${label ?? '?'}${phone ? ', phone' : ''}'
            '${admin ? ', admin' : ''}'
            '${sshPrompts ? ', ssh prompts' : ''}'
            '${transcripts ? ', transcripts' : ''})'
      : 'local';
}
