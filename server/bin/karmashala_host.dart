import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';

Future<void> main(List<String> args) async {
  final code = await runHostCli(args);
  // A proxy that has finished must not wait for the event loop to drain: a
  // stdin nobody closes holds it open for ever, and one did for five days.
  //
  // Nor must a daemon that has shut down. `serve` returning is the end: what
  // is still open then — a client connection it never hung up, the process
  // worker isolate a checkpoint started, a pty reader — kept the VM alive
  // after SIGTERM until somebody sent SIGKILL (2026-09-25).
  if (args.isNotEmpty && (args.first == 'attach' || args.first == 'serve')) {
    exit(code);
  }
  exitCode = code;
}
