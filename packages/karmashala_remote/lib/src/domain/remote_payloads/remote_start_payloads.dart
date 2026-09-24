part of '../remote_payloads.dart';

/// What `host.status` carries on connect, and again whenever the host's relays
/// change under a live link.
class RemoteHostStatus {
  const RemoteHostStatus({
    required this.versions,
    required this.hostName,
    this.relays = const [],
    this.lanHint,
    this.capabilities,
    this.streamAcks = false,
  });

  final VersionRange versions;
  final String hostName;

  /// Whether this host reads `stream.ack`. A phone acks only a host that says
  /// so, or an older one would answer every ack with `unknown_type`.
  final bool streamAcks;

  /// What this device is granted **now**, so permissions edited on the desktop
  /// reach the phone without re-pairing. Null from a host that does not send
  /// it, and the phone then keeps what it was paired with.
  final CapabilitySet? capabilities;

  /// Every relay this host is serving right now; the phone replaces its saved
  /// candidate set with this. Additive — an older host sends none and the phone
  /// keeps what it has.
  final List<Uri> relays;

  /// `host:port` of the host's direct LAN listener. A **discovery hint** — the
  /// sealed hello remains the only proof of who answered.
  final String? lanHint;

  Map<String, Object?> toJson() => {
    'versions': versions.toJson(),
    'host': hostName,
    if (relays.isNotEmpty) 'relays': [for (final url in relays) url.toString()],
    if (lanHint != null) 'lan': lanHint,
    if (capabilities != null) 'caps': capabilities!.bits,
    if (streamAcks) 'acks': true,
  };

  static RemoteHostStatus fromJson(Map<String, Object?> json) {
    final versions = json['versions'];
    if (versions is! Map<String, Object?>) {
      throw const ProtocolException('bad host status');
    }
    final lan = json['lan'];
    final caps = json['caps'];
    return RemoteHostStatus(
      versions: VersionRange.fromJson(versions),
      hostName: json['host'] is String ? json['host']! as String : '',
      relays: relayUrisFrom(json['relays']),
      lanHint: lan is String && lan.isNotEmpty ? lan : null,
      capabilities: caps is int && caps >= 0 ? CapabilitySet(caps) : null,
      streamAcks: json['acks'] == true,
    );
  }
}

/// One permission mode an agent can be put into, worded by the host — so a
/// phone one release behind can offer a mode it has never heard of and still
/// say truthfully what it does to that agent.
class RemotePermissionOption {
  const RemotePermissionOption({
    required this.mode,
    required this.label,
    required this.summary,
    required this.selectable,
    this.dangerous = false,
  });

  /// `PermissionMode.name` on the desktop; opaque here.
  final String mode;

  /// The desktop's own name for it ("Ask every time").
  final String label;

  /// What picking it actually does to this agent, in the agent's own terms —
  /// `AgentPermissionOption.summary`, never re-worded on the phone.
  final String summary;

  /// Whether the agent can be put into it at all. A mode it cannot express is
  /// **sent and not selectable** rather than hidden.
  final bool selectable;

  /// True for the mode the desktop marks dangerous, so the phone can make the
  /// deliberate choice look deliberate.
  final bool dangerous;

  Map<String, Object?> toJson() => {
    'mode': mode,
    'label': label,
    'summary': summary,
    'selectable': selectable,
    if (dangerous) 'dangerous': dangerous,
  };

  static RemotePermissionOption fromJson(Map<String, Object?> json) {
    final mode = json['mode'];
    if (mode is! String) throw const ProtocolException('bad permission option');
    return RemotePermissionOption(
      mode: mode,
      label: json['label'] is String ? json['label']! as String : mode,
      summary: json['summary'] is String ? json['summary']! as String : '',
      selectable: json['selectable'] == true,
      dangerous: json['dangerous'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemotePermissionOption &&
      other.mode == mode &&
      other.label == label &&
      other.summary == summary &&
      other.selectable == selectable &&
      other.dangerous == dangerous;

  @override
  int get hashCode => Object.hash(mode, label, summary, selectable, dangerous);
}

/// One agent installed where a checkout lives — an installation the phone may
/// name in `session.start`, never an agent that merely exists in the registry.
class RemoteAgentOption {
  const RemoteAgentOption({
    required this.installationId,
    required this.agentId,
    required this.name,
    required this.defaultMode,
    this.version,
    this.acceptsOpeningMessage = false,
    this.permissionModes = const [],
  });

  /// `AgentInstallation.id` — what `session.start` names.
  final String installationId;

  /// `AgentDescriptor.id`; opaque here, useful for an icon.
  final String agentId;

  /// The desktop's display name for the agent ("Claude Code").
  final String name;

  /// The mode the desktop's own settings would start this agent under. The
  /// phone preselects it and never invents one.
  final String defaultMode;

  final String? version;

  /// Whether this agent's command line takes an opening message. False means a
  /// start carrying one is refused (`SessionLaunchRefused`).
  final bool acceptsOpeningMessage;

  final List<RemotePermissionOption> permissionModes;

  Map<String, Object?> toJson() => {
    'installationId': installationId,
    'agentId': agentId,
    'name': name,
    'defaultMode': defaultMode,
    if (version != null) 'version': version,
    if (acceptsOpeningMessage) 'acceptsOpeningMessage': acceptsOpeningMessage,
    'permissionModes': [for (final m in permissionModes) m.toJson()],
  };

  static RemoteAgentOption fromJson(Map<String, Object?> json) {
    final installationId = json['installationId'];
    final agentId = json['agentId'];
    if (installationId is! String || agentId is! String) {
      throw const ProtocolException('bad agent option');
    }
    final modes = json['permissionModes'];
    return RemoteAgentOption(
      installationId: installationId,
      agentId: agentId,
      name: json['name'] is String ? json['name']! as String : agentId,
      defaultMode: json['defaultMode'] is String
          ? json['defaultMode']! as String
          : '',
      version: json['version'] is String ? json['version']! as String : null,
      acceptsOpeningMessage: json['acceptsOpeningMessage'] == true,
      permissionModes: [
        if (modes is List)
          for (final entry in modes)
            if (entry is Map<String, Object?>)
              RemotePermissionOption.fromJson(entry),
      ],
    );
  }
}

/// One checkout of a project, and what can be started in it.
class RemoteCheckoutOption {
  const RemoteCheckoutOption({
    required this.repositoryId,
    required this.name,
    this.path,
    this.subPath,
    this.branch,
    this.environmentName,
    this.folderMissing = false,
    this.agents = const [],
  });

  /// `Repository.id` — what `session.start` names.
  final String repositoryId;
  final String name;

  /// The checkout as the desktop spells it. A subtitle, never a path to act
  /// on: the phone cannot reach this filesystem.
  final String? path;

  /// Written relative to the project root, when it says anything the name
  /// does not.
  final String? subPath;

  /// The branch checked out here, when already measured. Null means "not
  /// measured", never "no branch": this starts no git.
  final String? branch;

  /// The execution environment this checkout lives in, as the desktop names it.
  /// One repository checked out natively and inside WSL gives a project two
  /// checkouts of one name; null when there is nothing worth saying.
  final String? environmentName;

  /// The desktop cannot see this folder on disk. False also means "could not
  /// tell" — the same fail-safe direction the session rows take.
  final bool folderMissing;

  /// Every agent installed in the environment this checkout lives in. Empty
  /// is a real answer: nothing can be started here.
  final List<RemoteAgentOption> agents;

  Map<String, Object?> toJson() => {
    'repositoryId': repositoryId,
    'name': name,
    if (path != null) 'path': path,
    if (subPath != null) 'subPath': subPath,
    if (branch != null) 'branch': branch,
    if (environmentName != null) 'environmentName': environmentName,
    if (folderMissing) 'folderMissing': folderMissing,
    'agents': [for (final agent in agents) agent.toJson()],
  };

  static RemoteCheckoutOption fromJson(Map<String, Object?> json) {
    final repositoryId = json['repositoryId'];
    if (repositoryId is! String) {
      throw const ProtocolException('bad checkout option');
    }
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    final agents = json['agents'];
    return RemoteCheckoutOption(
      repositoryId: repositoryId,
      name: str(json['name']) ?? repositoryId,
      path: str(json['path']),
      subPath: str(json['subPath']),
      branch: str(json['branch']),
      environmentName: str(json['environmentName']),
      folderMissing: json['folderMissing'] == true,
      agents: [
        if (agents is List)
          for (final entry in agents)
            if (entry is Map<String, Object?>)
              RemoteAgentOption.fromJson(entry),
      ],
    );
  }
}

/// One project of the desktop's workspace. Reported, never guessed — a checkout
/// the desktop holds no row for is absent rather than inferred from a session.
class RemoteWorkspaceProject {
  const RemoteWorkspaceProject({
    required this.projectId,
    required this.name,
    this.path,
    this.environmentName,
    this.environmentBadge,
    this.environmentId,
    this.environmentKind,
    this.checkouts = const [],
  });

  final String projectId;
  final String name;
  final String? path;

  /// The environment the project's root lives in. Two projects of one name, one
  /// per environment, are otherwise told apart only by their paths.
  final String? environmentName;

  /// The badge on a non-local project card ("WSL · Ubuntu"); null for local.
  final String? environmentBadge;

  /// The desktop's own id for the machine, and what kind it is. Both null from
  /// a desktop older than this field; the phone groups by name then.
  final String? environmentId;
  final String? environmentKind;

  final List<RemoteCheckoutOption> checkouts;

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'name': name,
    if (path != null) 'path': path,
    if (environmentName != null) 'environmentName': environmentName,
    if (environmentBadge != null) 'environmentBadge': environmentBadge,
    if (environmentId != null) 'environmentId': environmentId,
    if (environmentKind != null) 'environmentKind': environmentKind,
    'checkouts': [for (final checkout in checkouts) checkout.toJson()],
  };

  static RemoteWorkspaceProject fromJson(Map<String, Object?> json) {
    final projectId = json['projectId'];
    if (projectId is! String) {
      throw const ProtocolException('bad workspace project');
    }
    final checkouts = json['checkouts'];
    return RemoteWorkspaceProject(
      projectId: projectId,
      name: json['name'] is String ? json['name']! as String : projectId,
      path: json['path'] is String ? json['path']! as String : null,
      environmentName: json['environmentName'] is String
          ? json['environmentName']! as String
          : null,
      environmentBadge: json['environmentBadge'] is String
          ? json['environmentBadge']! as String
          : null,
      environmentId: json['environmentId'] is String
          ? json['environmentId']! as String
          : null,
      environmentKind: json['environmentKind'] is String
          ? json['environmentKind']! as String
          : null,
      checkouts: [
        if (checkouts is List)
          for (final entry in checkouts)
            if (entry is Map<String, Object?>)
              RemoteCheckoutOption.fromJson(entry),
      ],
    );
  }
}

/// A `session.start` request, after the host api has checked its shape.
class RemoteSessionStartRequest {
  const RemoteSessionStartRequest({
    required this.repositoryId,
    required this.installationId,
    required this.permissionMode,
    this.title,
    this.message,
  });

  final String repositoryId;
  final String installationId;

  /// The mode the **user** picked. Not optional: starting an agent in bypass is
  /// not a choice anything but a person may make.
  final String permissionMode;

  final String? title;

  /// The opening message, when there is one. Refused for an agent whose
  /// command line cannot carry it — by the launcher, not by anything here.
  final String? message;
}

/// What `session.start` answers with.
class RemoteSessionStarted {
  const RemoteSessionStarted({
    required this.sessionId,
    required this.title,
    this.permissionMode,
    this.replayed = false,
  });

  final String sessionId;
  final String title;

  /// The mode the session was actually stamped with, or null when the row
  /// records none.
  final String? permissionMode;

  /// True when this answer was remembered rather than acted on: the same
  /// idempotency key arrived twice.
  final bool replayed;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'title': title,
    if (permissionMode != null) 'permissionMode': permissionMode,
    if (replayed) 'replayed': replayed,
  };

  static RemoteSessionStarted fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    if (sessionId is! String) {
      throw const ProtocolException('bad session start result');
    }
    return RemoteSessionStarted(
      sessionId: sessionId,
      title: json['title'] is String ? json['title']! as String : '',
      permissionMode: json['permissionMode'] is String
          ? json['permissionMode']! as String
          : null,
      replayed: json['replayed'] == true,
    );
  }
}
