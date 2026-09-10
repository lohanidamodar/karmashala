import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';

/// Everything one launching session needs to reach the app's own MCP endpoint,
/// already in the **agent's** terms: nothing downstream translates again.
class SessionMcpAccess {
  const SessionMcpAccess({this.url, this.configPath})
    : assert(
        url != null || configPath != null,
        'an access with neither an address nor a file says nothing',
      );

  /// The endpoint URL with this session's credential in its last path segment,
  /// or `null` where no address of ours is dialable — WSL gets [configPath].
  final String? url;

  /// The config file describing the server, or null when the agent's convention
  /// takes the URL directly and never opens a file.
  final String? configPath;
}

/// What a launch asks about the MCP endpoint, implemented by
/// `LauncherControlServer` — the only thing that knows what survived hardening.
abstract class SessionMcp {
  /// Where [sessionId] reaches the endpoint from [environment], or `null` when
  /// there is nothing truthful to hand it — a normal answer, not a failure.
  SessionMcpAccess? accessFor({
    required String sessionId,
    required ExecutionEnvironment environment,
    required bool withConfigFile,
  });
}

/// [windowsPath] as the agent running in [kind] would name it, or `null` when
/// it has no name for it: a path an agent cannot open is worse than no path.
String? agentConfigPathFor(String windowsPath, EnvironmentKind kind) {
  switch (kind) {
    case EnvironmentKind.windowsNative:
    case EnvironmentKind.localPosix:
      // The agent shares this filesystem, so the path it was handed is already
      // the name it knows the file by.
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

/// The per-session MCP config files, in an owner-only directory emptied as it is
/// prepared: one file per session, because its URL is what names the caller.
class SessionMcpConfigs {
  const SessionMcpConfigs(this.directory);

  final Directory directory;

  /// Creates [directory] empty and locked to this user, or `null` when the ACL
  /// did not apply — with a credential inside, that is the boundary missing.
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
  /// path, or `null`. Synchronous because the pane launch is.
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

  /// Session ids are UUIDs, so this changes nothing in practice — but a file
  /// name built from a database row is not the place to find that out.
  static String _fileNameFor(String sessionId) =>
      'session-${sessionId.replaceAll(RegExp('[^A-Za-z0-9-]'), '_')}.json';
}

/// The live MCP wiring, or `null` when nothing is served: how a launch holding
/// only a `Ref` finds a server the lifecycle owner built.
class SessionMcpController extends Notifier<SessionMcp?> {
  @override
  SessionMcp? build() => null;

  void adopt(SessionMcp? value) => state = value;
}

final sessionMcpProvider = NotifierProvider<SessionMcpController, SessionMcp?>(
  SessionMcpController.new,
);
