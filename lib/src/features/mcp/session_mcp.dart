import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/process/path_translator.dart';
import '../environments/domain/environment_kind.dart';
import '../environments/domain/execution_environment.dart';

/// Everything one launching session needs to reach the app's own MCP endpoint.
///
/// Both fields are already in the **agent's** terms: [url] is an address that
/// agent's environment can dial, and [configPath] is spelled in that agent's
/// path namespace. Nothing downstream translates either again.
class SessionMcpAccess {
  const SessionMcpAccess({this.url, this.configPath})
    : assert(
        url != null || configPath != null,
        'an access with neither an address nor a file says nothing',
      );

  /// The endpoint URL, carrying this session's own credential in its last path
  /// segment — or `null` when this environment has **no HTTP address of ours it
  /// can dial**. See `LauncherControlServer.mcpUrlFor`.
  ///
  /// Null is not the same as "no tools". An agent inside WSL is pointed at the
  /// stdio bridge through [configPath] instead, which reaches the app without a
  /// network; what it has no use for is a URL. An agent whose convention is
  /// *only* a URL (Codex's `-c mcp_servers.karmashala.url=…`) does lose its
  /// tools there, and that is reported rather than papered over.
  final String? url;

  /// The config file describing the server, or null when the agent's convention
  /// takes the URL directly and never opens a file.
  final String? configPath;
}

/// What a launch asks about the MCP endpoint. Implemented by
/// `LauncherControlServer`, which is the only thing that knows the port, the
/// tokens and whether any of it survived hardening.
abstract class SessionMcp {
  /// Where [sessionId] can reach the endpoint from [environment], writing it a
  /// config file when [withConfigFile], or `null` when there is nothing
  /// truthful to hand it.
  ///
  /// `null` is a normal answer, not a failure: an SSH session, a host with no
  /// WSL switch, an endpoint that failed hardening, a config directory whose
  /// ACL did not apply. In every one of those the session launches exactly as
  /// it did before any of this existed.
  SessionMcpAccess? accessFor({
    required String sessionId,
    required ExecutionEnvironment environment,
    required bool withConfigFile,
  });
}

/// [windowsPath] as the agent running in [kind] would name it, or `null` when
/// that agent has no name for it.
///
/// Translation is explicit everywhere in this codebase — there is no implicit
/// conversion, and `EditorActions.windowsPathFor` is the same call made in the
/// other direction. The two `null`s are different facts worth keeping apart:
/// an SSH agent is on another machine, so the file is not on its disk at all;
/// a UNC application-support directory (a roaming profile can produce one) has
/// no `/mnt/` form, and a path an agent cannot open is worse than no path.
String? agentConfigPathFor(String windowsPath, EnvironmentKind kind) {
  switch (kind) {
    case EnvironmentKind.windowsNative:
    case EnvironmentKind.localPosix:
      // The agent shares this filesystem, so the path it was handed is already
      // the name it knows the file by — on a POSIX host there is no drive
      // letter to translate in the first place.
      return windowsPath;
    case EnvironmentKind.wsl:
      try {
        return const PathTranslator().windowsDriveToWslMount(windowsPath);
      } on PathTranslationException {
        return null;
      }
    case EnvironmentKind.ssh:
      return null;
  }
}

/// The per-session MCP config files, and the owner-only directory they live in.
///
/// **One file per session**, because the URL inside it is what tells the server
/// which session is calling. Two sessions sharing a config would be two agents
/// speaking with one voice, and the spawn-depth cap and verification
/// attribution both read that voice.
///
/// The directory is emptied when it is prepared rather than when the app quits.
/// A config from a previous run names a port and a token that died with that
/// process, and the port number will be reused by something else eventually; a
/// crash is exactly the case where the tidy-up on the way out did not happen,
/// so the guarantee has to be made on the way in.
class SessionMcpConfigs {
  const SessionMcpConfigs(this.directory);

  final Directory directory;

  /// Creates [directory] empty and locks it to this user, or returns `null`
  /// when it could not be locked.
  ///
  /// The file holds a credential for the app's whole tool surface, so an ACL
  /// that did not apply is the boundary missing rather than weakened — the same
  /// rule the handshake file follows, and the same answer: nothing is written.
  /// The grant is inheritable, so each config written later is born behind it
  /// instead of racing an `icacls` of its own.
  static Future<SessionMcpConfigs?> prepare(
    Directory directory,
    Future<bool> Function(Directory) restrict,
  ) async {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      await directory.create(recursive: true);
      if (!await restrict(directory)) return null;
      return SessionMcpConfigs(directory);
    } on Object {
      return null;
    }
  }

  /// Writes [sessionId]'s config around [entry] and returns its **Windows**
  /// path, or `null` if it could not be written.
  ///
  /// [entry] is the `mcpServers.karmashala` value — `LauncherMcp.httpServerEntry`
  /// for an agent that shares a loopback with this process, or
  /// `LauncherMcp.commandServerEntry` for one inside a WSL distribution, which
  /// has no address of ours it can dial. The caller picks; this only writes,
  /// because which transport an environment gets is a property of the
  /// environment and not of the file format.
  ///
  /// Synchronous because the pane launch is: `SessionLauncher._startInPane`
  /// returns a result rather than a future, and a launch that has to await a
  /// 200-byte write to open a terminal tab is a worse trade than this line.
  String? write({
    required String sessionId,
    required Map<String, Object?> entry,
  }) {
    try {
      final file = File(p.join(directory.path, _fileNameFor(sessionId)));
      file.writeAsStringSync(
        jsonEncode({
          'mcpServers': {'karmashala': entry},
        }),
        flush: true,
      );
      return file.path;
    } on Object {
      return null;
    }
  }

  /// Removes the whole directory, configs and all.
  void dispose() {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } on Object {
      // Nothing to do about it, and it is emptied again on the next start.
    }
  }

  /// Session ids are UUIDs, so this changes nothing in practice — but the id
  /// reaches here from a database row, and a file name built from one is not
  /// the place to find out that assumption was wrong.
  static String _fileNameFor(String sessionId) =>
      'session-${sessionId.replaceAll(RegExp('[^A-Za-z0-9-]'), '_')}.json';
}

/// The live MCP wiring, or `null` when nothing is served.
///
/// `LauncherControlServer` is built by the lifecycle owner rather than by a
/// provider, so this is how a launch — which has only a `Ref` — finds it. It is
/// set on start and cleared on stop, which is also what makes "the server is
/// not up" answer itself: the launcher reads `null` and passes no MCP argument.
class SessionMcpController extends Notifier<SessionMcp?> {
  @override
  SessionMcp? build() => null;

  void adopt(SessionMcp? value) => state = value;
}

final sessionMcpProvider = NotifierProvider<SessionMcpController, SessionMcp?>(
  SessionMcpController.new,
);
