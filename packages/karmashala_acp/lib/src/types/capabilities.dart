import 'package:meta/meta.dart';

import '../json.dart';

/// Who is on each end of the wire: `clientInfo` and `agentInfo` share a shape.
@immutable
final class ImplementationInfo {
  const ImplementationInfo({
    required this.name,
    required this.version,
    this.title,
  });

  factory ImplementationInfo.fromJson(JsonMap json) => ImplementationInfo(
    name: json.string('name') ?? '',
    version: json.string('version') ?? '',
    title: json.string('title'),
  );

  final String name;
  final String version;
  final String? title;

  JsonMap toJson() =>
      withoutNulls({'name': name, 'title': title, 'version': version});
}

typedef ClientInfo = ImplementationInfo;
typedef AgentInfo = ImplementationInfo;

@immutable
final class FsCapabilities {
  const FsCapabilities({this.readTextFile = false, this.writeTextFile = false});

  factory FsCapabilities.fromJson(JsonMap json) => FsCapabilities(
    readTextFile: json.boolean('readTextFile') ?? false,
    writeTextFile: json.boolean('writeTextFile') ?? false,
  );

  final bool readTextFile;
  final bool writeTextFile;

  JsonMap toJson() => {
    'readTextFile': readTextFile,
    'writeTextFile': writeTextFile,
  };
}

/// What this client offers the agent. Terminals (`terminal/*`) are never
/// advertised in this cut, so `terminal` is always false on the wire;
/// `auth.terminal` says whether the client can run the agent's program in an
/// interactive terminal for a `terminal` auth method.
@immutable
final class ClientCapabilities {
  const ClientCapabilities({
    this.fs = const FsCapabilities(readTextFile: true, writeTextFile: true),
    this.authTerminal = true,
  });

  final FsCapabilities fs;

  /// Whether the agent may advertise `terminal` auth methods.
  final bool authTerminal;

  bool get terminal => false;

  JsonMap toJson() => {
    'fs': fs.toJson(),
    'terminal': terminal,
    'auth': {'terminal': authTerminal},
  };
}

@immutable
final class PromptCapabilities {
  const PromptCapabilities({
    this.image = false,
    this.audio = false,
    this.embeddedContext = false,
  });

  factory PromptCapabilities.fromJson(JsonMap json) => PromptCapabilities(
    image: json.boolean('image') ?? false,
    audio: json.boolean('audio') ?? false,
    embeddedContext: json.boolean('embeddedContext') ?? false,
  );

  final bool image;
  final bool audio;
  final bool embeddedContext;

  JsonMap toJson() => {
    'image': image,
    'audio': audio,
    'embeddedContext': embeddedContext,
  };
}

@immutable
final class McpCapabilities {
  const McpCapabilities({this.http = false, this.sse = false});

  factory McpCapabilities.fromJson(JsonMap json) => McpCapabilities(
    http: json.boolean('http') ?? false,
    sse: json.boolean('sse') ?? false,
  );

  final bool http;
  final bool sse;

  JsonMap toJson() => {'http': http, 'sse': sse};
}

/// What the agent offers. Fields this package does not model stay in [raw].
@immutable
final class AgentCapabilities {
  const AgentCapabilities({
    this.loadSession = false,
    this.promptCapabilities = const PromptCapabilities(),
    this.mcpCapabilities = const McpCapabilities(),
    this.supportsLogout = false,
    this.raw = const {},
  });

  factory AgentCapabilities.fromJson(JsonMap json) => AgentCapabilities(
    loadSession: json.boolean('loadSession') ?? false,
    promptCapabilities: PromptCapabilities.fromJson(
      json.object('promptCapabilities') ?? const {},
    ),
    mcpCapabilities: McpCapabilities.fromJson(
      json.object('mcpCapabilities') ?? const {},
    ),
    // `auth.logout` is `{}` when supported, absent or null when not.
    supportsLogout: json.object('auth')?.object('logout') != null,
    raw: json,
  );

  final bool loadSession;
  final PromptCapabilities promptCapabilities;
  final McpCapabilities mcpCapabilities;

  /// Whether the agent answers `logout`.
  final bool supportsLogout;
  final JsonMap raw;

  JsonMap toJson() => {
    ...raw,
    'loadSession': loadSession,
    'promptCapabilities': promptCapabilities.toJson(),
    'mcpCapabilities': mcpCapabilities.toJson(),
    if (supportsLogout) 'auth': {'logout': <String, Object?>{}},
  };
}

/// A way the agent can be authenticated: an `agent` method, named by [id]
/// in `authenticate`; or a `terminal` one, where the client runs the agent's
/// own program interactively with [args] and [env] added — which the spec
/// says must never be passed to `authenticate`. An agent that predates the
/// typed form says the same with `_meta.terminal-auth` (a command and args).
@immutable
final class AuthMethod {
  const AuthMethod({
    required this.id,
    required this.name,
    this.description,
    this.type,
    this.args = const [],
    this.env = const {},
    this.meta,
  });

  factory AuthMethod.fromJson(JsonMap json) => AuthMethod(
    id: json.string('id') ?? '',
    name: json.string('name') ?? '',
    description: json.string('description'),
    type: json.string('type'),
    args: json.strings('args') ?? const [],
    env: switch (json.object('env')) {
      final env? => {
        for (final MapEntry(:key, :value) in env.entries)
          if (value is String) key: value,
      },
      null => const {},
    },
    meta: json.object('_meta'),
  );

  final String id;
  final String name;
  final String? description;

  /// `terminal` for a method the client runs in a terminal; `null` otherwise.
  final String? type;

  /// Appended to the agent's own invocation for a `terminal` method.
  final List<String> args;

  /// Laid over the agent's environment for a `terminal` method.
  final Map<String, String> env;
  final JsonMap? meta;

  /// `_meta.terminal-auth`, as an older agent spells a terminal login.
  JsonMap? get _terminalAuth => meta?.object('terminal-auth');

  /// Whether the person completes this login in a terminal rather than the
  /// agent through `authenticate`.
  bool get isTerminal => type == 'terminal' || _terminalAuth != null;

  /// The program a terminal login runs, when the method names one; null
  /// means the agent's own configured program.
  String? get terminalCommand => _terminalAuth?.string('command');

  /// The arguments a terminal login runs with: [args], else what
  /// `_meta.terminal-auth` names.
  List<String> get terminalArguments =>
      args.isNotEmpty ? args : _terminalAuth?.strings('args') ?? const [];

  JsonMap toJson() => withoutNulls({
    'id': id,
    'name': name,
    'description': description,
    'type': type,
    'args': args.isEmpty ? null : args,
    'env': env.isEmpty ? null : env,
    '_meta': meta,
  });
}
