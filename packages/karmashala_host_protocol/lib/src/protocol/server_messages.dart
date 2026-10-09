part of 'messages.dart';

// Administering a server from its own machine (protocol 8): the paired
// devices, revoking one, the agent CLIs it found, and its config (protocol
// 10) — what `karmashala_host devices`, `revoke` and `agents`, and the
// desktop's Remote access settings, ask over the owner-only socket. One request/answer pair with a method name, because each is a small
// JSON question and none streams; the methods are [ServerMethod]'s.

/// The methods a [ServerCallMessage] may name.
abstract final class ServerMethod {
  /// `{}` → `{name, dataDirectory, companion: {serving, port?, bind,
  /// relay?}}` — what `pair` needs to build an invite. A relay's token is
  /// never in it.
  static const String serverInfo = 'server.info';

  /// `{}` → `{file, settings, flags}`: `server.json` as written (a relay
  /// token only as `companion.relayTokenSet`), every field as decided, and
  /// the fields a `serve` flag holds for the life of the process.
  static const String configGet = 'server.config.get';

  /// `{patch}` → as [configGet], after laying `patch` — shaped like
  /// `server.json`, a null clearing a field — over the file, writing it
  /// owner-only and applying it: how phones are served and where the
  /// listener binds at once, the name and the MCP port at the next start.
  static const String configSet = 'server.config.set';

  /// `{}` → `{devices: [PairedDeviceSummary…]}`.
  static const String devicesList = 'devices.list';

  /// `{deviceId}` → `{device: PairedDeviceSummary}`, now revoked.
  static const String devicesRevoke = 'devices.revoke';

  /// `{}` → `{agents: [installation…]}`, as recorded.
  static const String agentsList = 'agents.list';

  /// `{}` → `{agents: [installation…], summary}`, after probing again.
  static const String agentsRefresh = 'agents.refresh';

  /// `{}` → `{databaseBytes, tables?: [{name, bytes}], toolImages: {files,
  /// bytes, maxAgeDays, maxMegabytes}}`: what the server keeps on disk.
  /// `tables` is absent when its SQLite cannot say.
  static const String storage = 'server.storage';

  /// `{}` → `{removed}`: every cached tool image deleted.
  static const String toolImagesClear = 'server.toolImages.clear';

  /// `{}` → `{removed}`: the tool-image cache swept by its limits as they are
  /// set now.
  static const String toolImagesSweep = 'server.toolImages.sweep';

  /// `{folder}` → `{path, manifest}`: a backup archive written into
  /// `folder`, a path on the server's machine.
  static const String backupCreate = 'server.backup.create';

  /// `{archive}` → `{manifest, refusal?}`: what a backup holds, and why this
  /// server would refuse to restore it.
  static const String backupInspect = 'server.backup.inspect';

  /// `{archive}` → `{staged, schemaFrom, schemaTo}`: the backup unpacked,
  /// checked and migrated into a fresh folder, switched to at the next start.
  static const String backupRestore = 'server.backup.restore';

  /// `{}` → `{frequency, keep, folder?, last?, lastRestore?,
  /// pendingRestore}`.
  static const String backupScheduleGet = 'server.backup.schedule.get';

  /// `{frequency, keep, folder?}` → as [backupScheduleGet].
  static const String backupScheduleSet = 'server.backup.schedule.set';
}

/// What a backup never holds, as Settings → Data and the manifest name it.
const List<String> kBackupExclusions = [
  'The vaults in secrets/: environment variables, store credentials, the '
      'GitHub token, agent secrets and webhook secrets',
  'server.json, which holds the relay token',
  'The MCP bridge handshake and per-session MCP configs',
  'Phone pairing keys and push tokens',
  'SSH keys: only the paths to them are recorded',
  'Any file named .env*, key.properties, or a keystore or private key',
  'Logs and the tool-image cache',
];

/// What a backup refers to but cannot carry, as Settings → Data names it.
const List<String> kBackupNotCarried = [
  'Checkpoint contents: they are git objects in each repository, so the '
      'backup records their refs and the repositories must still hold them',
  "Agent transcripts: each agent CLI keeps its own, outside Karmashala's data",
];

/// client → host: one administrative question, answered with a
/// [ServerResultMessage] under [requestId].
class ServerCallMessage extends HostMessage {
  const ServerCallMessage({
    required this.requestId,
    required this.method,
    this.arguments = const {},
  });

  final int requestId;
  final String method;
  final Map<String, Object?> arguments;

  @override
  Frame toFrame() => Frame(
    MessageType.serverCall,
    0,
    (WireWriter()..str(
          jsonEncode({
            'requestId': requestId,
            'method': method,
            'arguments': arguments,
          }),
        ))
        .take(),
  );

  static ServerCallMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'server call',
    );
    final arguments = map['arguments'];
    return ServerCallMessage(
      requestId: _required<int>(map, 'requestId'),
      method: _required<String>(map, 'method'),
      arguments: arguments == null
          ? const {}
          : _object(arguments, 'server call arguments'),
    );
  }
}

/// host → client: how the [ServerCallMessage] under [requestId] ended — its
/// [result], or the [message] it was refused with.
class ServerResultMessage extends HostMessage {
  const ServerResultMessage.success(
    this.requestId,
    Map<String, Object?> this.result,
  ) : message = null;

  const ServerResultMessage.failure(this.requestId, String this.message)
    : result = null;

  final int requestId;
  final Map<String, Object?>? result;
  final String? message;

  bool get ok => message == null;

  @override
  Frame toFrame() => Frame(
    MessageType.serverResult,
    0,
    (WireWriter()..str(
          jsonEncode({
            'requestId': requestId,
            'result': ?result,
            'message': ?message,
          }),
        ))
        .take(),
  );

  static ServerResultMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'server result',
    );
    final requestId = _required<int>(map, 'requestId');
    final message = _optional<String>(map, 'message');
    if (message != null) return ServerResultMessage.failure(requestId, message);
    final result = map['result'];
    return ServerResultMessage.success(
      requestId,
      result == null ? const {} : _object(result, 'server result body'),
    );
  }
}
