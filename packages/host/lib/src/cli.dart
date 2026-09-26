import 'dart:io';

import 'host_version.dart';
import 'protocol/messages.dart';
import 'pty/pty_exec.dart';
import 'pty/pty_probe.dart';
import 'relay/relay_command.dart';
import 'serve/attach_command.dart';
import 'serve/client_command.dart';
import 'serve/serve_command.dart';
import 'server/admin_commands.dart';
import 'server/init_command.dart';
import 'server/pair_command.dart';
import 'store/store_probe.dart';

const _usage =
    '''
karmashala_host $kHostVersion — Karmashala's session host.

  karmashala_host serve         own sessions on this machine until told to stop
                                --data-dir=<dir>: the store is
                                  <dir>/karmashala.sqlite and the config
                                  <dir>/server.json (required unless
                                  --standalone)
                                --standalone: a server on its own — data in
                                  ~/.karmashala unless --data-dir says, phone
                                  listener on loopback unless --bind says,
                                  agent CLIs found at start
                                --name=<n> --bind=<ip> --companion-port=<n>
                                --relay=<url> --relay-token=<t>
                                --extra-relay=<url> --[no-]beacon --no-notes
                                --no-companion --mcp-port=<n>: override
                                  server.json, field by field
  karmashala_host init          write server.json from the flags above;
                                  --force replaces one that is there
  karmashala_host pair          open a pairing window and print its code and QR
                                --capabilities=<list|all> --relay=<url>
                                --name=<label> --address=<host[:port]>
  karmashala_host devices       the phones paired with this server
  karmashala_host revoke <id>   revoke one (see `devices` for ids)
  karmashala_host agents        the agent CLIs this server found; --refresh
                                  probes again
  karmashala_host attach        proxy stdio to the running host's socket
  karmashala_host list          what this machine's host is holding
  karmashala_host end <id>      end one session (see `list` for ids)
  karmashala_host stop          stop the host itself; --force takes sessions with it
  karmashala_host relay         be the relay for one desktop; `relay --help` for flags
  karmashala_host probe-pty     prove the pty layer works on this machine
  karmashala_host probe-store   prove this machine can hold a store
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
    case 'relay':
      return runRelay(args.skip(1).toList(), out: sink, err: errSink);
    case 'init':
      return runInit(args.skip(1).toList(), out: sink, err: errSink);
    case 'pair':
      return runPair(args.skip(1).toList(), out: sink, err: errSink);
    case 'devices':
      return runDevices(args.skip(1).toList(), out: sink, err: errSink);
    case 'revoke':
      return runRevoke(args.skip(1).toList(), out: sink, err: errSink);
    case 'agents':
      return runAgents(args.skip(1).toList(), out: sink, err: errSink);
    case 'probe-pty':
      return runPtyProbe(out: sink);
    case 'probe-store':
      return runStoreProbe(out: sink);
    case 'pty-exec':
      // Not in the usage: the host starts it, nobody else has a reason to.
      return runPtyExec(args.skip(1).toList());
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
