import 'package:meta/meta.dart';

import '../json.dart';

/// An MCP server the agent should connect to for the session.
@immutable
sealed class McpServerEntry {
  const McpServerEntry(this.name);

  const factory McpServerEntry.stdio(
    String name, {
    required String command,
    List<String> args,
    Map<String, String> env,
  }) = McpServerStdio;

  const factory McpServerEntry.http(
    String name, {
    required String url,
    Map<String, String> headers,
  }) = McpServerHttp;

  final String name;

  JsonMap toJson();

  static List<JsonMap> _pairs(Map<String, String> values) => [
    for (final entry in values.entries)
      {'name': entry.key, 'value': entry.value},
  ];
}

final class McpServerStdio extends McpServerEntry {
  const McpServerStdio(
    super.name, {
    required this.command,
    this.args = const [],
    this.env = const {},
  });

  final String command;
  final List<String> args;
  final Map<String, String> env;

  @override
  JsonMap toJson() => {
    'name': name,
    'command': command,
    'args': args,
    'env': McpServerEntry._pairs(env),
  };
}

final class McpServerHttp extends McpServerEntry {
  const McpServerHttp(super.name, {required this.url, this.headers = const {}});

  final String url;
  final Map<String, String> headers;

  @override
  JsonMap toJson() => {
    'type': 'http',
    'name': name,
    'url': url,
    'headers': McpServerEntry._pairs(headers),
  };
}
