import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';

Future<void> main(List<String> args) async {
  exitCode = await runHostCli(args);
}
