/// What one connection may do (slice 5e). The local socket's peer is this OS
/// user, so it may do everything; a client on another machine, over the
/// companion's sealed channel, gets only what its pairing grants.
class LinkTrust {
  const LinkTrust._({
    required this.remote,
    required this.admin,
    required this.sshPrompts,
    required this.transcripts,
  }) : label = null;

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
  const LinkTrust.remote({
    required this.admin,
    required this.sshPrompts,
    required this.transcripts,
    this.label,
  }) : remote = true;

  final bool remote;
  final bool admin;
  final bool sshPrompts;
  final bool transcripts;

  /// The paired device's name, for a client that names itself nothing.
  final String? label;

  @override
  String toString() => remote
      ? 'remote(${label ?? '?'}${admin ? ', admin' : ''}'
            '${sshPrompts ? ', ssh prompts' : ''}'
            '${transcripts ? ', transcripts' : ''})'
      : 'local';
}
