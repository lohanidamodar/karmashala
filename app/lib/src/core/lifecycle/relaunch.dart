import 'dart:io';

/// Starts this app again once this process has gone (slice 5e: switching the
/// machine a window is a client of starts it afresh, so nothing of the old
/// server — its panes, copies, links — outlives the switch). The new process
/// waits for this pid to exit, so the old one's ordered shutdown finishes
/// first and the two never run side by side.
Future<void> relaunchAfterExit() async {
  final executable = Platform.resolvedExecutable;
  final me = '$pid';
  if (Platform.isWindows) {
    await Process.start('powershell', [
      '-NoProfile',
      '-Command',
      'Wait-Process -Id $me -ErrorAction SilentlyContinue; '
          "Start-Process -FilePath '${executable.replaceAll("'", "''")}'",
    ], mode: ProcessStartMode.detached);
    return;
  }
  await Process.start('/bin/sh', [
    '-c',
    'while kill -0 "\$1" 2>/dev/null; do sleep 0.2; done; exec "\$2"',
    'relaunch',
    me,
    executable,
  ], mode: ProcessStartMode.detached);
}
