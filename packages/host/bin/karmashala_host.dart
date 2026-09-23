import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';

Future<void> main(List<String> args) async {
  final code = await runHostCli(args);
  // A proxy that has finished must not wait for the event loop to drain: a
  // stdin nobody closes holds it open for ever, and one did for five days.
  if (args.isNotEmpty && args.first == 'attach') exit(code);
  exitCode = code;
}
