import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/util/json_object_splice.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_hook_endpoint.dart';

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
  ///
  /// **Idempotent to the byte.** An event whose entry already spells the exact
  /// command for this [endpoint] is left alone, so a relaunch that happens to
  /// bind the same port rewrites nothing — the file keeps whatever formatting
  /// the user's editor gave it. The port is ephemeral, so this is rare; a
  /// rewrite that changes nothing is still a write to somebody else's config.
  Future<bool> install({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
  }) async {
    final spec = descriptor.hooks;
    if (spec == null) return false;

    await _rewrite(descriptor, storeHome, (hooks) {
      var changed = false;
      for (final event in spec.eventStatus.keys) {
        final current = hooks[event];
        // A shape we do not understand is left exactly as it is, the way
        // [uninstall] leaves it — a hand-edited or future-shaped config is
        // still the user's, and losing a value beats nothing we install.
        if (current != null && current is! List) continue;
        final entries = current is List ? current : const <Object?>[];
        final command = hookCommand(
          descriptor: descriptor,
          event: event,
          endpoint: endpoint,
        );
        if (_alreadyCurrent(entries, command)) continue;
        hooks[event] = [
          ..._withoutOurs(entries),
          {
            'hooks': [
              {'type': 'command', 'command': command},
            ],
          },
        ];
        changed = true;
      }
      return changed;
    });
    return true;
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
        final current = hooks[event];
        // Not a list: not a shape this app ever wrote, so there is nothing of
        // ours in it and nothing to decide. Casting it would throw on a config
        // we are only passing through.
        if (current is! List) continue;
        final kept = _withoutOurs(current);
        if (kept.length == current.length) continue;
        changed = true;
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

  /// [entries] with our own entries removed. Everything else is carried over
  /// untouched — the list belongs to the user, and only the entries carrying
  /// [agentHookMarker] are ours to drop.
  List<Object?> _withoutOurs(List<Object?> entries) => [
    for (final entry in entries)
      if (!_isOurs(entry)) entry,
  ];

  /// Whether [entries] already holds exactly one entry of ours and it spells
  /// [command] — the case where installing again would rewrite the file to
  /// produce the bytes it already has.
  bool _alreadyCurrent(List<Object?> entries, String command) {
    final ours = entries.where(_isOurs).toList();
    if (ours.length != 1) return false;
    final hooks = (ours.single as Map)['hooks'];
    if (hooks is! List || hooks.length != 1) return false;
    final hook = hooks.single;
    return hook is Map && hook['command'] == command;
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
