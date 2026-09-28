import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/server/machine_pairing.dart';
import 'package:karmashala/src/core/server/machines.dart';
import 'package:karmashala/src/core/server/remote_server_access.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show MemoryPairedDeviceStore, RemoteHostService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/host.dart' show RemoteHostBindings;
import 'package:karmashala_remote/pairing.dart' show PairingCode;
import 'package:karmashala_remote/remote.dart'
    show Capability, CapabilitySet, DeviceId;
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';

/// This app as the client of a server on another machine (slice 5e), the
/// other machine played in-process on loopback — its companion service over
/// an in-memory device store, its host server over fake PTYs, no database:
/// "Add a machine" with the code `pair --grants desktop` prints, the list in
/// its owner-only file in app support, then a pane over the sealed link.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late RemoteHostService service;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ks-machines-');
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    final server = HostServer(registry: registry, ptyLibrary: 'libc.so.6');
    service = RemoteHostService(
      devices: MemoryPairedDeviceStore(),
      hostId: DeviceId.generate(),
      bindings: _bindings('droplet'),
      relay: null,
      lanAddress: '127.0.0.1',
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      onHostLink: (link) {
        final connection = SealedHostConnection(link);
        unawaited(server.serveConnection(connection, trust: connection.trust));
      },
    );
    await service.start();
  });

  tearDown(() async {
    for (final pty in launcher.handles) {
      pty.finish(0);
    }
    await service.stop();
    await registry.shutdown();
    tmp.deleteSync(recursive: true);
  });

  String address() => '127.0.0.1:${service.lanPortBound}';

  Future<String> openWindow(CapabilitySet grants) async {
    final session = await service.beginPairing(capabilities: grants);
    // A window nobody pairs through is cancelled at teardown.
    session.done.ignore();
    return PairingCode.encode(session.payload.typedSecret!);
  }

  test('Add a machine with a desktop code, then a pane on it over the sealed '
      'link', () async {
    final machines = Machines(MachinesFileStore.inDirectory(tmp.path));
    final record = await pairWithMachine(
      store: machines.store,
      code: await openWindow(CapabilitySet.of([Capability.desktopClient])),
      address: address(),
    );
    expect(record.hostName, 'droplet');
    expect(record.directEndpoint, address());
    expect((await machines.remote()).single.hostId, record.hostId);

    await machines.use(record.hostId.value);
    final chosen = (await machines.active())!;
    final access = RemoteServerAccess(
      hostId: chosen.hostId.value,
      hostName: chosen.hostName,
      store: machines.store,
    );

    registry.open('karmashala_local_p1', const PtySpawnRequest(argv: ['sh']));
    final pane = HostTerminalInstance(
      id: 'p1',
      title: 'Remote',
      profileId: 'sh',
      access: access,
      sessionId: 'karmashala_local_p1',
    );
    addTearDown(pane.dispose);
    pane.terminal.resize(80, 24);
    await _until(() => pane.outlivesApp);
    launcher.handles.single.emit('from the droplet\r\n'.codeUnits);
    await _until(
      () => terminalTailLines(
        pane.terminal,
        lines: 10,
      ).any((line) => line.contains('from the droplet')),
    );

    // Keys typed here reach the process there.
    pane.terminal.textInput('ls');
    await _until(() => launcher.handles.single.writes.isNotEmpty);
    expect(String.fromCharCodes(launcher.handles.single.writes.last), 'ls');
  });

  test('a phone\'s code is refused and not kept', () async {
    final machines = Machines(MachinesFileStore.inDirectory(tmp.path));
    await expectLater(
      pairWithMachine(
        store: machines.store,
        code: await openWindow(CapabilitySet.all),
        address: address(),
      ),
      throwsA(
        isA<CompanionPairingException>().having(
          (e) => e.message,
          'message',
          contains('--grants desktop'),
        ),
      ),
    );
    expect(await machines.remote(), isEmpty);
  });

  test('a typed code with no address, and junk, are refused in words',
      () async {
    final machines = Machines(MachinesFileStore.inDirectory(tmp.path));
    await expectLater(
      pairWithMachine(
        store: machines.store,
        code: PairingCode.encode(List<int>.filled(20, 7)),
      ),
      throwsA(isA<CompanionPairingException>()),
    );
    await expectLater(
      pairWithMachine(store: machines.store, code: 'hello'),
      throwsA(isA<CompanionPairingException>()),
    );
  });

  test('the list: this computer by default, a chosen one, and forgetting '
      'the one in use falls back to this computer', () async {
    final machines = Machines(MachinesFileStore.inDirectory(tmp.path));
    expect(await machines.active(), isNull);
    final record = await pairWithMachine(
      store: machines.store,
      code: await openWindow(CapabilitySet.of([Capability.desktopClient])),
      address: address(),
    );
    await machines.use(record.hostId.value);
    expect((await machines.active())!.hostName, 'droplet');
    // Kept in a file only this user can read: it holds the device key.
    if (!Platform.isWindows) {
      final mode = File('${tmp.path}/machines.json').statSync().modeString();
      expect(mode, 'rw-------');
    }
    await machines.forget(record.hostId.value);
    expect(await machines.active(), isNull);
    expect(await machines.remote(), isEmpty);
  });
}

/// A companion that serves no phone call: a desktop client needs only its
/// name and the switch to the host protocol.
RemoteHostBindings _bindings(String name) => RemoteHostBindings(
  hostName: name,
  listSessions: () => const [],
  sessionById: (_) => null,
  deliveryStageFor: (_) async => null,
  transcriptFor: (_) => throw UnimplementedError(),
  sendPrompt: (_, _, {attachment}) => throw UnimplementedError(),
  answerApproval: (_, _) => throw UnimplementedError(),
  approvalEvidenceFor: (_) => throw UnimplementedError(),
  registerPush: (_, _, _, _) async {},
  listWorkspace: () => const [],
  listProjects: () => const [],
  startSession: (_) => throw UnimplementedError(),
  addProject: (_, _) => throw UnimplementedError(),
  resumeSession: (_) => throw UnimplementedError(),
  beginAttachment: (_, _) => throw UnimplementedError(),
  writeAttachmentChunk: (_, _, _, _) => throw UnimplementedError(),
  discardAttachment: (_) async {},
);

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('never became true');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
