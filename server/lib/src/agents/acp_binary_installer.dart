import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// **Installs an ACP agent the registry ships as a prebuilt archive** into
/// an environment's managed folder
/// (`~/karmashala/acp/<registry id>/<version>/`): downloads the archive with
/// what the machine has
/// (`curl` or `wget`; `Invoke-WebRequest` on Windows), checks it against the
/// registry's sha256 when one is given, unpacks it (`unzip` or `python3 -m
/// zipfile`, `tar`; `Expand-Archive` on Windows), marks the command
/// executable, and answers the executable's path there.
///
/// Every step is a script handed to the environment's shell on its stdin, so
/// nothing user-shaped is on a command line a WSL login shell would parse
/// first — and every value that reaches a script is checked to be plain.
class AcpBinaryInstaller {
  const AcpBinaryInstaller({
    required this.runnerFor,
    this.hostEnvironment = const {},
    this.timeout = const Duration(minutes: 20),
  });

  final CommandRunner Function(ExecutionEnvironment environment) runnerFor;

  /// The server's own variables: `USERPROFILE` names the Windows home.
  final Map<String, String> hostEnvironment;

  /// For each step; the archives run to hundreds of megabytes.
  final Duration timeout;

  /// Installs [request]'s archive into [environment]; [onStep] is told before
  /// the download and before the unpacking. Throws [DataRefused] in words.
  Future<String> install(
    ExecutionEnvironment environment,
    AcpAgentInstall request, {
    void Function(AcpInstallStep step)? onStep,
  }) async {
    if (environment.kind == EnvironmentKind.ssh) {
      throw const DataRefused.invalid(
        'Karmashala installs agents on this machine and in WSL, not over SSH.',
      );
    }
    final plan = _InstallPlan.of(
      environment.kind,
      request,
      hostEnvironment,
      timeout,
    );
    final CommandRunner runner;
    try {
      runner = runnerFor(environment);
    } on Object catch (error) {
      throw DataRefused.unavailable(
        '${environment.name} cannot be reached: $error',
      );
    }
    onStep?.call(AcpInstallStep.downloading);
    await _run(runner, plan.download(), 'The download failed');
    onStep?.call(AcpInstallStep.unpacking);
    final unpacked = await _run(runner, plan.unpack(), 'Unpacking failed');
    final path = _lastLine(unpacked.stdout);
    if (path == null) {
      throw const DataRefused(
        DataRefusalCode.failed,
        'Unpacking finished but the executable\'s path was not reported.',
      );
    }
    return path;
  }

  Future<CommandResult> _run(
    CommandRunner runner,
    CommandRequest request,
    String what,
  ) async {
    final CommandResult result;
    try {
      result = await runner.run(request);
    } on CommandException catch (error) {
      throw DataRefused(DataRefusalCode.failed, '$what: ${error.message}');
    }
    if (!result.ok) {
      final words = _lastLines(result.stderr, 3) ?? _lastLine(result.stdout);
      throw DataRefused(
        DataRefusalCode.failed,
        '$what (exit ${result.exitCode})${words == null ? '' : ': $words'}',
      );
    }
    return result;
  }

  String? _lastLine(String text) => _lastLines(text, 1);

  String? _lastLines(String text, int count) {
    final lines = [
      for (final line in text.split(RegExp(r'[\r\n]+')))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    if (lines.isEmpty) return null;
    return lines
        .skip(lines.length > count ? lines.length - count : 0)
        .join(' ');
  }
}

/// The scripts for one install, with every interpolated value checked.
class _InstallPlan {
  _InstallPlan._({
    required this.posix,
    required this.registryId,
    required this.version,
    required this.archiveUrl,
    required this.archiveName,
    required this.command,
    required this.sha256,
    required this.windowsHome,
    required this.timeout,
  });

  factory _InstallPlan.of(
    EnvironmentKind kind,
    AcpAgentInstall request,
    Map<String, String> hostEnvironment,
    Duration timeout,
  ) {
    final posix = isPosixShell(kind);
    final registryId = _plain(request.registryId, 'registry id');
    final version = _plain(request.version, 'version');
    final command = _commandPath(request.command);
    final url = Uri.tryParse(request.archive);
    // Printable ASCII only: PowerShell also ends a quoted string at the
    // typographic quotes.
    if (url == null ||
        !(url.scheme == 'https' || url.scheme == 'http') ||
        url.host.isEmpty ||
        RegExp(r'''[^\x21-\x7E]|['"`$\\]''').hasMatch(request.archive)) {
      throw DataRefused.invalid(
        'The registry\'s archive address is not one Karmashala will fetch: '
        '${request.archive}',
      );
    }
    // Decoded from the path, so `%24(...)` would arrive here as `$(...)`.
    final archiveName = url.pathSegments.lastOrNull ?? '';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(archiveName)) {
      throw DataRefused.invalid(
        'The registry\'s archive address does not end in a plain file name '
        'Karmashala will fetch: ${request.archive}',
      );
    }
    if (!_isArchive(archiveName)) {
      throw DataRefused.invalid(
        'Karmashala unpacks .zip, .tar.gz, .tgz and .tar.xz archives, not '
        '"$archiveName".',
      );
    }
    final sha = request.sha256?.trim().toLowerCase();
    if (sha != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw const DataRefused.invalid(
        'The registry\'s sha256 for this archive is not a checksum.',
      );
    }
    if (url.scheme == 'http' && sha == null) {
      throw const DataRefused.invalid(
        'The registry\'s archive address is plain http and it gives no '
        'checksum, so Karmashala will not fetch and run it.',
      );
    }
    String? windowsHome;
    if (!posix) {
      windowsHome = hostEnvironment['USERPROFILE']?.trim();
      if (windowsHome == null || windowsHome.isEmpty) {
        throw const DataRefused.unavailable(
          'USERPROFILE is not set, so there is no folder to install into.',
        );
      }
      if (RegExp("['‘-‛]").hasMatch(windowsHome)) {
        throw const DataRefused.invalid(
          'The profile folder\'s path holds a quote Karmashala cannot pass.',
        );
      }
    }
    return _InstallPlan._(
      posix: posix,
      registryId: registryId,
      version: version,
      archiveUrl: request.archive,
      archiveName: archiveName,
      command: command,
      sha256: sha,
      windowsHome: windowsHome,
      timeout: timeout,
    );
  }

  final bool posix;
  final String registryId;
  final String version;
  final String archiveUrl;
  final String archiveName;
  final String command;
  final String? sha256;
  final String? windowsHome;
  final Duration timeout;

  static String _plain(String value, String what) {
    final trimmed = value.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(trimmed)) {
      throw DataRefused.invalid('"$value" is not a $what Karmashala can use.');
    }
    return trimmed;
  }

  /// The registry spells a command `./agy_acp_server.par`; the archive's
  /// own layout is kept, the leading `./` is not.
  static String _commandPath(String command) {
    var path = command.trim();
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    if (path.isEmpty ||
        path.split('/').any((s) => s.isEmpty || s == '..') ||
        !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(path)) {
      throw DataRefused.invalid(
        '"$command" is not a command inside the archive Karmashala can run.',
      );
    }
    return path;
  }

  static bool _isArchive(String name) =>
      name.endsWith('.zip') ||
      name.endsWith('.tar.gz') ||
      name.endsWith('.tgz') ||
      name.endsWith('.tar.xz');

  CommandRequest download() => posix
      ? _bash('''
set -eu
dir="\$HOME/$kAcpManagedFolder/$registryId/$version"
mkdir -p "\$dir"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "\$dir/$archiveName" '$archiveUrl'
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "\$dir/$archiveName" '$archiveUrl'
else
  echo 'neither curl nor wget is installed' >&2
  exit 2
fi
''')
      : _powershell('''
\$ErrorActionPreference = 'Stop'
\$dir = Join-Path '$windowsHome' '${_windowsFolder()}'
New-Item -ItemType Directory -Force -Path \$dir | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri '$archiveUrl' -OutFile (Join-Path \$dir '$archiveName')
''');

  CommandRequest unpack() => posix
      ? _bash('''
set -eu
dir="\$HOME/$kAcpManagedFolder/$registryId/$version"
archive="\$dir/$archiveName"
${sha256 == null ? '' : '''
if command -v sha256sum >/dev/null 2>&1; then
  echo "$sha256  \$archive" | sha256sum -c - >/dev/null
else
  echo "$sha256  \$archive" | shasum -a 256 -c - >/dev/null
fi
'''}case "$archiveName" in
  *.zip)
    if command -v unzip >/dev/null 2>&1; then
      unzip -o -q "\$archive" -d "\$dir"
    elif command -v python3 >/dev/null 2>&1; then
      python3 -m zipfile -e "\$archive" "\$dir"
    else
      echo 'neither unzip nor python3 is installed' >&2
      exit 2
    fi
    ;;
  *.tar.gz|*.tgz) tar -xzf "\$archive" -C "\$dir" ;;
  *.tar.xz) tar -xJf "\$archive" -C "\$dir" ;;
esac
rm -f "\$archive"
chmod +x "\$dir/$command"
printf '%s\\n' "\$dir/$command"
''')
      : _powershell('''
\$ErrorActionPreference = 'Stop'
\$dir = Join-Path '$windowsHome' '${_windowsFolder()}'
\$archive = Join-Path \$dir '$archiveName'
${sha256 == null ? '' : '''
if ((Get-FileHash -Algorithm SHA256 -LiteralPath \$archive).Hash.ToLowerInvariant() -ne '$sha256') {
  throw 'The download does not match the checksum the registry gives.'
}
'''}${archiveName.endsWith('.zip') ? 'Expand-Archive -Force -LiteralPath \$archive -DestinationPath \$dir' : 'tar -xf \$archive -C \$dir'}
Remove-Item -Force \$archive
Write-Output (Join-Path \$dir '${command.replaceAll('/', r'\')}')
''');

  String _windowsFolder() =>
      acpManagedDirectory(EnvironmentKind.windowsNative, registryId, version);

  CommandRequest _bash(String script) => CommandRequest(
    executable: 'bash',
    arguments: const ['-ls'],
    stdinText: script,
    timeout: timeout,
  );

  CommandRequest _powershell(String script) => CommandRequest(
    executable: 'powershell.exe',
    arguments: const [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '-',
    ],
    stdinText: script,
    timeout: timeout,
  );
}
