@Tags(['live'])
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart'
    show HostClient, ServerConfig, ServerMethod;
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

import 'companion_live_harness.dart';
import 'local_host_harness.dart';

/// A Karmashala server as every machine now runs one — one way, one data
/// folder per user — end to end on this machine, in a temporary HOME so its
/// default folder is a temporary `~/.karmashala`: the built bundle's `init`
/// writes `server.json` there, `serve` with no `--data-dir` creates and
/// migrates its store there, the bundle's `pair` prints a code, and the
/// phone's own pairing client types that code at the server's listener — as
/// "Add machine" does — then connects with the pairing it stored. Then the
/// config changes over `server.config.set`, as the desktop's Remote access
/// settings change it, and the listener follows with no restart.
void main() {
  test('a server in its default folder pairs a phone from a code its CLI '
      'printed, and its listener follows a config change', () async {
    final home = temporaryHome('karmashala-server-live');
    final dataDir = '${home.path}/.karmashala';
    final environment = {'HOME': home.path, 'USERPROFILE': home.path};
    final bundle = await builtHost;

    final init = await Process.run(bundle, [
      'init',
      '--name=Live server',
      '--companion',
      '--bind=127.0.0.1',
      '--companion-port=0',
      '--mcp-port=0',
    ], environment: environment);
    expect(init.exitCode, 0, reason: '${init.stdout}${init.stderr}');
    expect(init.stdout, contains('wrote $dataDir/server.json'));
    expect(
      File('$dataDir/server.json').statSync().mode & 0x1ff,
      0x180,
      reason: 'owner-only from the first byte',
    );

    // No flag at all: the folder is the default, the ports the file's.
    final host = await LocalHost.start(home, serveArguments: const []);
    addTearDown(host.kill);
    expect(host.greeting, contains('server "Live server", data in $dataDir'));
    expect(host.greeting, contains('store $dataDir/$kStoreFileName'));
    expect(host.greeting, contains('(bound to 127.0.0.1)'));
    final port = companionPortOf(host.greeting);
    expect(port, isNot(kHostCompanionPort));

    // `pair`, as a person on the server types it.
    final pair = await Process.start(bundle, [
      'pair',
      '--name=Live phone',
      '--address=server.example.com',
      '--no-color',
    ], environment: environment);
    final said = StringBuffer();
    final waiting = Completer<void>();
    pair.stdout.transform(utf8.decoder).listen((text) {
      said.write(text);
      if (said.toString().contains('Waiting for a device') &&
          !waiting.isCompleted) {
        waiting.complete();
      }
    });
    pair.stderr.transform(utf8.decoder).listen(said.write);
    await Future.any([
      waiting.future,
      pair.exitCode.then((code) => fail('pair exited $code:\n$said')),
    ]).timeout(const Duration(seconds: 30));

    final printed = said.toString();
    final code = RegExp(r'Code:\s+(\S+)').firstMatch(printed)!.group(1)!;
    final lines = printed.split('\n');
    final invite = HostPairingInvite.decode(
      lines[lines.indexWhere((l) => l.startsWith('Payload')) + 1],
    );
    expect(invite.endpoint, 'server.example.com:$port');
    expect(invite.hostName, 'Live server');
    expect(invite.code, code);
    expect(printed, contains('█'), reason: 'the QR, in half blocks');

    // The phone: its own pairing client, the typed code, the listener.
    final phone = LoopbackPhone(port, name: 'Phone says');
    final transport = LanTransport(host: '127.0.0.1', port: port)..start();
    final paired =
        await CompanionPairingClient(
          store: phone.store,
          deviceName: phone.name,
        ).pairWithTypedCode(
          codeSecret: PairingCode.tryDecode(code)!,
          relay: Uri.parse('https://invalid.local'),
          transport: transport,
        );
    await transport.close();
    phone.pairing = paired;
    expect(paired.capabilities, CapabilitySet.all);

    expect(
      await pair.exitCode.timeout(const Duration(seconds: 20)),
      0,
      reason: said.toString(),
    );
    expect(said.toString(), contains('Paired: Live phone ('));

    // The pairing works: a sealed session, and the server's own answer.
    final first = await phone.dial();
    expect(await first.listSessions(), isEmpty, reason: 'runs nothing yet');
    await first.close();

    // The desktop's Remote access switch, over the owner-only socket: off
    // closes the listener at once, and the file says so.
    final admin = (await HostClient.connect(host.socketPath))!;
    addTearDown(admin.close);
    Future<Map<String, Object?>> served() async =>
        (await admin.call(ServerMethod.serverInfo))['companion']!
            as Map<String, Object?>;
    await admin.call(
      ServerMethod.configSet,
      arguments: {
        'patch': {
          'companion': {'enabled': false},
        },
      },
    );
    expect((await served())['serving'], isFalse);
    await expectLater(
      Socket.connect('127.0.0.1', port),
      throwsA(isA<SocketException>()),
      reason: 'nothing listens where it did',
    );
    final off = await ServerConfig.read(dataDir);
    expect(off.companionEnabled, isFalse);
    expect(off.name, 'Live server', reason: 'the rest of the file kept');

    // On again: a listener, found where the server says, and the phone's
    // pairing still opens a sealed session there — same store, same host
    // id, no re-pair.
    await admin.call(
      ServerMethod.configSet,
      arguments: {
        'patch': {
          'companion': {'enabled': true},
        },
      },
    );
    final back = await served();
    expect(back['serving'], isTrue);
    phone.port = back['port']! as int;
    final again = await phone.dial();
    addTearDown(again.close);
    expect(await again.listSessions(), isEmpty);

    final devices = await Process.run(bundle, [
      'devices',
    ], environment: environment);
    expect(devices.exitCode, 0, reason: '${devices.stderr}');
    expect('${devices.stdout}', contains('Live phone'));

    await host.kill();
    final db = AppDatabase.open(Directory(dataDir));
    addTearDown(db.close);
    expect(PairedDeviceDao(db).getActive().map((d) => d.name), ['Live phone']);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
