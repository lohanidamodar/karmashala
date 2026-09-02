import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/util/json_object_splice.dart';
import '../../environments/domain/environment_kind.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_hook_endpoint.dart';
import '../domain/agent_status.dart';

/// Marks the hook entries Karmashala owns, so uninstall can remove exactly
/// those and leave the user's own hooks alone.
const String agentHookMarker = 'karmashala-agent-hook';

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
const List<String> legacyAgentHookMarkers = <String>['chitragupta-agent-hook'];

/// Top-level config keys this app wrote under names it no longer uses.
///
/// Antigravity's `hooks.json` is a map of hook *names*, so the app's own name
/// is the key holding its whole block. A rename therefore does not move that
/// block — it abandons it, and `replaceTopLevelJsonValue` can only ever empty a
/// value, never remove it. Without this the old block would sit at the root of
/// the file for ever, belonging to nothing.
///
/// Literals on purpose; see [legacyAgentHookMarkers].
const List<String> legacyAgentHookConfigKeys = <String>['chitragupta'];

/// Installs Karmashala's callbacks into an agent's own hook configuration.
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
  /// and not one `karmashala-agent-hook` anywhere under `~/.claude`, on either
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

    // Written **before** the config entry that names it, so no launch can leave
    // an entry pointing at a script that is not there yet. The reverse order is
    // what an interrupted install would have to survive, and a hook whose
    // command names a missing file is an error printed into the user's session.
    if (spec.trustsCommandByHash &&
        !await _writeCallbackScript(
          descriptor: descriptor,
          storeHome: storeHome,
          endpoint: endpoint,
          environment: environment,
        )) {
      return false;
    }

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
    // The script goes with them. It is the only file in this feature that holds
    // a bearer token in its own bytes rather than inside somebody else's config,
    // so leaving it behind would outlive both the port it names and the app that
    // could answer on it — the same argument [uninstall] exists for, one file
    // further along. Removed whichever way the config edit went: a config that
    // never carried our entry can still be sitting beside a script an earlier
    // run wrote.
    if (spec.trustsCommandByHash &&
        _removeCallbackScripts(descriptor, storeHome)) {
      changed = true;
    }
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
  ///
  /// **Except for an agent that trusts a hook by hashing its command.** Codex
  /// does (see [AgentHookSpec.trustsCommandByHash]), and the address in that
  /// string changes on every launch, so spelling it inline would revoke our own
  /// trust every time the app started. For those agents the command names a
  /// fixed script instead — constant for the life of the install — and the
  /// address and token live in the script, which nothing hashes.
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
    final spec = descriptor.hooks;
    if (spec != null && spec.trustsCommandByHash) {
      return _scriptCommand(
        descriptor: descriptor,
        event: event,
        environment: environment,
      );
    }
    final uri = base.replace(
      queryParameters: {
        'agent': descriptor.id,
        'event': event,
        'marker': agentHookMarker,
      },
    );
    // Silent, and it always succeeds. A status callback is Karmashala's
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

  /// The base name of the generated callback script, extension excluded.
  ///
  /// It **is** [agentHookMarker], and that is load-bearing rather than tidy:
  /// an installed entry is recognised as ours only by the marker appearing in
  /// its command string ([_isOurs]), and for a fixed-command agent the command
  /// is nothing but this path and an event name. Naming the file anything else
  /// would strand every entry in somebody's config the moment the app was
  /// uninstalled, exactly as [legacyAgentHookMarkers] describes.
  static const String _scriptBaseName = agentHookMarker;

  /// The generated script's file name in [environment].
  ///
  /// Two spellings because the interpreter differs, not because the work does:
  /// a `.cmd` is what `cmd.exe` will run, and a `.sh` is what a distribution's
  /// `sh` will. Both are named explicitly by [_scriptCommand], so neither
  /// relies on an execute bit — which a file written onto a
  /// `\\wsl.localhost` share does not reliably carry anyway.
  static String _scriptFileName(EnvironmentKind environment) =>
      environment == EnvironmentKind.windowsNative
      ? '$_scriptBaseName.cmd'
      : '$_scriptBaseName.sh';

  /// The command a fixed-command agent runs for [event] — the generated script,
  /// named through the same home-directory variable the store locator itself
  /// resolved, and the event as its one argument.
  ///
  /// **Every part of this string is a constant.** That is the whole requirement
  /// ([AgentHookSpec.trustsCommandByHash]): the hash Codex trusts covers this
  /// text, so anything in it that changed between launches would revoke the
  /// user's grant on every start.
  ///
  /// The home directory is named as `%USERPROFILE%` / `$HOME` rather than
  /// resolved here, and that is what makes one string correct in every
  /// reachable environment. `CliStoreLocator` builds the store home from
  /// exactly those two variables — `USERPROFILE` where the environment uses
  /// Windows paths, `HOME` everywhere else — so the path the agent expands at
  /// run time is the path this installer wrote to, by construction. It also
  /// settles WSL, where the two disagree about spelling and not about place:
  /// the app reaches that store as `\\wsl.localhost\<distro>\home\<user>\…`
  /// and the agent inside the distribution reaches the same bytes as
  /// `$HOME/…`. Writing the app's own view into the command would install a
  /// path no process inside the distribution can open.
  ///
  /// **Both forms survive the shell the agent happens to use, which is not one
  /// shell.** Codex hands the string to the session's own detected shell, and
  /// only falls back to a fixed one when it has none
  /// (`hooks/src/engine/command_runner.rs`, `default_shell_command`:
  /// `%COMSPEC%` or `cmd.exe` with `/C` on Windows, `$SHELL` or `/bin/sh` with
  /// `-lc` elsewhere). On Windows the detected shell is commonly PowerShell,
  /// where `%USERPROFILE%` does not expand and a quoted path is a string
  /// expression rather than a command — so naming `cmd.exe` explicitly is what
  /// makes the same text work under `cmd`, Windows PowerShell and `pwsh`
  /// alike: every one of them passes the quoted argument through unexpanded,
  /// and the `cmd` we name does the expanding. On POSIX, `sh` is named for the
  /// matching reason — a file written across a `\\wsl.localhost` share lands
  /// mode 644, so it must be interpreted rather than executed.
  static String? _scriptCommand({
    required AgentDescriptor descriptor,
    required String event,
    required EnvironmentKind environment,
  }) {
    final store = descriptor.store;
    // A fixed-command agent needs a directory of its own to keep the script in,
    // and the store home is the only one this app knows how to name from inside
    // the agent's environment. Without it there is nowhere to put the file.
    if (store == null) return null;
    final file = _scriptFileName(environment);
    return switch (environment) {
      EnvironmentKind.windowsNative =>
        'cmd.exe /c "%USERPROFILE%\\'
            '${store.homeDirectoryName.replaceAll('/', '\\')}\\$file" $event',
      EnvironmentKind.localPosix || EnvironmentKind.wsl =>
        'sh "\$HOME/${store.homeDirectoryName}/$file" $event',
      // Never reached: [AgentHookEndpoint.reaches] is false for SSH, so no
      // command is ever asked for. Spelled out rather than defaulted so a new
      // environment kind is a compile error here instead of a silent guess.
      EnvironmentKind.ssh => null,
    };
  }

  /// Writes the callback script [_scriptCommand] names, and reports whether the
  /// file on disk now spells this [endpoint].
  ///
  /// **This file is the one place the bearer token lives in bytes of our own.**
  /// It is the same token, the same exposure and the same lifetime as the one
  /// the inline command already writes into `settings.json` — status-only,
  /// separate from the privileged `/rpc` credential, and documented as public
  /// to anything running as this user (`LauncherControlServer`). What changes is
  /// only where it sits, and one property improves: [uninstall] deletes the
  /// file, so the token does not outlive the app that minted it.
  ///
  /// Nothing here is logged. The command, the URL and the script body all carry
  /// the token, so none of them may reach a log line — the only thing this
  /// reports upward is a bool.
  Future<bool> _writeCallbackScript({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) async {
    final uri = endpoint.uriFor(
      agentId: descriptor.id,
      event: '',
      environment: environment,
    );
    if (uri == null) return false;
    final file = _callbackScriptFile(descriptor, storeHome, environment);
    if (file == null) return false;
    // The address, with the event left to the script's own argument. Built by
    // hand rather than through `Uri.replace` because the `$1` / `%~1` that
    // stands in for it is not a legal query value and would be escaped.
    final base =
        '${uri.origin}${uri.path}'
        '?agent=${Uri.encodeQueryComponent(descriptor.id)}'
        '&marker=${Uri.encodeQueryComponent(agentHookMarker)}'
        '&event=';
    final contents = environment == EnvironmentKind.windowsNative
        ? _windowsScript(base: base, token: endpoint.token)
        : _posixScript(base: base, token: endpoint.token);

    // Idempotent to the byte, exactly as the config write is: a relaunch that
    // happened to bind the same port rewrites nothing.
    if (file.existsSync()) {
      try {
        if (file.readAsStringSync() == contents) return true;
      } on FileSystemException {
        // Unreadable but present — rewritten below rather than trusted.
      }
    }
    final parent = file.parent;
    if (!parent.existsSync() && Directory(storeHome).existsSync()) {
      await parent.create(recursive: true);
    }
    await _writeAtomically(file, contents);
    try {
      return file.readAsStringSync() == contents;
    } on FileSystemException {
      return false;
    }
  }

  /// The `sh` body. `$1` is the hook event name, supplied by the command.
  ///
  /// **Nothing this runs may reach the agent's stdout.** A hook that can decide
  /// something reads its own stdout for that decision — Codex's
  /// `PermissionRequest` looks for a `decision` there — and the endpoint answers
  /// every callback with `{"ok":true,"status":"…"}`. Inline, `curl -s` prints
  /// that body; here `-o /dev/null` throws it away before it can be read as a
  /// verdict on somebody's tool call. The precedent is measured, not theoretical:
  /// an empty `{}` from an Antigravity `PreToolUse` hook produced *"tool call
  /// denied by pre-tool hook"* on a live run.
  ///
  /// **And the exit status is forced, not merely tidied.** The inline command
  /// ends `|| true` because the owner watched `curl: (52) Empty reply from
  /// server` and a non-zero status print into a live session. Here it is
  /// load-bearing on top of that: Codex reads **exit code 2 with non-empty
  /// stderr as a denial**, and turns the stderr text into the rejection the
  /// user is shown (`hooks/src/events/permission_request.rs`, the exit-2 arm
  /// of `parse_completed`). `curl` exits 2 on an option it cannot parse — a
  /// truncated or half-written script is enough — so a wrapper that let its
  /// own status through could start refusing the user's tool calls and
  /// blaming curl for it. Every other non-zero exit, and a timeout, are
  /// already neutral; 2 is the one that is not, and `exit 0` closes it.
  static String _posixScript({required String base, required String token}) =>
      '#!/bin/sh\n'
      '# Karmashala agent status callback. Generated: rewritten on every\n'
      '# launch, and deleted when the app exits. Edits will not survive.\n'
      'curl -s -o /dev/null -m 2 -X POST \\\n'
      '  -H "Authorization: Bearer $token" \\\n'
      '  --data-binary @- \\\n'
      '  "$base\$1" 2>/dev/null\n'
      'exit 0\n';

  /// The `cmd.exe` body. `%~1` is the hook event name, unquoted.
  ///
  /// CRLF throughout: a batch file with bare newlines is read by some Windows
  /// shells and not others, and this one is written from a Dart process whose
  /// default is `\n`. See [_posixScript] for why the output is discarded and the
  /// status forced to zero.
  static String _windowsScript({required String base, required String token}) =>
      '@echo off\r\n'
      'rem Karmashala agent status callback. Generated: rewritten on every\r\n'
      'rem launch, and deleted when the app exits. Edits will not survive.\r\n'
      'curl -s -o NUL -m 2 -X POST '
      '-H "Authorization: Bearer $token" '
      '--data-binary @- "$base%~1" 2>NUL\r\n'
      'exit /b 0\r\n';

  /// Deletes every spelling of the callback script under [storeHome]. Returns
  /// whether anything was removed.
  ///
  /// Both spellings, not the one this environment would write: a store can be
  /// reached from more than one side of a machine, and an uninstall that only
  /// swept its own platform's extension would leave the other behind for ever.
  bool _removeCallbackScripts(AgentDescriptor descriptor, String storeHome) {
    var removed = false;
    for (final environment in EnvironmentKind.values) {
      final file = _callbackScriptFile(descriptor, storeHome, environment);
      if (file == null || !file.existsSync()) continue;
      try {
        file.deleteSync();
        removed = true;
      } on FileSystemException {
        // Someone else's directory, and the config entry is already gone — a
        // script nothing names costs the agent nothing.
      }
    }
    return removed;
  }

  /// Where the generated script sits **as this app sees it**: beside the hook
  /// config, which for a fixed-command agent is the store home itself.
  ///
  /// `null` when this spec's config file is not directly in the store home. The
  /// script's run-time path is built from the store's own directory name
  /// ([_scriptCommand]), so the two only agree while the config sits there —
  /// and a script the agent cannot find is the failure mode this whole feature
  /// exists to avoid.
  File? _callbackScriptFile(
    AgentDescriptor descriptor,
    String storeHome,
    EnvironmentKind environment,
  ) {
    final config = configFileFor(descriptor, storeHome);
    if (config == null || descriptor.store == null) return null;
    if (p.normalize(config.parent.path) != p.normalize(storeHome)) return null;
    return File(p.join(storeHome, _scriptFileName(environment)));
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
    final staged = File('${file.path}.karmashala-tmp');
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
