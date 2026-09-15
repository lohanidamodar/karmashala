import 'dart:io';

import 'host_version.dart';
import 'protocol/messages.dart';
import 'pty/pty_probe.dart';
import 'serve/attach_command.dart';
import 'serve/client_command.dart';
import 'serve/serve_command.dart';

const _usage = '''
karmashala_host $kHostVersion — Karmashala's session host.

  karmashala_host serve         own sessions on this machine until told to stop
  karmashala_host attach        proxy stdio to the running host's socket
  karmashala_host list          what this machine's host is holding
  karmashala_host end <id>      end one session (see `list` for ids)
  karmashala_host stop          stop the host itself; --force takes sessions with it
  karmashala_host probe-pty     prove the pty layer works on this machine
  karmashala_host version       print the host and protocol versions
''';

Future<int> runHostCli(List<String> args, {IOSink? out, IOSink? err}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final command = args.isEmpty ? '' : args.first;
  switch (command) {
    case 'serve':
      return runServe(args.skip(1).toList(), out: sink, err: errSink);
    case 'attach':
      return runAttach(args.skip(1).toList(), output: sink, err: errSink);
    case 'list':
      return runList(out: sink, err: errSink);
    case 'end':
      return runEnd(args.skip(1).toList(), out: sink, err: errSink);
    case 'stop':
      return runStop(args.skip(1).toList(), out: sink, err: errSink);
    case 'probe-pty':
      return runPtyProbe(out: sink);
    case 'version':
      // Both numbers, because the deployer compares them separately: a host
      // can be new enough to run and still speak a protocol the app does not.
      sink.writeln('host $kHostVersion protocol $kProtocolVersion');
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
