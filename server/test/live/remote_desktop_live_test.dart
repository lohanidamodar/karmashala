@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show HostDataLink;
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart' hide kProtocolVersion;
import 'package:test/test.dart';

import 'companion_live_harness.dart';
import 'local_host_harness.dart';

/// Slice 5e against a real `karmashala_host serve` (temp HOME, loopback,
/// ephemeral ports): a desktop client paired with `--grants desktop`
/// reaches it through its own relay, opens a real shell there over the
/// sealed link, and a second client on the server's socket watches the same
/// session — who types is told to both.
void main() {
  late Directory home;
  late LocalHost host;

  setUpAll(() async {
    home = temporaryHome('karmashala-remote-desktop-live');
    final dataDir = Directory('${home.path}/data');
    seedStore(dataDir);
    host = await LocalHost.start(
      home,
      serveArguments: [
        '--companion-port=0',
        '--mcp-port=0',
        '--data-dir=${dataDir.path}',
        '--local-relay',
        '--local-relay-port=0',
      ],
    );
    addTearDown(host.kill);
  });

  test('a desktop paired elsewhere drives a real shell over the relay, '
      'watched by a client on this machine', () async {
    final pairer = await AppLink.connect(host.socketPath);
    final payload = await pairer.pair(
      CapabilitySet.of([Capability.desktopClient]),
      atLocalRelay: true,
    );
    final store = InMemoryCompanionStore();
    final record = await CompanionPairingClient(
      store: store,
      deviceName: 'studio-mac',
    ).pair(payload);
    await pairer.close();
    expect(record.capabilities.has(Capability.desktopClient), isTrue);

    final sealed = await DesktopServerDialer(store: store).dial(record);
    final remote = await HostClientLink.open(
      SealedHostChannel(sealed),
      clientId: 'studio-mac',
    );
    addTearDown(remote.close);

    final data = HostDataLink.onLink(remote);
    final opened = (await data.send(
      const TerminalOpen(paneId: 'live5e', columns: 100, rows: 30),
    )).value;
    final attached = await remote.request<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: opened.sessionId,
        sinceOffset: 0,
        claimWrite: true,
      ),
      const Duration(seconds: 20),
    );
    final seen = StringBuffer();
    final presence = <PresenceMessage>[];
    remote.framesFor(attached.sessionRef).listen((frame) {
      if (frame is OutputMessage) {
        seen.write(String.fromCharCodes(frame.bytes));
        remote.send(OutputAckMessage(attached.sessionRef, frame.nextOffset));
      }
      if (frame is PresenceMessage) presence.add(frame);
    });

    final local = await HostClientLink.open(
      _SocketChannel(
        await Socket.connect(
          InternetAddress(host.socketPath, type: InternetAddressType.unix),
          0,
        ),
      ),
      clientId: 'this-mac',
    );
    addTearDown(local.close);
    final watching = await local.request<AttachedMessage>(
      (id) => AttachMessage(
        requestId: id,
        sessionId: opened.sessionId,
        sinceOffset: 0,
        claimWrite: false,
      ),
      const Duration(seconds: 20),
    );
    final alsoSeen = StringBuffer();
    local.framesFor(watching.sessionRef).listen((frame) {
      if (frame is OutputMessage) alsoSeen.write(String.fromCharCodes(frame.bytes));
    });

    remote.send(
      InputMessage(
        attached.sessionRef,
        Uint8List.fromList('echo ks5e-\$((6*7))\r'.codeUnits),
      ),
    );
    await _until(() => seen.toString().contains('ks5e-42'));
    await _until(() => alsoSeen.toString().contains('ks5e-42'));
    await _until(
      () => presence.any(
        (p) => p.holder == 'studio-mac' && p.viewers.contains('this-mac'),
      ),
    );
    await data.send(TerminalClose(opened.sessionId));
    await data.close();
  });
}

/// The server's unix socket as a byte channel.
class _SocketChannel implements RemoteChannel {
  _SocketChannel(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stdout => _socket;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void add(Uint8List bytes) => _socket.add(bytes);

  @override
  Future<int> get exitCode => _socket.done.then((_) => 0);

  @override
  Future<void> close() async => _socket.destroy();
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('never became true');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
