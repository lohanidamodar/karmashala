import 'dart:io';

import 'host_version.dart';
import 'pty/pty_probe.dart';

const _usage = '''
karmashala_host $kHostVersion — Karmashala's session host.

  karmashala_host probe-pty     prove the pty layer works on this machine
  karmashala_host version       print the host and protocol versions
''';

Future<int> runHostCli(List<String> args, {IOSink? out, IOSink? err}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final command = args.isEmpty ? '' : args.first;
  switch (command) {
    case 'probe-pty':
      return runPtyProbe(out: sink);
    case 'version':
      sink.writeln('host $kHostVersion');
      return 0;
    case '':
    case '-h':
    case '--help':
      sink.write(_usage);
      return args.isEmpty ? 2 : 0;
    default:
      errSink.writeln('karmashala_host: unknown command "$command"');
      errSink.write(_usage);
      return 2;
  }
}
