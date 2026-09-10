import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_core/util.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/descriptors.dart';

/// Marks the hook entries Karmashala owns, so uninstall can remove exactly
/// those and leave the user's own hooks alone.
const String agentHookMarker = 'karmashala-agent-hook';

/// Markers this app wrote under names it no longer uses. An entry is
/// identified *only* by its marker, so these literals must survive any future
/// rename — `legacy_hook_marker_test.dart` fails if one is find-and-replaced.
const List<String> legacyAgentHookMarkers = <String>['chitragupta-agent-hook'];

/// Top-level config keys this app wrote under names it no longer uses.
/// Antigravity's `hooks.json` keys its block by app name, so a rename abandons
/// that block rather than moving it. Literals; see [legacyAgentHookMarkers].
const List<String> legacyAgentHookConfigKeys = <String>['chitragupta'];

/// Installs Karmashala's callbacks into an agent's own hook configuration.
///
/// The config is edited by splicing only its hook value back in, so every other
/// key keeps its original bytes — a decode/encode round trip would collapse
/// keys that differ only by case. An environment [AgentHookEndpoint] cannot
/// reach is refused here as well as skipped by the caller. The config entry and
/// the callback script are constants written once; only the endpoint file
/// beside them is rewritten per launch, so an agent CLI that saves its own
/// config from a stale copy has one chance a launch to drop our entry, not two.
///
/// Nothing here is `…Sync`: a WSL store home is a `\\wsl.localhost` UNC path
/// served from inside the distribution, and a synchronous file operation on it
/// has no timeout and holds the isolate the window is painted on.
class AgentHookInstaller {
  const AgentHookInstaller({
    this.replace = _replaceFile,
    this.restrict = restrictToOwner,
  });

  /// How staged content is moved onto the real config. Injectable because a
  /// rename cannot be made to fail on demand, and "an interrupted install leaves
  /// a config the agent can still parse" needs a test behind it.
  final Future<void> Function(File staged, File destination) replace;

  /// How the endpoint file is closed to other accounts, applied to the staged
  /// file **before** the token is written into it. Injectable so a test can
  /// prove it is attempted without spawning `icacls` or `chmod`.
  final Future<bool> Function(File file, EnvironmentKind environment) restrict;

  /// Whether this agent's store exists in [storeHome] at all — the one reason
  /// [install] can answer `false` that is not a fault.
  Future<bool> storeIsPresent(String storeHome) =>
      Directory(storeHome).exists();

  /// Writes one hook entry per event the descriptor declares. Returns whether
  /// the config **on disk** now carries this endpoint's callback for every one
  /// of them — read back rather than assumed, because a write can fail without
  /// raising and a reported install that wrote nothing never gets investigated.
  /// Throws [FormatException] if the existing config is not a JSON object,
  /// leaving it untouched; an entry that already spells the command is left
  /// byte-identical.
  Future<bool> install({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) async {
    final spec = descriptor.hooks;
    if (spec == null) return false;
    if (!endpoint.reaches(environment)) return false;

    // Read the config **before** writing anything beside it: a store whose
    // config we turn out not to be able to edit is a store we wrote nothing
    // into, rather than one holding a bearer token beside an unopened file.
    await _readConfigObject(descriptor, storeHome);

    // Written **before** the config entry that names it — a hook whose command
    // names a missing file is an error printed into the user's session.
    if (!await _writeCallbackFiles(
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
        // A shape we do not understand is left exactly as it is: losing a
        // value of the user's beats anything we install.
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
    final events = await installedEvents(
      descriptor: descriptor,
      storeHome: storeHome,
      endpoint: endpoint,
      environment: environment,
    );
    return events.length == spec.eventStatus.length;
  }

  /// The declared events whose entry is on disk **right now**, spelling this
  /// [endpoint]'s command. Separate from [install] because a partial install is
  /// a real state. Reads the file rather than any cached decode, so a config
  /// that vanished, was truncated or stopped being JSON answers "none".
  Future<Set<String>> installedEvents({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) async {
    final spec = descriptor.hooks;
    if (spec == null) return const {};
    final file = configFileFor(descriptor, storeHome)!;
    Map<String, Object?> hooks;
    try {
      final raw = await file.readAsString();
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
        // Not a list: not a shape this app ever wrote, and casting it would
        // throw on a config we are only passing through.
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
    // The script and the endpoint file go with them — the endpoint file is the
    // only one holding a bearer token and a port. Removed whichever way the
    // config edit went; an earlier run's files can outlive its entry.
    if (await _removeGeneratedFiles(descriptor, storeHome)) changed = true;
    return changed;
  }

  /// Deletes the endpoint file, leaving the config entry and the script in
  /// place — what the app does on the way out instead of a full [uninstall].
  /// Those two are constants that never go stale, and rewriting them every
  /// launch is what lost the race in the class doc; only the address and the
  /// token die with the process. Returns whether a file was removed.
  Future<bool> retireEndpoint({
    required AgentDescriptor descriptor,
    required String storeHome,
  }) async {
    if (descriptor.hooks == null) return false;
    var removed = false;
    final file = _endpointFile(descriptor, storeHome);
    if (file != null && await file.exists()) {
      try {
        await file.delete();
        removed = true;
      } on FileSystemException {
        // Someone else's directory. The script fails closed on a token it
        // cannot authenticate with anyway.
      }
    }
    // And the staging file a *previous* quit left mid-write; the soak found
    // those accumulating, one per interrupted launch.
    if (file != null) await _removeStaged(File('${file.path}.karmashala-tmp'));
    // The spool goes with it, and for the same reason: what it holds is this
    // The spool holds this launch's undelivered payloads, and there is no
    // launch any more.
    final spool = spoolDirectoryFor(descriptor, storeHome);
    if (spool != null && await spool.exists()) {
      try {
        await spool.delete(recursive: true);
        removed = true;
      } on FileSystemException {
        // Same answer: the script exits zero on a directory it cannot see.
      }
    }
    return removed;
  }

  /// The command line an agent runs for [event]: the generated callback script,
  /// with the event as its one argument. `null` when nothing this app binds is
  /// reachable from [environment], or when the agent declares no store to keep
  /// the script in.
  ///
  /// **Every part of this string is a constant.** The address and the
  /// per-launch token moved out into an endpoint file the script reads when the
  /// hook fires: rewriting three CLIs' *global* config twice a launch kept
  /// losing our entry to the CLI's own save, and Codex hashes the command to
  /// decide trust ([AgentHookSpec.trustsCommandByHash]), so a command that
  /// changed would revoke the user's grant every launch. A fixed path rather
  /// than an environment variable, because we do not own the agent's
  /// environment — Codex even re-runs each hook through a login shell.
  String? hookCommand({
    required AgentDescriptor descriptor,
    required String event,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) {
    // The reachability gate the URL used to provide, so a mistake upstream
    // cannot put a hook in a config it could never call back from.
    if (!endpoint.reaches(environment)) return null;
    if (descriptor.hooks == null) return null;
    return _scriptCommand(
      descriptor: descriptor,
      event: event,
      environment: environment,
    );
  }

  /// The base name of the generated callback script, extension excluded.
  ///
  /// It **is** [agentHookMarker]: an entry is recognised as ours only by the
  /// marker appearing in its command ([_isOurs]), and for a fixed-command agent
  /// the command is nothing but this path and an event name.
  static const String _scriptBaseName = agentHookMarker;

  /// The file the generated script reads its address and token out of, every
  /// time a hook fires.
  ///
  /// One name for both platforms — a store home is only ever reached from one
  /// side of the machine — with the line endings that environment's reader
  /// expects. It sits in the store home because that is the single directory
  /// both this app and the agent can name; a WSL agent's `sh` cannot open a
  /// Windows path.
  static const String _endpointFileName = '$_scriptBaseName.endpoint';

  /// The directory a spooling agent drops its payloads into, beside the script
  /// and the endpoint file that name it.
  ///
  /// Only ever written from inside a WSL distribution and read over
  /// `\\wsl.localhost`. Volatile like the endpoint file, so [retireEndpoint]
  /// takes the whole directory; what survives an unclean exit is bounded by the
  /// script, which stops writing at 2000 files, and each payload is timed by its
  /// own mtime rather than by when this app got round to reading it.
  static const String _spoolDirectoryName = '$_scriptBaseName.spool';

  /// Where [descriptor]'s spooled payloads land under [storeHome], as **this
  /// app** sees it. `null` for an agent with no store of its own. Public so the
  /// drainer need not re-derive the name — a second spelling of a generated path
  /// is how an uninstall comes to leave something behind.
  Directory? spoolDirectoryFor(AgentDescriptor descriptor, String storeHome) =>
      descriptor.store == null
      ? null
      : Directory(p.join(storeHome, _spoolDirectoryName));

  /// The generated script's file name in [environment]. Both are named
  /// explicitly by [_scriptCommand], so neither relies on an execute bit — which
  /// a file written onto a `\\wsl.localhost` share does not reliably carry.
  static String _scriptFileName(EnvironmentKind environment) =>
      environment == EnvironmentKind.windowsNative
      ? '$_scriptBaseName.cmd'
      : '$_scriptBaseName.sh';

  /// The command an agent runs for [event] — the generated script, named
  /// through the same home-directory variable the store locator itself resolved.
  ///
  /// `%USERPROFILE%` / `$HOME` rather than a resolved path: `CliStoreLocator`
  /// builds every store home from exactly those two, so the path the agent
  /// expands at run time is the path this installer wrote to. That is what
  /// settles WSL, where the app reaches the store as `\\wsl.localhost\…` and
  /// the agent reaches the same bytes as `$HOME/…`. `cmd.exe` and `sh` are named
  /// explicitly because the agent picks the shell: PowerShell does not expand
  /// `%USERPROFILE%`, and a script written across a WSL share lands mode 644 and
  /// must be interpreted rather than executed.
  static String? _scriptCommand({
    required AgentDescriptor descriptor,
    required String event,
    required EnvironmentKind environment,
  }) {
    final store = descriptor.store;
    // A stable command needs a directory of its own for the script and the
    // endpoint file, and the store home is the only one this app can name from
    // inside the agent's environment. Without it, no hook at all — an inline
    // command that changed every launch is the bug, not the fallback.
    if (store == null) return null;
    final file = _scriptFileName(environment);
    return switch (environment) {
      EnvironmentKind.windowsNative =>
        'cmd.exe /c "%USERPROFILE%\\'
            '${store.homeDirectoryName.replaceAll('/', '\\')}\\$file" $event',
      EnvironmentKind.localPosix || EnvironmentKind.wsl =>
        'sh "\$HOME/${store.homeDirectoryName}/$file" $event',
      // Never reached: [AgentHookEndpoint.reaches] is false for SSH. Spelled
      // out so a new environment kind is a compile error, not a silent guess.
      EnvironmentKind.ssh => null,
    };
  }

  /// Writes the two files [_scriptCommand] depends on — the constant script and
  /// the endpoint file it reads — and reports whether both are on disk spelling
  /// what this run intends.
  ///
  /// The endpoint file goes **second**: a script with no endpoint file exits
  /// zero and costs nothing, while an endpoint file with no script is a token on
  /// disk that nothing will delete. It is now the only place the bearer token
  /// lives in bytes of our own, which is why [retireEndpoint] removes it and
  /// [restrict] hardens it. Nothing here is logged — the URL and the body both
  /// carry the token.
  Future<bool> _writeCallbackFiles({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) async {
    final transport = endpoint.transportFor(environment);
    if (transport == null) return false;
    final script = _callbackScriptFile(descriptor, storeHome, environment);
    final endpointFile = _endpointFile(descriptor, storeHome);
    if (script == null || endpointFile == null) return false;

    if (!await _writeIfChanged(
      script,
      storeHome,
      environment == EnvironmentKind.windowsNative
          ? _windowsScript
          : _posixScript,
    )) {
      return false;
    }

    switch (transport) {
      case AgentHookHttpTransport():
        final uri = endpoint.uriFor(
          agentId: descriptor.id,
          event: '',
          environment: environment,
        );
        if (uri == null) return false;
        // The address, with the event left to the script's own argument. Built
        // by hand rather than with `Uri.replace`, which would escape the
        // `$event` / `%~1` standing in for it.
        final base =
            '${uri.origin}${uri.path}'
            '?agent=${Uri.encodeQueryComponent(descriptor.id)}'
            '&marker=${Uri.encodeQueryComponent(agentHookMarker)}'
            '&event=';
        return _writeIfChanged(
          endpointFile,
          storeHome,
          _httpEndpointFileContents(
            base: base,
            token: transport.token,
            newline: environment == EnvironmentKind.windowsNative
                ? '\r\n'
                : '\n',
          ),
          harden: (staged) => restrict(staged, environment),
        );
      case AgentHookSpoolTransport():
        // Made **before** the endpoint file that names it: the script exits
        // zero on a directory that is not there, so a half-finished install
        // costs the agent nothing.
        final spool = spoolDirectoryFor(descriptor, storeHome);
        if (spool == null) return false;
        try {
          if (!await spool.exists()) await spool.create(recursive: true);
        } on FileSystemException {
          return false;
        }
        // No `harden`: there is no credential in this file.
        return _writeIfChanged(
          endpointFile,
          storeHome,
          _spoolEndpointFileContents(
            agentId: descriptor.id,
            spool: _spoolDirectoryName,
          ),
        );
    }
  }

  /// Writes [contents] to [file] unless it already holds exactly that, and
  /// reports whether the bytes on disk are now [contents].
  Future<bool> _writeIfChanged(
    File file,
    String storeHome,
    String contents, {
    Future<void> Function(File staged)? harden,
  }) async {
    if (await file.exists()) {
      try {
        if (await file.readAsString() == contents) return true;
      } on FileSystemException {
        // Unreadable but present — rewritten below rather than trusted.
      }
    }
    if (!await Directory(storeHome).exists()) {
      // The agent is not installed in this environment, so there is nothing to
      // hook. Not created: the callback script lives *inside* the store home,
      // and creating it would leave an empty agent home in somebody's `~` for a
      // tool they never installed — a Mac with the Antigravity IDE but not its
      // CLI took that path and logged a `PathNotFoundException` at every start.
      return false;
    }
    final parent = file.parent;
    if (!await parent.exists()) {
      // The config need not live in the store home — `~/.gemini/config` sits
      // beside `~/.gemini/antigravity-cli` — so its directory can be missing.
      await parent.create(recursive: true);
    }
    await _writeAtomically(file, contents, harden: harden);
    try {
      return await file.readAsString() == contents;
    } on FileSystemException {
      return false;
    }
  }

  /// The endpoint file's body: the address and the token, and nothing else.
  ///
  /// `key=value` with `#` comments, which both `sh` and `cmd.exe` parse without
  /// spawning anything, and a corrupted or half-written file can only produce an
  /// empty `url` — which the script treats as "do nothing". Executing it instead
  /// (Orca's shape) would make it arbitrary code in somebody's home directory.
  /// [newline] is the environment's, not this process's.
  static String _httpEndpointFileContents({
    required String base,
    required String token,
    required String newline,
  }) => <String>[
    '# Karmashala agent status callback endpoint.',
    '#',
    '# Generated on every launch and deleted when the app exits. The script',
    '# beside this file reads it each time a hook fires, which is what lets the',
    '# command in your agent\'s own config stay a constant. Editing this file',
    '# changes nothing past the current launch.',
    'url=$base',
    'token=$token',
  ].map((line) => '$line$newline').join();

  /// The endpoint file for [AgentHookSpoolTransport]: a directory to write
  /// into, the agent's own id, and **no credential** — the absence of `url=`
  /// and `token=` is what the script reads to choose this transport, and a
  /// spooled payload has to name its own agent. Always LF; only a
  /// distribution's `sh` ever reads this form.
  static String _spoolEndpointFileContents({
    required String agentId,
    required String spool,
  }) => <String>[
    '# Karmashala agent status callback endpoint.',
    '#',
    '# Generated on every launch and deleted when the app exits. The script',
    '# beside this file reads it each time a hook fires, which is what lets the',
    '# command in your agent\'s own config stay a constant. Editing this file',
    '# changes nothing past the current launch.',
    '#',
    '# There is no token here and that is deliberate: this environment reports',
    '# by writing a file that Karmashala reads over the WSL share, so nothing',
    '# is sent over a network and there is no listener for an impostor to bind.',
    'spool=$spool',
    'agent=$agentId',
  ].map((line) => '$line\n').join();

  /// The `sh` body. `$1` is the hook event name, supplied by the command.
  ///
  /// **A constant.** Everything that changes between launches is read from the
  /// endpoint file at fire time, and its `spool=` or `url=`/`token=` also picks
  /// the transport. Nothing is sent until an unauthenticated probe answers
  /// `401`: an endpoint file survives an unclean exit, so the port it names may
  /// belong to somebody else by now, and ours is the only listener that answers
  /// `401` to an uncredentialed `GET /agent-hook`.
  ///
  /// Output goes to `/dev/null` — an agent reads a hook's stdout as a verdict on
  /// the user's tool call — and `exit 0` is forced, because Codex reads exit 2
  /// with non-empty stderr as a denial and `curl` exits 2 on an option it cannot
  /// parse. Both branches stop reading at [kAgentHookPayloadLimitBytes].
  ///
  /// `${0%/*}` rather than `dirname`, and `event` is saved before anything else
  /// because the cap below re-uses `$@`.
  static const String _posixScript =
      '#!/bin/sh\n'
      '# Karmashala agent status callback. Generated; edits will not survive.\n'
      '#\n'
      '# This file is a constant: where to report and how live in the endpoint\n'
      '# file beside it and are read here, every time a hook fires. A file\n'
      '# naming a spool directory is written to; one naming a url is posted to,\n'
      '# and then only once an unauthenticated probe proves the port still\n'
      '# belongs to Karmashala.\n'
      'event="\$1"\n'
      'here="\${0%/*}"\n'
      'endpoint="\$here/$_endpointFileName"\n'
      '[ -f "\$endpoint" ] || exit 0\n'
      "url=''\n"
      "token=''\n"
      "spool=''\n"
      "agent=''\n"
      'while IFS= read -r line; do\n'
      '  case "\$line" in\n'
      '    url=*) url="\${line#url=}" ;;\n'
      '    token=*) token="\${line#token=}" ;;\n'
      '    spool=*) spool="\${line#spool=}" ;;\n'
      '    agent=*) agent="\${line#agent=}" ;;\n'
      '  esac\n'
      'done < "\$endpoint"\n'
      'if [ -n "\$spool" ]; then\n'
      '  dir="\$here/\$spool"\n'
      '  [ -d "\$dir" ] || exit 0\n'
      '  set -- "\$dir"/*.json\n'
      '  [ "\$#" -lt 2000 ] || exit 0\n'
      '  n=0\n'
      '  while [ -e "\$dir/\$\$-\$n.json" ] || [ -e "\$dir/\$\$-\$n.part" ]; '
      'do\n'
      '    n=\$((n+1))\n'
      '    [ "\$n" -lt 64 ] || exit 0\n'
      '  done\n'
      "  { printf 'agent=%s\\nevent=%s\\n\\n' \"\$agent\" \"\$event\"; "
      'head -c $kAgentHookPayloadLimitBytes; } '
      '> "\$dir/\$\$-\$n.part" 2>/dev/null || exit 0\n'
      '  mv -f "\$dir/\$\$-\$n.part" "\$dir/\$\$-\$n.json" 2>/dev/null\n'
      '  exit 0\n'
      'fi\n'
      '[ -n "\$url" ] && [ -n "\$token" ] || exit 0\n'
      "code=\$(curl -s -o /dev/null -m 2 -w '%{http_code}' \"\$url\" "
      '2>/dev/null)\n'
      '[ "\$code" = "401" ] || exit 0\n'
      'head -c $kAgentHookPayloadLimitBytes '
      '| curl -s -o /dev/null -m 2 -X POST \\\n'
      '  -H "Authorization: Bearer \$token" \\\n'
      '  --data-binary @- \\\n'
      '  "\$url\$event" 2>/dev/null\n'
      'exit 0\n';

  /// The `cmd.exe` body. `%~1` is the hook event name, unquoted. CRLF
  /// throughout: a batch file with bare newlines is read by some Windows shells
  /// and not others. See [_posixScript] for the probe, the discarded output and
  /// the forced exit status.
  ///
  /// The probe's status code comes back through a `%TEMP%` file read with the
  /// `set /p` builtin, because `for /f %%c in ('curl …')` would spawn a second
  /// `cmd.exe` on every hook of every tool call. `cmd` has no byte-exact way to
  /// copy a stream at all — `more` re-encodes and expands tabs — so the payload
  /// bound is applied by **measuring rather than cutting**: `curl -T -` spills
  /// stdin to `%TEMP%`, `%%~zI` reads its size, and an oversized payload is
  /// dropped, which is what the receiver would do with it anyway. The spill sits
  /// after the 401 probe, so a dead port still costs exactly one process.
  ///
  /// `enabledelayedexpansion` is for the one line that substitutes `%20` into a
  /// space in `%TEMP%`, and is safe because every value here is one we
  /// generated — a base64url token and an encoded URL, neither holding a `!`.
  static const String _windowsScript =
      '@echo off\r\n'
      'rem Karmashala agent status callback. Generated; edits will not '
      'survive.\r\n'
      'rem\r\n'
      'rem This file is a constant: the address and the token live in the\r\n'
      'rem endpoint file beside it and are read here, every time a hook '
      'fires.\r\n'
      'rem Nothing is sent until an unauthenticated probe proves the port\r\n'
      'rem still belongs to Karmashala.\r\n'
      'setlocal enabledelayedexpansion\r\n'
      'set "KS_ENDPOINT=%~dp0$_endpointFileName"\r\n'
      'if not exist "%KS_ENDPOINT%" exit /b 0\r\n'
      'set "KS_URL="\r\n'
      'set "KS_TOKEN="\r\n'
      'for /f "usebackq eol=# tokens=1,* delims==" %%A in '
      '("%KS_ENDPOINT%") do (\r\n'
      '  if "%%A"=="url" set "KS_URL=%%B"\r\n'
      '  if "%%A"=="token" set "KS_TOKEN=%%B"\r\n'
      ')\r\n'
      'if not defined KS_URL exit /b 0\r\n'
      'if not defined KS_TOKEN exit /b 0\r\n'
      'set "KS_PROBE=%TEMP%\\$_scriptBaseName.%RANDOM%.code"\r\n'
      'set "KS_CODE="\r\n'
      'curl -s -o NUL -m 2 -w "%%{http_code}" "%KS_URL%" > "%KS_PROBE%" '
      '2>NUL\r\n'
      'set /p KS_CODE=<"%KS_PROBE%"\r\n'
      'del "%KS_PROBE%" >NUL 2>NUL\r\n'
      'if not "%KS_CODE%"=="401" exit /b 0\r\n'
      'set "KS_BODY=%TEMP%\\$_scriptBaseName.%RANDOM%.body"\r\n'
      'set "KS_BODYURL=!KS_BODY:\\=/!"\r\n'
      'set "KS_BODYURL=!KS_BODYURL: =%%20!"\r\n'
      'curl -s -T - "file:///!KS_BODYURL!" 2>NUL\r\n'
      'set "KS_SIZE="\r\n'
      'for %%I in ("%KS_BODY%") do set "KS_SIZE=%%~zI"\r\n'
      'if defined KS_SIZE if !KS_SIZE! LEQ $kAgentHookPayloadLimitBytes '
      'curl -s -o NUL -m 2 -X POST '
      '-H "Authorization: Bearer %KS_TOKEN%" '
      '--data-binary @"%KS_BODY%" "%KS_URL%%~1" 2>NUL\r\n'
      'del "%KS_BODY%" >NUL 2>NUL\r\n'
      'exit /b 0\r\n';

  /// Deletes every generated file under [storeHome] — both spellings of the
  /// script, and the endpoint file. Returns whether anything was removed. Both
  /// spellings, because a store can be reached from more than one side of a
  /// machine and the other extension would be left behind for ever.
  Future<bool> _removeGeneratedFiles(
    AgentDescriptor descriptor,
    String storeHome,
  ) async {
    var removed = await retireEndpoint(
      descriptor: descriptor,
      storeHome: storeHome,
    );
    for (final environment in EnvironmentKind.values) {
      final file = _callbackScriptFile(descriptor, storeHome, environment);
      if (file == null || !await file.exists()) continue;
      try {
        await file.delete();
        removed = true;
      } on FileSystemException {
        // Someone else's directory, and the config entry is already gone.
      }
    }
    return removed;
  }

  /// Where the generated script sits **as this app sees it**: in the store
  /// home, the same directory [_scriptCommand] names from inside the agent's own
  /// environment, since `CliStoreLocator` builds both from the same two
  /// variables. **The agent's config file has nothing to do with it** —
  /// Antigravity keeps its data in `~/.gemini/antigravity-cli` and reads
  /// `~/.gemini/config/hooks.json`. `null` for an agent that declares no store,
  /// which has nowhere of its own to keep a file.
  File? _callbackScriptFile(
    AgentDescriptor descriptor,
    String storeHome,
    EnvironmentKind environment,
  ) => descriptor.store == null
      ? null
      : File(p.join(storeHome, _scriptFileName(environment)));

  /// Where the endpoint file sits, as this app sees it. See
  /// [_callbackScriptFile] for why the store home is the right directory.
  File? _endpointFile(AgentDescriptor descriptor, String storeHome) =>
      descriptor.store == null
      ? null
      : File(p.join(storeHome, _endpointFileName));

  /// The config's raw text and its decoded root object, or a throw.
  ///
  /// Read again inside [_rewrite] rather than passed down, so the splice works
  /// on the bytes that are there *now* — this app wrote two files beside it in
  /// between. A missing or empty file reads as `{}`: an agent installed but
  /// never run has no config yet, and refusing it would refuse the case the
  /// feature is most useful in.
  Future<(String, Map<String, Object?>)> _readConfigObject(
    AgentDescriptor descriptor,
    String storeHome,
  ) async {
    final file = configFileFor(descriptor, storeHome)!;
    final raw = await file.exists() ? await file.readAsString() : '{}';
    final trimmed = raw.trim().isEmpty ? '{}' : raw;
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Agent config root is not a JSON object');
    }
    return (trimmed, decoded);
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
    final (trimmed, decoded) = await _readConfigObject(
      descriptor,
      storeHome,
    );
    final current = decoded[spec.configKey];
    final hooks = current is Map<String, Object?>
        ? Map<String, Object?>.from(current)
        : <String, Object?>{};

    // A block we left behind under an older name of this app. Dropped whether
    // or not [edit] changes anything; nothing else will ever recognise it.
    final abandoned = legacyAgentHookConfigKeys
        .where((key) => key != spec.configKey && decoded.containsKey(key))
        .toList();

    if (!edit(hooks) && abandoned.isEmpty) return false;

    // The config need not sit in the store home, so its directory can be one
    // the CLI has not created yet. Created only when the **store** is really
    // there, so a machine without this agent never gets an empty directory.
    final parent = file.parent;
    if (!await parent.exists() && await Directory(storeHome).exists()) {
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
  /// mid-write leaves an agent that will not start — and the window is wider
  /// across a `\\wsl.localhost` share. A failed rename changes nothing.
  Future<void> _writeAtomically(
    File file,
    String contents, {
    Future<void> Function(File staged)? harden,
  }) async {
    final staged = File('${file.path}.karmashala-tmp');
    // A previous run's litter, if the process ended between the write and the
    // rename. Removed rather than written over, so `harden` still applies its
    // ACL to a file this run created.
    await _removeStaged(staged);
    if (harden != null) {
      // The permission goes on the **empty** file, before the token is in it: a
      // credential is never written under an ACL that was not applied, not even
      // for the instant before a follow-up call.
      await staged.create(recursive: false);
      await harden(staged);
    }
    await staged.writeAsString(contents, flush: true);
    try {
      await replace(staged, file);
    } finally {
      // Never left behind, whichever way the move went.
      await _removeStaged(staged);
    }
  }

  /// Removes a staging file. Never throws: it is somebody else's directory, and
  /// both callers have something better to fail on. One call rather than
  /// exists-then-delete, which is two file operations on a possible UNC share.
  Future<void> _removeStaged(File staged) async {
    try {
      await staged.delete();
    } on FileSystemException {
      // Not there, or held by something; the next sweep tries again.
    }
  }

  /// The file [descriptor]'s hooks are configured in, or `null` when it has no
  /// hook spec.
  ///
  /// [AgentHookSpec.configFileName] is a path *relative to the store home* and
  /// can walk out of it — Antigravity stores data in `~/.gemini/antigravity-cli`
  /// and reads its sibling `~/.gemini/config/hooks.json` — so the `..` is
  /// resolved here rather than handed to a `\\wsl.localhost` UNC path.
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

  /// [entries] with our own entries removed. The list belongs to the user, and
  /// only the entries carrying [agentHookMarker] are ours to drop.
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
  /// Both styles are read regardless of what this agent's spec declares, so an
  /// entry written by an earlier build is still ours to take back out.
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

/// Move [staged] onto [destination], replacing it. Verified over
/// `\\wsl.localhost\<distro>\home\<user>` as well as local disk: the moved file
/// lands owned by the distribution's user with mode 644, which is what an agent
/// inside that distribution has to be able to read.
Future<void> _replaceFile(File staged, File destination) =>
    staged.rename(destination.path);

/// Closes [file] to every account on the machine but this one, where this
/// process can assert that from where it is running. Returns whether it was.
///
/// `icacls` for a Windows host writing a `windowsNative` store (granting owner,
/// `SYSTEM` and `Administrators` by SID, then stripping inheritance), `chmod
/// 600` for a POSIX host writing a `localPosix` one, and **nothing** for a
/// Windows host writing a WSL store: neither tool applies across a 9p share, so
/// that case reports `false` rather than papering over it.
///
/// A `false` is not fatal, unlike `mcp/handshake_file_permissions.dart`'s rule
/// this re-spells: the token here can only report a status, and the
/// `settings.json` it replaces carried the same token inline with no ACL.
Future<bool> restrictToOwner(File file, EnvironmentKind environment) async {
  try {
    if (Platform.isWindows) {
      if (environment != EnvironmentKind.windowsNative) return false;
      final env = Platform.environment;
      final user = env['USERNAME'];
      if (user == null || user.isEmpty) return false;
      final domain = env['USERDOMAIN'];
      final principal = (domain == null || domain.isEmpty)
          ? user
          : '$domain\\$user';
      // Grant first, strip inheritance second: `/inheritance:r` deletes
      // inherited ACEs outright, so the other order leaves a file its own owner
      // cannot open.
      final granted = await Process.run('icacls', [
        file.path,
        '/grant:r',
        '*S-1-5-18:(F)', // NT AUTHORITY\SYSTEM
        '*S-1-5-32-544:(F)', // BUILTIN\Administrators, and it is localised
        '$principal:(F)',
      ]);
      if (granted.exitCode != 0) return false;
      final stripped = await Process.run('icacls', [
        file.path,
        '/inheritance:r',
      ]);
      return stripped.exitCode == 0;
    }
    if (environment != EnvironmentKind.localPosix) return false;
    final result = await Process.run('chmod', ['600', file.path]);
    return result.exitCode == 0;
  } on Object {
    // A machine without `icacls` or `chmod`, or a path the tool will not
    // accept. The install goes on; see the doc for why that is not fatal.
    return false;
  }
}
