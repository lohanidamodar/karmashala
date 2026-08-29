import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/util/json_object_splice.dart';
import '../domain/agent_descriptor.dart';
import 'agent_hook_server.dart';

/// Marks the hook entries Chitragupta owns, so uninstall can remove exactly
/// those and leave the user's own hooks alone.
const String agentHookMarker = 'chitragupta-agent-hook';

/// Installs Chitragupta's callbacks into an agent's own hook configuration.
///
/// The config file is edited by **splicing** only its hook value back in
/// (`replaceTopLevelJsonValue`), so every other key keeps its original bytes —
/// agent configs can contain keys that differ only by case, which a
/// decode/encode round trip would silently collapse.
class AgentHookInstaller {
  const AgentHookInstaller();

  /// Writes one hook entry per event the descriptor declares. Returns `false`
  /// when the agent has no hook configuration to write into. Throws
  /// [FormatException] if the existing config is not a JSON object, leaving it
  /// untouched.
  Future<bool> install({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
  }) async {
    final spec = descriptor.hooks;
    if (spec == null) return false;

    return _rewrite(descriptor, storeHome, (hooks) {
      for (final event in spec.eventStatus.keys) {
        final kept = _withoutOurs(hooks[event]);
        kept.add({
          'hooks': [
            {
              'type': 'command',
              'command': hookCommand(
                descriptor: descriptor,
                event: event,
                endpoint: endpoint,
              ),
            },
          ],
        });
        hooks[event] = kept;
      }
      return true;
    });
  }

  /// Removes the entries this app installed. Returns whether anything changed.
  Future<bool> uninstall({
    required AgentDescriptor descriptor,
    required String storeHome,
  }) async {
    final spec = descriptor.hooks;
    if (spec == null) return false;

    var changed = false;
    await _rewrite(descriptor, storeHome, (hooks) {
      for (final event in hooks.keys.toList()) {
        final before = (hooks[event] as List?)?.length ?? 0;
        final kept = _withoutOurs(hooks[event]);
        if (kept.length != before) changed = true;
        if (kept.isEmpty) {
          hooks.remove(event);
        } else {
          hooks[event] = kept;
        }
      }
      return changed;
    });
    return changed;
  }

  /// The command line an agent runs for [event]: post the hook payload from
  /// stdin to the loopback endpoint, bounded so a stopped app costs nothing.
  String hookCommand({
    required AgentDescriptor descriptor,
    required String event,
    required AgentHookEndpoint endpoint,
  }) {
    final uri = endpoint
        .uriFor(agentId: descriptor.id, event: event)
        .replace(
          queryParameters: {
            'agent': descriptor.id,
            'event': event,
            'marker': agentHookMarker,
          },
        );
    return 'curl -sS -m 2 -X POST '
        '-H "Authorization: Bearer ${endpoint.token}" '
        '--data-binary @- "$uri"';
  }

  /// Reads the config, hands its hook map to [edit], and splices the result
  /// back if [edit] reports a change.
  Future<bool> _rewrite(
    AgentDescriptor descriptor,
    String storeHome,
    bool Function(Map<String, Object?> hooks) edit,
  ) async {
    final spec = descriptor.hooks!;
    final file = File(p.join(storeHome, spec.configFileName));
    final raw = await file.exists() ? await file.readAsString() : '{}';
    final trimmed = raw.trim().isEmpty ? '{}' : raw;

    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Agent config root is not a JSON object');
    }
    final current = decoded[spec.configKey];
    final hooks = current is Map<String, Object?>
        ? Map<String, Object?>.from(current)
        : <String, Object?>{};

    if (!edit(hooks)) return false;

    final updated = replaceTopLevelJsonValue(
      trimmed,
      spec.configKey,
      jsonEncode(hooks),
    );
    await file.writeAsString(updated, flush: true);
    return true;
  }

  /// [value] as a mutable list with our own entries removed.
  List<Object?> _withoutOurs(Object? value) {
    if (value is! List) return [];
    return [
      for (final entry in value)
        if (!_isOurs(entry)) entry,
    ];
  }

  bool _isOurs(Object? entry) {
    if (entry is! Map) return false;
    final hooks = entry['hooks'];
    if (hooks is! List) return false;
    return hooks.any(
      (hook) =>
          hook is Map &&
          hook['command'] is String &&
          (hook['command'] as String).contains(agentHookMarker),
    );
  }
}
