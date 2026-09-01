import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/util/json_object_splice.dart';
import '../../environments/domain/environment_kind.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_hook_endpoint.dart';
import '../domain/agent_status.dart';

/// Marks the hook entries Chitragupta owns, so uninstall can remove exactly
/// those and leave the user's own hooks alone.
const String agentHookMarker = 'chitragupta-agent-hook';

/// Markers this app wrote under names it no longer uses.
///
/// An entry is identified *only* by its marker, so renaming the app without
/// remembering the old one would strand every entry already in somebody's
/// config: the new build would not recognise it, and the old build is
/// uninstalled and cannot be asked. Nothing else in the system can find them.
///
/// These strings are literals on purpose and must survive any future rename —
/// `legacy_hook_marker_test.dart` fails if a find-and-replace rewrites them,
/// which is exactly how they would otherwise be lost.
const List<String> legacyAgentHookMarkers = <String>[];

/// Top-level config keys this app wrote under names it no longer uses.
///
/// Antigravity's `hooks.json` is a map of hook *names*, so the app's own name
/// is the key holding its whole block. A rename therefore does not move that
/// block — it abandons it, and `replaceTopLevelJsonValue` can only ever empty a
/// value, never remove it. Without this the old block would sit at the root of
/// the file for ever, belonging to nothing.
///
/// Literals on purpose; see [legacyAgentHookMarkers].
const List<String> legacyAgentHookConfigKeys = <String>[];

/// Installs Chitragupta's callbacks into an agent's own hook configuration.
///
/// The config file is edited by **splicing** only its hook value back in
/// (`replaceTopLevelJsonValue`), so every other key keeps its original bytes —
/// agent configs can contain keys that differ only by case, which a
/// decode/encode round trip would silently collapse.
///
/// Every entry point takes the [EnvironmentKind] the config belongs to, because
/// the callback address differs per environment and there is no safe default:
/// writing a loopback URL into a WSL distribution's config installs a hook that
/// fires on every tool call and never arrives. An environment
/// [AgentHookEndpoint] cannot reach is **refused here as well as skipped by the
/// caller**, so a mistake upstream cannot put a dead URL in somebody's file.
class AgentHookInstaller {
  const AgentHookInstaller({this.replace = _replaceFile});

  /// How staged content is moved onto the real config. Injectable because the
  /// failure path is the guarantee: a rename cannot be made to fail on demand,
  /// and "an interrupted install leaves a config the agent can still parse" is
  /// otherwise a claim with no test behind it.
  final Future<void> Function(File staged, File destination) replace;

  /// Writes one hook entry per event the descriptor declares. Returns whether
  /// the config **on disk** now carries this endpoint's callback for every one
  /// of them. Throws [FormatException] if the existing config is not a JSON
  /// object, leaving it untouched.
  ///
  /// **The answer is read back, never assumed.** This used to `return true` the
  /// moment `_rewrite` came back, which made the return value a statement about
  /// intent rather than about the file — so every way a write can fail without
  /// raising was reported as a success. The owner's machine showed exactly that:
  ///
  ///   2026-09-01 11:25:53 I bootstrap: Agent hooks: 1 installed, 1 skipped.
  ///
  /// and not one `chitragupta-agent-hook` anywhere under `~/.claude`, on either
  /// side of the machine, while `notifications.status` reported `0 by hook` all
  /// day. The most likely way it got there is the one this cannot prevent and
  /// must therefore report: an agent CLI rewrites its own `settings.json` from
  /// the copy it loaded at *its* start-up (`settings.json` on that machine was
  /// written at 11:39, fourteen minutes after the install), and our entries go
  /// with it. Nothing here can stop that. What it can do is stop claiming the
  /// hooks are there — a reported install that wrote nothing is worse than a
  /// reported skip, because only the skip ever gets investigated.
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
    required EnvironmentKind environment,
  }) async {
    final spec = descriptor.hooks;
    if (spec == null) return false;
    if (!endpoint.reaches(environment)) return false;

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
          environment: environment,
        )!;
        if (_alreadyCurrent(entries, command)) continue;
        hooks[event] = [
          ..._withoutOurs(entries),
          _entry(spec.entryStyle, command),
        ];
        changed = true;
      }
      return changed;
    });
    return installedEvents(
          descriptor: descriptor,
          storeHome: storeHome,
          endpoint: endpoint,
          environment: environment,
        ).length ==
        spec.eventStatus.length;
  }

  /// The declared events whose entry is on disk **right now**, spelling this
  /// [endpoint]'s command.
  ///
  /// Separate from [install] because the count is worth reporting on its own: a
  /// partial install — some events ours, one left alone because the user's
  /// config holds a shape we do not understand there — is a real state, and
  /// "installed: false" with no number is not enough to act on.
  ///
  /// Reads the file rather than any cached decode. A config that vanished, was
  /// truncated or stopped being JSON between the write and this call answers
  /// "none", which is the truth about what will fire.
  Set<String> installedEvents({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) {
    final spec = descriptor.hooks;
    if (spec == null) return const {};
    final file = configFileFor(descriptor, storeHome)!;
    Map<String, Object?> hooks;
    try {
      final raw = file.readAsStringSync();
      final decoded = jsonDecode(raw.trim().isEmpty ? '{}' : raw);
      if (decoded is! Map<String, Object?>) return const {};
      final current = decoded[spec.configKey];
      hooks = current is Map<String, Object?> ? current : const {};
    } on Object {
      return const {};
    }

    final found = <String>{};
    for (final event in spec.eventStatus.keys) {
      final entries = hooks[event];
      if (entries is! List) continue;
      final command = hookCommand(
        descriptor: descriptor,
        event: event,
        endpoint: endpoint,
        environment: environment,
      );
      if (command == null) continue;
      if (_alreadyCurrent(entries, command)) found.add(event);
    }
    return found;
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
  /// stdin to the endpoint address for [environment], bounded so a stopped app
  /// costs nothing. `null` when nothing this app binds is reachable from there.
  ///
  /// It names no path of its own — only `curl`, a URL and a header — so the one
  /// string is equally valid in a Windows shell and in a distribution's `sh`.
  /// The token is base64url (`A-Za-z0-9-_=`) and both the header and the URL
  /// are double-quoted, so the `&` between query parameters cannot background
  /// the command and nothing in it is expanded.
  String? hookCommand({
    required AgentDescriptor descriptor,
    required String event,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) {
    final base = endpoint.uriFor(
      agentId: descriptor.id,
      event: event,
      environment: environment,
    );
    if (base == null) return null;
    final uri = base
        .replace(
          queryParameters: {
            'agent': descriptor.id,
            'event': event,
            'marker': agentHookMarker,
          },
        );
    // Silent, and it always succeeds. A status callback is Chitragupta's
    // business, not the agent's: the owner watched `curl: (52) Empty reply
    // from server` print into a live session and the shell exit non-zero
    // because the app happened not to be answering on the WSL interface. A
    // hook that cannot deliver must cost the agent nothing — no message, no
    // exit code — so `-s` swallows the diagnostic and `|| true` swallows the
    // status. What the app loses is a status update it was never guaranteed;
    // what the user loses otherwise is confidence in their own terminal.
    return 'curl -s -m 2 -X POST '
        '-H "Authorization: Bearer ${endpoint.token}" '
        '--data-binary @- "$uri" || true';
  }

  /// Reads the config, hands its hook map to [edit], and splices the result
  /// back if [edit] reports a change.
  Future<bool> _rewrite(
    AgentDescriptor descriptor,
    String storeHome,
    bool Function(Map<String, Object?> hooks) edit,
  ) async {
    final spec = descriptor.hooks!;
    final file = configFileFor(descriptor, storeHome)!;
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

    // A block we left behind under an older name of this app. Dropped whether
    // or not [edit] changes anything, because it is ours and nothing else will
    // ever recognise it.
    final abandoned = legacyAgentHookConfigKeys
        .where((key) => key != spec.configKey && decoded.containsKey(key))
        .toList();

    if (!edit(hooks) && abandoned.isEmpty) return false;

    // The config need not sit in the store home, so its directory can be one
    // the CLI has not created yet — `~/.gemini/config` beside
    // `~/.gemini/antigravity-cli`. Created only when the **store** is really
    // there, so a machine without this agent installed never gets an empty
    // config directory in its home from us.
    final parent = file.parent;
    if (!parent.existsSync() && Directory(storeHome).existsSync()) {
      await parent.create(recursive: true);
    }

    var updated = replaceTopLevelJsonValue(
      trimmed,
      spec.configKey,
      jsonEncode(hooks),
    );
    for (final key in abandoned) {
      updated = removeTopLevelJsonKey(updated, key);
    }
    await _writeAtomically(file, updated);
    return true;
  }

  /// Stages [contents] beside [file] and moves it into place.
  ///
  /// A plain `writeAsString` truncates the config first, so a process killed
  /// mid-write leaves an agent that will not start — and this now writes across
  /// a `\\wsl.localhost` share as well as to local disk, where a write is
  /// slower and the window is wider. Staging inverts that: the only step that
  /// touches the real file is a rename, and a failed rename leaves the config
  /// exactly as the user's editor left it.
  Future<void> _writeAtomically(File file, String contents) async {
    final staged = File('${file.path}.chitragupta-tmp');
    await staged.writeAsString(contents, flush: true);
    try {
      await replace(staged, file);
    } finally {
      // Never left behind, whichever way the move went: a stray file in
      // somebody's `.claude` directory is litter we would have to explain.
      if (staged.existsSync()) {
        try {
          staged.deleteSync();
        } on FileSystemException {
          // Nothing more to try, and it must not mask the real failure.
        }
      }
    }
  }

  /// The file [descriptor]'s hooks are configured in, or `null` when it has no
  /// hook spec.
  ///
  /// [AgentHookSpec.configFileName] is a path *relative to the store home*, so
  /// it can walk out of it: Antigravity keeps its data in
  /// `~/.gemini/antigravity-cli` and reads `~/.gemini/config/hooks.json`, its
  /// sibling. Normalized rather than joined blindly, so the `..` is resolved
  /// here instead of being handed to the filesystem — a `\\wsl.localhost` UNC
  /// store home is one of the paths this has to survive.
  File? configFileFor(AgentDescriptor descriptor, String storeHome) {
    final spec = descriptor.hooks;
    if (spec == null) return null;
    return File(p.normalize(p.join(storeHome, spec.configFileName)));
  }

  /// One installed handler, in the shape this agent reads.
  Map<String, Object?> _entry(AgentHookEntryStyle style, String command) =>
      switch (style) {
        AgentHookEntryStyle.grouped => {
          'hooks': [
            {'type': 'command', 'command': command},
          ],
        },
        AgentHookEntryStyle.flat => {'type': 'command', 'command': command},
      };

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
    final commands = _commandsIn(ours.single).toList();
    return commands.length == 1 && commands.single == command;
  }

  /// Whether [entry] is one of ours. Exposed for the legacy-marker test, which
  /// has to prove an entry written under an old name is still removable.
  @visibleForTesting
  bool debugIsOurs(Object? entry) => _isOurs(entry);

  /// Ours if it carries the current marker **or** one we used to write.
  bool _isOurs(Object? entry) => _commandsIn(entry).any(
    (command) =>
        command.contains(agentHookMarker) ||
        legacyAgentHookMarkers.any(command.contains),
  );

  /// Every command string an entry carries, whichever shape it is written in.
  ///
  /// Both styles are read regardless of what this agent's spec declares: a
  /// config written by an earlier build, or hand-edited, is still ours to
  /// recognise and take back out on uninstall.
  Iterable<String> _commandsIn(Object? entry) sync* {
    if (entry is! Map) return;
    final grouped = entry['hooks'];
    if (grouped is List) {
      for (final hook in grouped) {
        if (hook is Map && hook['command'] is String) {
          yield hook['command']! as String;
        }
      }
      return;
    }
    if (entry['command'] is String) yield entry['command']! as String;
  }
}

/// Move [staged] onto [destination], replacing it.
///
/// Verified over `\\wsl.localhost\<distro>\home\<user>` as well as on local
/// disk: the moved file lands owned by the distribution's user with mode 644,
/// which is what an agent inside that distribution has to be able to read.
Future<void> _replaceFile(File staged, File destination) =>
    staged.rename(destination.path);
