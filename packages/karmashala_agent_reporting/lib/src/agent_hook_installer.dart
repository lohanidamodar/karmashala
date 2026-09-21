import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_core/util.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/descriptors.dart';

/// Marks the hook entries Karmashala owns, so uninstall can remove exactly
/// those and leave the user's own hooks alone.
const String agentHookMarker = 'karmashala-agent-hook';

/// Markers this app wrote under names it no longer uses; an entry is identified
/// *only* by its marker, so these literals must survive any future rename.
const List<String> legacyAgentHookMarkers = <String>['chitragupta-agent-hook'];

/// Top-level config keys written under a former name: a rename abandons the old
/// block rather than moving it. Literals; see [legacyAgentHookMarkers].
const List<String> legacyAgentHookConfigKeys = <String>['chitragupta'];

/// The header an HTTP hook names its pane's `KARMASHALA_SESSION_ID` in; the
/// spool carries the same value as a `session=` line.
const String kPaneSessionHeader = 'X-Karmashala-Session';

/// Everything before the base64 in a Windows hook command.
const String _windowsHookPrefix =
    'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass '
    '-EncodedCommand ';

/// A Windows hook command that runs [script] in Windows PowerShell, spelled so
/// that **no shell can reinterpret it**: no quotes, no `%VAR%` or `$VAR`, and
/// no `/`-flag, only bare words and base64.
///
/// It has to be that neutral because the agent picks the shell, not us. Claude
/// Code runs a hook through Git Bash when Git Bash is installed and PowerShell
/// when it is not. The `cmd.exe /c "%USERPROFILE%\…"` this replaced was fine
/// under cmd, but Git Bash's MSYS path conversion rewrites `/c` to `C:/`, so
/// cmd started *interactively* and ran the hook's JSON payload from stdin as
/// command lines — every `=>` in a payload redirected into a stray file in the
/// working directory, and an `&` would have run whatever followed it.
///
/// The payload still arrives on the script's stdin under all three shells:
/// PowerShell does not read its own stdin for `-EncodedCommand`, so the child
/// inherits it untouched.
String windowsHookCommand(String script) {
  final utf16 = <int>[
    for (final unit in script.codeUnits) ...[unit & 0xff, unit >> 8],
  ];
  return '$_windowsHookPrefix${base64.encode(utf16)}';
}

/// The script inside a [windowsHookCommand], or null when [command] is not one.
String? decodeWindowsHookScript(String command) {
  if (!command.startsWith(_windowsHookPrefix)) return null;
  final List<int> bytes;
  try {
    bytes = base64.decode(command.substring(_windowsHookPrefix.length).trim());
  } on FormatException {
    return null;
  }
  if (bytes.length.isOdd) return null;
  return String.fromCharCodes([
    for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
  ]);
}

final _encodedWindowsHook = RegExp(
  '${RegExp.escape(_windowsHookPrefix)}[A-Za-z0-9+/]+=*',
);

/// [text] — a command, or a whole config file — with every Windows hook command
/// in it replaced by the script it runs. A search for the marker, a port or a
/// token has to read through this: against the base64 it would find nothing,
/// and "not found" would be the wrong answer.
String revealHookCommands(Object? text) => '$text'.replaceAllMapped(
  _encodedWindowsHook,
  (match) => decodeWindowsHookScript(match[0]!) ?? match[0]!,
);

/// Installs Karmashala's callbacks into an agent's own hook config: only the
/// hook value is spliced back, and nothing is `…Sync` (a WSL home is UNC).
class AgentHookInstaller {
  const AgentHookInstaller({
    this.replace = _replaceFile,
    this.restrict = restrictToOwner,
    this.beforeCommit,
    this.onWarning,
    this.checkForConcurrentSaves = true,
  });

  /// Whether a config rewrite stats the file before its read and again before
  /// its rename, retrying from a fresh read when the CLI saved in between. On
  /// by default; the app's install-cost suite pins the I/O call count with it
  /// on, so turning it off changes that count.
  final bool checkForConcurrentSaves;

  /// How staged content is moved onto the real config. Injectable because a
  /// rename cannot be made to fail on demand, and the guarantee needs a test.
  final Future<void> Function(File staged, File destination) replace;

  /// How the endpoint file is closed to other accounts, applied **before** the
  /// token is written into it. Injectable so a test need not spawn `icacls`.
  final Future<bool> Function(File file, EnvironmentKind environment) restrict;

  /// Runs after a config was read and spliced, before it is renamed over: the
  /// moment a concurrent save by the CLI can land. A test's seam, else null.
  final Future<void> Function(File config)? beforeCommit;

  /// Where a refusal that is not a fault is said — an ACL that did not apply.
  final void Function(String message)? onWarning;

  /// Splice attempts before a config that keeps changing under us is given up.
  static const int maxRewriteAttempts = 3;

  /// Whether this agent's store exists in [storeHome] at all — the one reason
  /// [install] can answer `false` that is not a fault.
  Future<bool> storeIsPresent(String storeHome) =>
      Directory(storeHome).exists();

  /// Writes one hook entry per declared event; returns whether the config **on
  /// disk** carries them, read back because a write can fail without raising.
  Future<bool> install({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) async {
    final spec = descriptor.hooks;
    if (spec == null) return false;
    if (!endpoint.reaches(environment)) return false;

    // Read the config **before** writing anything beside it: a store we cannot
    // edit is a store we wrote nothing into, not one holding a stray token.
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

  /// The declared events whose entry is on disk **right now** spelling this
  /// [endpoint]'s command. Read from the file, so a broken config answers none.
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
    // The script and the endpoint file go with them — that file is the only one
    // holding a bearer token. Removed whichever way the config edit went.
    if (await _removeGeneratedFiles(descriptor, storeHome)) changed = true;
    return changed;
  }

  /// Deletes the endpoint file and leaves the constant entry and script alone —
  /// rewriting those every launch is what lost the race to the CLI's own save.
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
    // The spool goes with it: it holds this launch's undelivered payloads, and
    // there is no launch any more.
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

  /// The command an agent runs for [event], or `null` when [environment] is
  /// unreachable. A constant: the address and token live in the endpoint file.
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

  /// The generated script's base name. It **is** [agentHookMarker], because an
  /// entry is recognised as ours only by the marker in its command.
  static const String _scriptBaseName = agentHookMarker;

  /// Where the script reads its address and token at fire time. One name for
  /// both platforms, in the store home — the one directory both sides can name.
  static const String _endpointFileName = '$_scriptBaseName.endpoint';

  /// Where a spooling agent drops its payloads. Volatile like the endpoint
  /// file, so [retireEndpoint] takes the whole directory with it.
  static const String _spoolDirectoryName = '$_scriptBaseName.spool';

  /// Where [descriptor]'s spooled payloads land, as this app sees them. Public
  /// so the drainer cannot spell a generated path a second way.
  Directory? spoolDirectoryFor(AgentDescriptor descriptor, String storeHome) =>
      descriptor.store == null
      ? null
      : Directory(p.join(storeHome, _spoolDirectoryName));

  /// The generated script's file name in [environment]. Both are named
  /// explicitly, so neither needs an execute bit a WSL share may not carry.
  static String _scriptFileName(EnvironmentKind environment) =>
      environment == EnvironmentKind.windowsNative
      ? '$_scriptBaseName.cmd'
      : '$_scriptBaseName.sh';

  /// The script, named through `%USERPROFILE%` / `$HOME` so one string is right
  /// in every environment, and interpreted by a named `cmd.exe` or `sh`.
  static String? _scriptCommand({
    required AgentDescriptor descriptor,
    required String event,
    required EnvironmentKind environment,
  }) {
    final store = descriptor.store;
    // A stable command needs a directory of its own, and the store home is the
    // only one this app can name from inside the agent's environment.
    if (store == null) return null;
    final file = _scriptFileName(environment);
    return switch (environment) {
      EnvironmentKind.windowsNative => windowsHookCommand(
        '& "\$env:USERPROFILE\\'
        '${store.homeDirectoryName.replaceAll('/', '\\')}\\$file" $event; '
        'exit \$LASTEXITCODE',
      ),
      EnvironmentKind.localPosix || EnvironmentKind.wsl =>
        'sh "\$HOME/${store.homeDirectoryName}/$file" $event',
      // Never reached: [AgentHookEndpoint.reaches] is false for SSH. Spelled
      // out so a new environment kind is a compile error, not a silent guess.
      EnvironmentKind.ssh => null,
    };
  }

  /// Writes the script and then the endpoint file — one with no script is a
  /// bearer token on disk that nothing will delete. Nothing here is logged.
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
        // Built by hand rather than with `Uri.replace`, which would escape the
        // `$event` / `%~1` standing in for the event.
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
          harden: (staged) => _harden(staged, environment),
        );
      case AgentHookSpoolTransport():
        // Made **before** the endpoint file that names it: the script exits
        // zero on a directory that is not there.
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

  /// The ACL verdict, carried rather than discarded. Where this platform can
  /// harden the store's environment, a refusal withholds the token file — the
  /// MCP side withholds its token on the same verdict; elsewhere it is a warning.
  Future<bool> _harden(File staged, EnvironmentKind environment) async {
    if (await restrict(staged, environment)) return true;
    final hardenable = Platform.isWindows
        ? environment == EnvironmentKind.windowsNative
        : environment == EnvironmentKind.localPosix;
    onWarning?.call(
      '${staged.path} could not be closed to other accounts'
      '${hardenable ? '' : ' (not this platform\'s to close)'}',
    );
    return !hardenable;
  }

  /// Writes [contents] to [file] unless it already holds exactly that, and
  /// reports whether the bytes on disk are now [contents].
  Future<bool> _writeIfChanged(
    File file,
    String storeHome,
    String contents, {
    Future<bool> Function(File staged)? harden,
  }) async {
    if (await file.exists()) {
      try {
        if (await file.readAsString() == contents) return true;
      } on FileSystemException {
        // Unreadable but present — rewritten below rather than trusted.
      }
    }
    if (!await Directory(storeHome).exists()) {
      // Not created: the callback script lives *inside* the store home, and
      // creating it leaves an empty home for a tool the user never installed.
      return false;
    }
    final parent = file.parent;
    if (!await parent.exists()) {
      // The config need not live in the store home — `~/.gemini/config` sits
      // beside `~/.gemini/antigravity-cli` — so its directory can be missing.
      await parent.create(recursive: true);
    }
    if (!await _writeAtomically(file, contents, harden: harden)) {
      // Refused: the file would have held a token under an ACL that did not
      // apply. Nothing is on disk; the install is reported as not done.
      onWarning?.call(
        '${file.path} was not written: it could not be closed to other '
        'accounts',
      );
      return false;
    }
    try {
      return await file.readAsString() == contents;
    } on FileSystemException {
      return false;
    }
  }

  /// The address and token as `key=value` lines both shells read without
  /// spawning anything; a half-written file can only yield an empty `url`.
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

  /// The spool form: a directory and the agent's id, and **no credential** —
  /// the absence of `url=`/`token=` is what selects it. Always LF.
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

  /// The `sh` body; `$1` is the event. Sends nothing until an unauthenticated
  /// probe answers `401`, discards stdout, and forces `exit 0` (2 means deny).
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
      '# The pane this agent was launched in, so a /clear is bound exactly.\n'
      'sid="\${KARMASHALA_SESSION_ID:-}"\n'
      "case \"\$sid\" in *[!A-Za-z0-9._-]*) sid='' ;; esac\n"
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
      "  { printf 'agent=%s\\nevent=%s\\nsession=%s\\n\\n' \"\$agent\" "
      '"\$event" "\$sid"; '
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
      '  -H "$kPaneSessionHeader: \$sid" \\\n'
      '  --data-binary @- \\\n'
      '  "\$url\$event" 2>/dev/null\n'
      'exit 0\n';

  /// The `cmd.exe` body, CRLF throughout. See [_posixScript]; `cmd` cannot copy
  /// a stream byte-exactly, so the payload bound is measured rather than cut.
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
      // Delayed, so a value is never parsed as cmd syntax; unset reads empty.
      '-H "$kPaneSessionHeader: !KARMASHALA_SESSION_ID!" '
      '--data-binary @"%KS_BODY%" "%KS_URL%%~1" 2>NUL\r\n'
      'del "%KS_BODY%" >NUL 2>NUL\r\n'
      'exit /b 0\r\n';

  /// Deletes every generated file under [storeHome]. Both script spellings,
  /// because a store can be reached from more than one side of a machine.
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

  /// Where the script sits as this app sees it: the store home, never the
  /// config's directory — Antigravity's differ. `null` for an agent with none.
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

  /// The config's text and decoded root, or a throw. Re-read inside [_rewrite]
  /// so the splice works on current bytes; a missing file reads as `{}`.
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
    // Read-splice-rename, retried from a fresh read when the CLI saved the
    // file in between: renaming over its save would throw that save away.
    final attempts = checkForConcurrentSaves ? maxRewriteAttempts : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final before = checkForConcurrentSaves ? await file.stat() : null;
      final (trimmed, decoded) = await _readConfigObject(descriptor, storeHome);
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

      // The config's directory can be one the CLI has not created yet. Made
      // only when the **store** is really there, so a stranger's `~` stays clean.
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
      await beforeCommit?.call(file);
      if (await _writeAtomically(file, updated, unlessChangedSince: before)) {
        return true;
      }
      onWarning?.call(
        '${file.path} changed while it was being edited; retrying',
      );
    }
    return false;
  }

  /// Stages [contents] beside [file] and renames it over: a plain write
  /// truncates first, so a kill mid-write leaves an agent that will not start.
  /// False when [harden] refused, or [file] no longer matches
  /// [unlessChangedSince]; nothing is written in either case.
  Future<bool> _writeAtomically(
    File file,
    String contents, {
    Future<bool> Function(File staged)? harden,
    FileStat? unlessChangedSince,
  }) async {
    final staged = File('${file.path}.karmashala-tmp');
    // A previous run's litter. Removed rather than written over, so `harden`
    // applies its ACL to a file this run created.
    await _removeStaged(staged);
    try {
      if (harden != null) {
        // The permission goes on the **empty** file, before the token is in
        // it: a credential is never written under an ACL that was not applied.
        await staged.create(recursive: false);
        if (!await harden(staged)) return false;
      }
      await staged.writeAsString(contents, flush: true);
      if (unlessChangedSince != null &&
          _changedSince(unlessChangedSince, await file.stat())) {
        return false;
      }
      await replace(staged, file);
      return true;
    } finally {
      // Never left behind, whichever way the move went — the token included.
      await _removeStaged(staged);
    }
  }

  static bool _changedSince(FileStat before, FileStat now) =>
      before.type != now.type ||
      before.size != now.size ||
      before.modified != now.modified;

  /// Removes a staging file. Never throws, and one call rather than
  /// exists-then-delete — two file operations on a possible UNC share.
  Future<void> _removeStaged(File staged) async {
    try {
      await staged.delete();
    } on FileSystemException {
      // Not there, or held by something; the next sweep tries again.
    }
  }

  /// The file [descriptor]'s hooks live in. [AgentHookSpec.configFileName] is
  /// relative to the store home and can walk out of it, so it is normalized.
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

  /// Whether [entries] already holds exactly one entry of ours spelling
  /// [command] — the case where installing again would write identical bytes.
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

  /// Ours if it carries the current marker **or** one we used to write — read
  /// through the encoding, since the Windows command carries its script in
  /// base64 and the marker is only visible once decoded.
  bool _isOurs(Object? entry) => _commandsIn(entry).any((command) {
    final text = decodeWindowsHookScript(command) ?? command;
    return text.contains(agentHookMarker) ||
        legacyAgentHookMarkers.any(text.contains);
  });

  /// Every command string an entry carries, in either shape: a config written
  /// by an earlier build is still ours to recognise and take back out.
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

/// Move [staged] onto [destination], replacing it. Verified across
/// `\\wsl.localhost` too: it lands owned by the distribution's user, mode 644.
Future<void> _replaceFile(File staged, File destination) =>
    staged.rename(destination.path);

/// Closes [file] to other accounts where this process can assert that, and says
/// whether it did — `false` across a WSL 9p share, which is not fatal.
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
      // inherited ACEs outright, so the other order locks out the owner.
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
