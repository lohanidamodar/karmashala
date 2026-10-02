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

/// What this client offers the agent. Terminals are never advertised in this
/// cut, so `terminal` is always false on the wire.
@immutable
final class ClientCapabilities {
  const ClientCapabilities({
    this.fs = const FsCapabilities(readTextFile: true, writeTextFile: true),
  });

  final FsCapabilities fs;

  bool get terminal => false;

  JsonMap toJson() => {'fs': fs.toJson(), 'terminal': terminal};
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
    raw: json,
  );

  final bool loadSession;
  final PromptCapabilities promptCapabilities;
  final McpCapabilities mcpCapabilities;
  final JsonMap raw;

  JsonMap toJson() => {
    ...raw,
    'loadSession': loadSession,
    'promptCapabilities': promptCapabilities.toJson(),
    'mcpCapabilities': mcpCapabilities.toJson(),
  };
}

/// A way the agent can be authenticated, named by [id] in `authenticate`.
@immutable
final class AuthMethod {
  const AuthMethod({
    required this.id,
    required this.name,
    this.description,
    this.type,
  });

  factory AuthMethod.fromJson(JsonMap json) => AuthMethod(
    id: json.string('id') ?? '',
    name: json.string('name') ?? '',
    description: json.string('description'),
    type: json.string('type'),
  );

  final String id;
  final String name;
  final String? description;

  /// `terminal` for a method the client runs in a terminal; `null` otherwise.
  final String? type;

  JsonMap toJson() => withoutNulls({
    'id': id,
    'name': name,
    'description': description,
    'type': type,
  });
}
