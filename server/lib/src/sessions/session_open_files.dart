import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_launch/karmashala_launch.dart'
    show kSessionIdEnvironmentVariable;

import '../terminals/linux_running.dart' show LinuxShell, wslShell;

/// The transcript files ([kTranscriptSuffix]) each of [sessionIds]' processes
/// holds open on [environment], by session id: what its agent is writing now.
/// Null when this server cannot look inside that machine.
typedef SessionOpenFiles =
    Future<Map<String, Set<String>>>? Function(
      ExecutionEnvironment environment,
      Set<String> sessionIds,
    );

/// What a transcript is called. Codex's rollouts and Claude Code's sessions
/// both end in it.
const String kTranscriptSuffix = '.jsonl';

/// The shape a session id must have to be put in a script: what the app
/// stamps is a UUID.
final RegExp _sessionIdShape = RegExp(r'^[A-Za-z0-9._-]{1,128}$');

/// One `sh` that finds every process whose environment names one of
/// [sessionIds] and prints `<session id> <path>` for each transcript it holds
/// open. One `grep` over every `environ`, and one `ls` per process it names.
String sessionOpenFilesScript(Set<String> sessionIds) {
  final wanted = [
    for (final id in sessionIds)
      if (_sessionIdShape.hasMatch(id)) id,
  ];
  return '''
export LC_ALL=C
wanted=" ${wanted.join(' ')} "
printf 'a\\0' | grep -qaz a 2>/dev/null || exit 0
grep -aHoz '^$kSessionIdEnvironmentVariable=[^[:cntrl:]]*' /proc/[0-9]*/environ 2>/dev/null | tr '\\0' '\\n' |
while IFS= read -r line; do
  pid=\${line#/proc/}; pid=\${pid%%/*}
  sid=\${line#*:$kSessionIdEnvironmentVariable=}
  case "\$wanted" in *" \$sid "*) ;; *) continue ;; esac
  ls -l "/proc/\$pid/fd" 2>/dev/null | sed -n "s|.* -> \\(.*\\$kTranscriptSuffix\\)\$|\$sid \\1|p"
done
''';
}

/// [sessionOpenFilesScript]'s output, by session id.
Map<String, Set<String>> parseSessionOpenFiles(String output) {
  final open = <String, Set<String>>{};
  for (final line in const LineSplitter().convert(output)) {
    final space = line.indexOf(' ');
    if (space <= 0) continue;
    final path = line.substring(space + 1).trim();
    if (!path.endsWith(kTranscriptSuffix)) continue;
    open.putIfAbsent(line.substring(0, space), () => {}).add(path);
  }
  return open;
}

/// The last segment of [path], in either spelling: a WSL store's files are
/// `\\wsl.localhost\…` here and `/home/…` inside.
String transcriptFileName(String path) {
  final cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

/// The machine's own processes: WSL from Windows, and this machine when it is
/// Linux. SSH boxes and Windows have no `/proc` to read here.
SessionOpenFiles sessionOpenFilesOnThisMachine({
  bool? windows,
  bool? linux,
  LinuxShell Function(String? distribution) wsl = wslShell,
  LinuxShell local = _localShell,
}) {
  final onWindows = windows ?? Platform.isWindows;
  final onLinux = linux ?? Platform.isLinux;
  return (environment, sessionIds) {
    final LinuxShell run;
    if (environment.kind == EnvironmentKind.wsl && onWindows) {
      run = wsl(environment.wslDistribution);
    } else if (environment.kind == EnvironmentKind.localPosix && onLinux) {
      run = local;
    } else {
      return null;
    }
    return run(sessionOpenFilesScript(sessionIds)).then(parseSessionOpenFiles);
  };
}

Future<String> _localShell(String script) async {
  final process = await Process.start('sh', ['-s']);
  final out = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final err = process.stderr.drain<void>();
  process.stdin.write(script);
  await process.stdin.close();
  try {
    await process.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    out.ignore();
    err.ignore();
    rethrow;
  }
  await err;
  return out;
}
