import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../environments/environment_kind.dart';
import '../../environments/environment_path.dart';
import '../../environments/execution_environment.dart';
import '../../process/command_runner.dart';
import '../../process/path_translator.dart';
import '../../process/wsl_command_runner.dart';
import '../../util/json_file.dart';

/// Raised when an agent's auth file cannot be read or written where it lives.
///
/// The message is already the user's sentence: it names the environment and
/// the file, and never carries the file's content.
class AuthFileIoException implements Exception {
  AuthFileIoException(this.message);
  final String message;
  @override
  String toString() => 'AuthFileIoException: $message';
}

/// How an agent's credential and config files are reached.
///
/// Account switching used to open them with `dart:io` `File` unconditionally,
/// which is right for the Windows host and for WSL — whose files this host can
/// open through `\\wsl.localhost\…` — and meaningless for an SSH environment,
/// whose `~/.claude` is on somebody else's disk. The auth services depend on
/// this instead, and the locator that resolves the paths hands over the one
/// that can reach them.
abstract interface class AuthFileIo {
  /// [path] as a sentence names it: the bare path here, `<path> on <host>`
  /// for a file on another machine.
  String describe(String path);

  /// The file at [path] as a JSON object, or why there is none. Never throws.
  Future<JsonFileRead> readJsonObject(String path);

  /// The text at [path], or null when there is no such file.
  ///
  /// Throws [AuthFileIoException] when the file exists and cannot be read.
  Future<String?> readText(String path);

  /// Copies [path] to [backupPath] unless [backupPath] already exists or
  /// [path] does not. The first copy is the one worth keeping.
  Future<void> backupOnce(String path, String backupPath);

  /// Replaces [path] with [content] so that a reader sees the old file or the
  /// new one and never a truncated mixture.
  ///
  /// [secret] marks a file that holds tokens: it must end up readable by its
  /// owner alone. Throws [AuthFileIoException] when it cannot be written.
  Future<void> writeAtomic(String path, String content, {required bool secret});
}

/// The files are on the Windows host, opened with `dart:io`. Also the reader
/// half of [ShellWrittenAuthFileIo].
class LocalAuthFileIo implements AuthFileIo {
  const LocalAuthFileIo();

  @override
  String describe(String path) => path;

  static const _tmpSuffix = '.karmashala.tmp';

  @override
  Future<JsonFileRead> readJsonObject(String path) => readJsonObjectFile(path);

  @override
  Future<String?> readText(String path) async {
    final file = File(path);
    try {
      if (!await file.exists()) return null;
      return await file.readAsString();
    } on FileSystemException catch (e) {
      throw AuthFileIoException(
        'Could not read $path (${e.osError?.message ?? e.message}).',
      );
    }
  }

  @override
  Future<void> backupOnce(String path, String backupPath) async {
    final backup = File(backupPath);
    if (await backup.exists()) return;
    final original = File(path);
    if (await original.exists()) await original.copy(backup.path);
  }

  @override
  Future<void> writeAtomic(
    String path,
    String content, {
    required bool secret,
  }) async {
    final tmp = File('$path$_tmpSuffix');
    try {
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(path);
    } on FileSystemException catch (e) {
      if (await tmp.exists()) await tmp.delete();
      throw AuthFileIoException(
        'Could not write $path (${e.osError?.message ?? e.message}).',
      );
    }
  }
}

/// The files are on a POSIX machine reached by running commands there — an SSH
/// host, or the writer half of [ShellWrittenAuthFileIo]. Every operation is
/// one short `sh` script run through that environment's [CommandRunner].
///
/// Three rules hold for every write, because the file is an OAuth token bundle
/// on a machine other people may log in to:
///
/// * **The content travels on stdin, never on the command line.** An argument
///   is visible in the remote process list to every user of that host and can
///   land in a shell history. The only arguments are paths.
/// * **Temp file plus rename, in the same directory.** `mktemp` beside the
///   target, then `mv` over it: a rename within one directory is atomic, so a
///   connection that drops mid-write leaves the original untouched. The stdin
///   payload is framed by a header and a trailer line, and the rename only
///   happens when both arrived — so a stream cut short, or a remote shell
///   startup file that swallowed part of it, writes nothing.
/// * **Owner-only from creation.** `mktemp` creates the temp file mode 0600
///   under `umask 077`, so there is no moment at which the token is readable
///   by anyone else. A secret file keeps the owner bits of the file it
///   replaces with the group and other bits cleared; a new one is 0600.
class RemoteAuthFileIo implements AuthFileIo {
  RemoteAuthFileIo({required this.runner, required this.environmentName});

  final CommandRunner runner;

  /// What the user calls this environment, for the refusals.
  final String environmentName;

  @override
  String describe(String path) => '$path on $environmentName';

  /// Frames the stdin payload. A JSON document never contains either as a
  /// line of its own.
  static const header = 'KARMASHALA-AUTH-BEGIN';
  static const trailer = 'KARMASHALA-AUTH-END';

  /// Printed before a file's content, so anything a remote shell startup file
  /// prints ahead of the script is not taken for part of the file.
  static const readMarker = 'KARMASHALA-AUTH-FILE';

  static const _absent = 3;
  static const _notAFile = 4;
  static const _noDirectory = 3;
  static const _truncated = 9;

  static const _timeout = Duration(seconds: 60);

  /// `sh -c`, not `bash -lc`: nothing here needs a login profile, and a
  /// profile that reads stdin would eat the payload.
  static const readScript =
      'f=\$1\n'
      'if [ ! -e "\$f" ]; then exit $_absent; fi\n'
      'if [ ! -f "\$f" ]; then exit $_notAFile; fi\n'
      "printf '%s\\n' $readMarker\n"
      'exec cat -- "\$f"\n';

  static const backupScript =
      'set -eu\n'
      'target=\$1\n'
      'bak=\$2\n'
      'if [ -e "\$bak" ] || [ ! -e "\$target" ]; then exit 0; fi\n'
      'umask 077\n'
      'tmp=\$(mktemp "\$bak.XXXXXX")\n'
      "trap 'rm -f -- \"\$tmp\"' EXIT\n"
      "trap 'exit 1' HUP INT TERM\n"
      // Into the 0600 file mktemp made, so the copy is owner-only whatever
      // the original's mode.
      'cat -- "\$target" > "\$tmp"\n'
      'mv -f -- "\$tmp" "\$bak"\n'
      'trap - EXIT\n';

  static const writeScript =
      'set -eu\n'
      'target=\$1\n'
      'policy=\$2\n'
      // A symlinked dotfile is written through, not replaced by a copy.
      'if [ -L "\$target" ]; then target=\$(readlink -f -- "\$target"); fi\n'
      'dir=\$(dirname -- "\$target")\n'
      'if [ ! -d "\$dir" ]; then exit $_noDirectory; fi\n'
      'umask 077\n'
      'tmp=\$(mktemp "\$target.karmashala.XXXXXX")\n'
      "trap 'rm -f -- \"\$tmp\"' EXIT\n"
      "trap 'exit 1' HUP INT TERM\n"
      'awk -v h=$header -v t=$trailer '
      "'NR == 1 { if (\$0 != h) bad = 1; next } "
      'NR > 2 { print prev } { prev = \$0 } '
      "END { if (bad || NR < 2 || prev != t) exit $_truncated }' "
      '> "\$tmp"\n'
      'if [ -e "\$target" ]; then\n'
      '  mode=\$(stat -c %a -- "\$target" 2>/dev/null || '
      'stat -f %Lp -- "\$target")\n'
      '  if [ "\$policy" = secret ]; then\n'
      "    mode=\$(printf '%o' \$(( (0\$mode & 0700) | 0600 )))\n"
      '  fi\n'
      'else\n'
      '  mode=600\n'
      'fi\n'
      'chmod "\$mode" "\$tmp"\n'
      'mv -f -- "\$tmp" "\$target"\n'
      'trap - EXIT\n';

  /// The stdin a write sends: [content] between [header] and [trailer].
  static String framed(String content) =>
      '$header\n$content${content.endsWith('\n') ? '' : '\n'}$trailer\n';

  @override
  Future<JsonFileRead> readJsonObject(String path) async {
    final String? raw;
    try {
      raw = await readText(path);
    } on AuthFileIoException catch (e) {
      return JsonFileUnreadable(path, FileSystemException(e.message, path));
    }
    if (raw == null) return JsonFileAbsent(path);
    return jsonObjectReadOf(path, raw);
  }

  @override
  Future<String?> readText(String path) async {
    final result = await _run(readScript, [path], verb: 'read $path');
    if (result.exitCode == _absent) return null;
    if (result.exitCode == _notAFile) {
      throw AuthFileIoException(
        '$path on $environmentName is not a regular file.',
      );
    }
    if (!result.ok) {
      throw AuthFileIoException(
        'Could not read $path on $environmentName${_detail(result)}.',
      );
    }
    final out = result.stdout;
    final at = out.indexOf('$readMarker\n');
    if (at == -1) {
      throw AuthFileIoException(
        'Could not read $path on $environmentName: the remote shell did not '
        'return the file.',
      );
    }
    return out.substring(at + readMarker.length + 1);
  }

  @override
  Future<void> backupOnce(String path, String backupPath) async {
    final result = await _run(backupScript, [
      path,
      backupPath,
    ], verb: 'back up $path');
    if (!result.ok) {
      throw AuthFileIoException(
        'Could not back up $path on $environmentName${_detail(result)}, so '
        'nothing was changed.',
      );
    }
  }

  @override
  Future<void> writeAtomic(
    String path,
    String content, {
    required bool secret,
  }) async {
    final result = await _run(
      writeScript,
      [path, if (secret) 'secret' else 'keep'],
      stdin: framed(content),
      verb: 'write $path',
    );
    if (result.ok) return;
    throw AuthFileIoException(switch (result.exitCode) {
      _noDirectory =>
        '${p.posix.dirname(path)} does not exist on $environmentName, so '
            '$path cannot be written there.',
      _truncated =>
        'The connection to $environmentName did not deliver all of $path, so '
            'it was left as it was.',
      _ =>
        'Could not write $path on $environmentName${_detail(result)}; it was '
            'left as it was.',
    });
  }

  Future<CommandResult> _run(
    String script,
    List<String> arguments, {
    String? stdin,
    required String verb,
  }) async {
    try {
      return await runner.run(
        CommandRequest(
          executable: 'sh',
          // `sh` fills `$0`; the paths follow as `$1`, `$2`.
          arguments: ['-c', script, 'sh', ...arguments],
          stdinText: stdin,
          timeout: _timeout,
        ),
      );
    } on CommandException catch (e) {
      throw AuthFileIoException(
        'Could not reach $environmentName to $verb (${e.message}).',
      );
    }
  }

  static String _detail(CommandResult result) {
    final err = result.stderr.trim();
    return err.isEmpty ? ' (exit ${result.exitCode})' : ' ($err)';
  }
}

/// Files this host can read directly, written through a POSIX shell on the
/// machine that owns them: a WSL distribution, or a local macOS or Linux host.
///
/// Reads go through [LocalAuthFileIo], as they always did. Backups and writes
/// go through [RemoteAuthFileIo], because `dart:io` cannot create a file at
/// mode 0600, and through `\\wsl.localhost` it cannot set a POSIX mode at all.
/// [runnerPath] turns a path as this host spells it into the path the
/// runner's shell sees.
class ShellWrittenAuthFileIo implements AuthFileIo {
  ShellWrittenAuthFileIo({
    required CommandRunner runner,
    required String environmentName,
    required this.runnerPath,
  }) : writer = RemoteAuthFileIo(
         runner: runner,
         environmentName: environmentName,
       );

  final RemoteAuthFileIo writer;
  final String Function(String hostPath) runnerPath;

  static const _reader = LocalAuthFileIo();

  @override
  String describe(String path) => path;

  @override
  Future<JsonFileRead> readJsonObject(String path) =>
      _reader.readJsonObject(path);

  @override
  Future<String?> readText(String path) => _reader.readText(path);

  @override
  Future<void> backupOnce(String path, String backupPath) =>
      writer.backupOnce(_mapped(path), _mapped(backupPath));

  @override
  Future<void> writeAtomic(
    String path,
    String content, {
    required bool secret,
  }) => writer.writeAtomic(_mapped(path), content, secret: secret);

  String _mapped(String path) {
    try {
      return runnerPath(path);
    } on Object catch (e) {
      throw AuthFileIoException(
        'Could not write $path: no path for it inside '
        '${writer.environmentName} ($e).',
      );
    }
  }
}

/// The [AuthFileIo] for an auth file in a store `CliStoreLocator` reaches:
/// [environment] is the local host or a WSL distribution, and paths are
/// spelled the way this host opens them.
///
/// Windows keeps [LocalAuthFileIo]: NTFS has no POSIX mode, and a file under
/// the user's profile is already private to that user by its inherited ACL.
AuthFileIo storeAuthFileIo({
  required ExecutionEnvironment environment,
  required List<ExecutionEnvironment> environments,
  required CommandRunner Function(String environmentId) runnerFor,
  PathTranslator translator = const PathTranslator(),
}) {
  switch (environment.kind) {
    case EnvironmentKind.windowsNative:
      return const LocalAuthFileIo();
    case EnvironmentKind.ssh:
      return RefusingAuthFileIo(
        '${environment.name} is not a store this host opens directly.',
      );
    case EnvironmentKind.localPosix:
      return ShellWrittenAuthFileIo(
        runner: runnerFor(environment.id),
        environmentName: environment.name,
        runnerPath: (hostPath) => hostPath,
      );
    case EnvironmentKind.wsl:
      final distribution = environment.wslDistribution;
      final windows = environments
          .where((e) => e.kind == EnvironmentKind.windowsNative)
          .firstOrNull;
      if (distribution == null || windows == null) {
        return RefusingAuthFileIo(
          'Karmashala cannot run commands in ${environment.name}, so its '
          'credentials cannot be written safely.',
        );
      }
      return ShellWrittenAuthFileIo(
        runner: WslCommandRunner(
          environmentId: environment.id,
          distribution: distribution,
          exec: true,
        ),
        environmentName: environment.name,
        runnerPath: (hostPath) => translator
            .translate(
              EnvironmentPath(environmentId: windows.id, path: hostPath),
              from: windows,
              to: environment,
            )
            .path,
      );
  }
}

/// An environment whose files could not be located at all — the SSH host did
/// not answer the question of where its home is. Every read reports why, and
/// every write refuses with the same words, so the panel and the switch button
/// say the same thing instead of a silent "signed out".
class RefusingAuthFileIo implements AuthFileIo {
  const RefusingAuthFileIo(this.reason);

  final String reason;

  @override
  String describe(String path) => path;

  @override
  Future<JsonFileRead> readJsonObject(String path) async =>
      JsonFileUnreadable(path, FileSystemException(reason, path));

  @override
  Future<String?> readText(String path) async =>
      throw AuthFileIoException(reason);

  @override
  Future<void> backupOnce(String path, String backupPath) async =>
      throw AuthFileIoException(reason);

  @override
  Future<void> writeAtomic(
    String path,
    String content, {
    required bool secret,
  }) async => throw AuthFileIoException(reason);
}

/// Where the agent CLIs keep their files on a remote POSIX host, as that host
/// itself reports them.
class RemoteAgentHomes {
  const RemoteAgentHomes({
    required this.home,
    this.claudeConfigDir,
    this.codexHome,
  });

  /// The remote `$HOME`.
  final String home;

  /// `CLAUDE_CONFIG_DIR` on that host, when set.
  final String? claudeConfigDir;

  /// `CODEX_HOME` on that host, when set.
  final String? codexHome;

  /// The value of [name] on that host, when [remoteAgentHomesScript] asks for
  /// it and it is set there.
  String? variable(String name) => switch (name) {
    'CLAUDE_CONFIG_DIR' => claudeConfigDir,
    'CODEX_HOME' => codexHome,
    _ => null,
  };
}

/// The probe that asks a remote host for its home and the agents' overrides.
///
/// A login shell, because that is where a user exports `CLAUDE_CONFIG_DIR`,
/// and the same `bash -lc` discovery uses to find the CLIs themselves. Each
/// answer is on its own tagged line so a chatty profile cannot be mistaken for
/// one.
const remoteAgentHomesScript =
    r'printf "karmashala-home=%s\n" "$HOME"; '
    r'printf "karmashala-claude=%s\n" "${CLAUDE_CONFIG_DIR:-}"; '
    r'printf "karmashala-codex=%s\n" "${CODEX_HOME:-}"';

/// Asks [runner]'s host where its agent homes are.
///
/// Throws [AuthFileIoException], naming [environmentName], when the host
/// cannot be reached or gives no absolute home — never a guessed
/// `/home/<user>`.
Future<RemoteAgentHomes> resolveRemoteAgentHomes(
  CommandRunner runner, {
  required String environmentName,
}) async {
  final CommandResult result;
  try {
    result = await runner.run(
      const CommandRequest(
        executable: 'bash',
        arguments: ['-lc', remoteAgentHomesScript],
        timeout: kProbeTimeout,
      ),
    );
  } on CommandException catch (e) {
    throw AuthFileIoException(
      'Could not reach $environmentName to find its home directory '
      '(${e.message}).',
    );
  }
  String? tagged(String tag) {
    String? value;
    for (final line in const LineSplitter().convert(result.stdout)) {
      if (line.startsWith('$tag=')) value = line.substring(tag.length + 1);
    }
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String? absolute(String? path) {
    if (path == null || !path.startsWith('/')) return null;
    return path.length > 1 && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
  }

  final home = absolute(tagged('karmashala-home'));
  if (!result.ok || home == null) {
    throw AuthFileIoException(
      '$environmentName did not report a home directory, so its agent '
      'credentials cannot be located.',
    );
  }
  return RemoteAgentHomes(
    home: home,
    claudeConfigDir: absolute(tagged('karmashala-claude')),
    codexHome: absolute(tagged('karmashala-codex')),
  );
}
