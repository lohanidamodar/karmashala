@Tags(['live'])
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

import 'companion_live_harness.dart';
import 'local_host_harness.dart';

/// A Karmashala server installed the way `server/deploy/install.sh` installs
/// one, end to end on this machine: the built bundle's `init` writes
/// `server.json`, `serve --standalone` creates its own store in a temporary
/// home with no app anywhere, the bundle's `pair` prints a code, and the
/// phone's own pairing client types that code at the server's listener — as
/// "Add machine" does — then connects with the pairing it stored.
void main() {
  test(
    'a standalone server pairs a phone from a code its CLI printed',
    () async {
      final home = temporaryHome('karmashala-standalone-live');
      final dataDir = '${home.path}/server';
      final environment = {'HOME': home.path, 'USERPROFILE': home.path};
      final bundle = await builtHost;

      final init = await Process.run(bundle, [
        'init',
        '--data-dir=$dataDir',
        '--name=Live server',
        '--bind=127.0.0.1',
      ], environment: environment);
      expect(init.exitCode, 0, reason: '${init.stdout}${init.stderr}');
      expect(
        File('$dataDir/server.json').statSync().mode & 0x1ff,
        0x180,
        reason: 'owner-only from the first byte',
      );

      final host = await LocalHost.start(
        home,
        serveArguments: [
          '--standalone',
          '--data-dir=$dataDir',
          '--companion-port=0',
          '--mcp-port=0',
        ],
      );
      addTearDown(host.kill);
      expect(host.greeting, contains('standalone server "Live server"'));
      expect(host.greeting, contains('store $dataDir/$kStoreFileName'));
      expect(host.greeting, contains('(bound to 127.0.0.1)'));
      final port = companionPortOf(host.greeting);

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
      final client = await phone.dial();
      addTearDown(client.close);
      final sessions = await client.listSessions();
      expect(sessions, isEmpty, reason: 'a fresh server runs nothing');

      final devices = await Process.run(bundle, [
        'devices',
      ], environment: environment);
      expect(devices.exitCode, 0, reason: '${devices.stderr}');
      expect('${devices.stdout}', contains('Live phone'));

      await host.kill();
      final db = AppDatabase.open(Directory(dataDir));
      addTearDown(db.close);
      expect(PairedDeviceDao(db).getActive().map((d) => d.name), [
        'Live phone',
      ]);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
