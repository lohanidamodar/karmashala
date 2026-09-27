import 'server_tool_set.dart';

/// Every agent tool the server runs itself, by name — all of them since slice
/// 5b. A tool none of these families serves is one the app still answers
/// (the attention inbox, until slice 5c), and is forwarded to it.
class ServerTools {
  ServerTools([Iterable<ServerToolSet> families = const []]) {
    families.forEach(add);
  }

  final _families = <ServerToolSet>[];
  final _byName = <String, ServerToolSet>{};

  /// Serves [family]'s tools from now on. A name two families both claim is
  /// a programming error.
  void add(ServerToolSet family) {
    for (final schema in family.schemas) {
      final name = schema['name'] as String;
      if (_byName.containsKey(name)) {
        throw StateError('Two server tool families serve $name.');
      }
      _byName[name] = family;
    }
    _families.add(family);
  }

  /// Whether the server serves [tool] itself.
  bool serves(String tool) => _byName.containsKey(tool);

  /// Every tool the server serves, unannotated, family by family.
  List<Map<String, Object?>> get schemas => [
    for (final family in _families) ...family.schemas,
  ];

  /// Runs [tool] here; null when the server does not serve it.
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => _byName[tool]?.call(tool, arguments, callerSessionId);
}
