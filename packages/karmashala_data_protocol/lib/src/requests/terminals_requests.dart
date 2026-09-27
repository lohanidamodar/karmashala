part of '../data_request.dart';

// Terminals the server runs (slice 5a). Every local and WSL pane is a PTY in
// the server's registry: a client asks for one here, then attaches to the
// session by id on the host socket (`attach` with a screen grid) — the same
// way a pane attaches to a hosted run. Each request touches the registry or
// spawns, so each is answered when done (`DataSession.handleLater`).
//
// Refusals: `invalid` for a profile the server does not offer or a launch it
// cannot read, `notFound` for an environment it cannot run a terminal in
// (unknown, an SSH box — slice 5d —, WSL off Windows) or a session it does not
// hold, `failed` for a process that would not start.

DataRequest<Object?>? _terminalsRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  TerminalsProfiles.name => const TerminalsProfiles(),
  TerminalOpen.name => TerminalOpen(
    paneId: args.string('paneId'),
    environmentId: args.optionalString('environmentId'),
    workingDirectory: args.optionalString('workingDirectory'),
    profileId: args.optionalString('profileId'),
    agentLaunch: args.values['agentLaunch'] == null
        ? null
        : args.value('agentLaunch', agentLaunchFromWire),
    columns: args.integer('columns'),
    rows: args.integer('rows'),
    shellIntegration: args.boolean('shellIntegration', orElse: false),
  ),
  TerminalsList.name => const TerminalsList(),
  TerminalClose.name => TerminalClose(args.string('sessionId')),
  TerminalRename.name => TerminalRename(
    args.string('sessionId'),
    args.string('title'),
  ),
  _ => null,
};

/// Terminals the server runs; answered when done.
sealed class TerminalWorkRequest<R> extends DataRequest<R> {
  const TerminalWorkRequest();
}

/// The shells the server's machine can open, spelled for its own OS: its
/// POSIX shells, or PowerShell, Command Prompt and each WSL distribution on a
/// Windows server. SSH profiles are the client's until slice 5d.
final class TerminalsProfiles
    extends TerminalWorkRequest<List<TerminalProfile>> {
  const TerminalsProfiles();

  static const String name = 'terminals.profiles';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<TerminalProfile> result) => [
    for (final profile in result) terminalProfileToJson(profile),
  ];

  @override
  List<TerminalProfile> resultFromJson(Object? json) => _decode(
    kind,
    () => [
      for (final item in _objects(json, kind)) terminalProfileFromJson(item),
    ],
  );
}

/// Starts a terminal for pane [paneId] — the shell of [profileId] (the
/// server's default when null), or [agentLaunch]'s agent — in
/// [workingDirectory], spelled the way [environmentId]'s environment spells
/// it, at [columns]×[rows]. A session already running under the pane's id is
/// answered as it is (`adopted`), never started twice; an ended record under
/// it is replaced. The client then attaches to `sessionId`.
final class TerminalOpen extends TerminalWorkRequest<TerminalOpened> {
  const TerminalOpen({
    required this.paneId,
    required this.columns,
    required this.rows,
    this.environmentId,
    this.workingDirectory,
    this.profileId,
    this.agentLaunch,
    this.shellIntegration = false,
  });

  static const String name = 'terminals.open';

  final String paneId;

  /// The environment [workingDirectory] belongs to; null is the server's own
  /// machine, or — for a WSL profile — that distribution.
  final String? environmentId;
  final String? workingDirectory;
  final String? profileId;
  final AgentPaneLaunch? agentLaunch;
  final int columns;
  final int rows;

  /// The client's setting: whether a shell that can carry OSC 133 does.
  final bool shellIntegration;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'paneId': paneId,
    'environmentId': ?environmentId,
    'workingDirectory': ?workingDirectory,
    'profileId': ?profileId,
    if (agentLaunch != null) 'agentLaunch': agentLaunchToWire(agentLaunch!),
    'columns': columns,
    'rows': rows,
    'shellIntegration': shellIntegration,
  };

  @override
  Object? resultToJson(TerminalOpened result) => result.toJson();

  @override
  TerminalOpened resultFromJson(Object? json) =>
      _decode(kind, () => TerminalOpened.fromJson(_object(json, kind)));
}

/// Every terminal the server holds — running, and ended ones whose record it
/// still keeps — as its screen reads them.
final class TerminalsList extends TerminalWorkRequest<List<TerminalRecord>> {
  const TerminalsList();

  static const String name = 'terminals.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<TerminalRecord> result) => [
    for (final record in result) record.toJson(),
  ];

  @override
  List<TerminalRecord> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) TerminalRecord.fromJson(item)],
  );
}

/// Ends terminal [sessionId] for good — the process asked to exit, then
/// killed — and forgets its record. A disconnect never does this.
final class TerminalClose extends TerminalWorkRequest<DataAck> {
  const TerminalClose(this.sessionId);

  static const String name = 'terminals.close';

  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Names terminal [sessionId] [title], over whatever the program set; an
/// empty title gives the naming back to the program.
final class TerminalRename extends TerminalWorkRequest<DataAck> {
  const TerminalRename(this.sessionId, this.title);

  static const String name = 'terminals.rename';

  final String sessionId;
  final String title;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'title': title,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
