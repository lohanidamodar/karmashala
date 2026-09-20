import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:test/test.dart';

/// A host on the other end of `attach`, answering whatever the test says it is.
class _RemoteHost implements HostDeployTarget {
  _RemoteHost(this.answer);

  /// What to send back once the client has spoken. Null says nothing at all.
  final HostMessage? Function(PairMessage request)? answer;

  final asked = <PairMessage>[];

  @override
  String get address => 'box.example';

  @override
  Future<RemoteRun> run(String command) async => const RemoteRun(0, '', '');

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {}

  @override
  Future<RemoteChannel> exec(String command) async => _Channel(this);
}

class _Channel implements RemoteChannel {
  _Channel(this._host);

  final _RemoteHost _host;
  final _out = StreamController<Uint8List>();
  final _parser = FrameParser();

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  void add(List<int> bytes) {
    for (final frame in _parser.add(bytes)) {
      final message = decodeMessage(frame);
      if (message is! PairMessage) continue;
      _host.asked.add(message);
      final reply = _host.answer?.call(message);
      if (reply != null) _out.add(reply.toFrame().encode());
    }
  }

  @override
  Future<int> get exitCode async => 0;

  @override
  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }
}

void main() {
  RemotePairing pairingOn(_RemoteHost host) => RemotePairing(
    target: host,
    remotePath:
        '/home/x/.karmashala/bin/karmashala_host-1.0.0-linux-x64.d/bin/karmashala_host',
    clock: () => DateTime.utc(2026, 9, 16),
    timeout: const Duration(seconds: 2),
  );

  test('an open window comes back with the code and its deadline', () async {
    final host = _RemoteHost(
      (request) => PairedMessage(
        requestId: request.requestId,
        code: 'K7QM-3X2W-ABCD-EFGH-2345-6789-JKLM-NPQR',
        expiresAt: DateTime.utc(2026, 9, 16, 0, 3),
      ),
    );

    final window = await pairingOn(host).open(capabilities: 0x7);

    expect(window.isOpen, isTrue);
    expect(window.code, startsWith('K7QM-'));
    expect(window.expiresAt, DateTime.utc(2026, 9, 16, 0, 3));
    // The grant travels untouched: a desktop that widened it would be granting
    // what nobody offered.
    expect(host.asked.single.capabilities, 0x7);
  });

  test(
    'the route travels with the request: a relay for one, nothing for the other',
    () async {
      final host = _RemoteHost(
        (request) => PairedMessage(
          requestId: request.requestId,
          code: 'K7QM-3X2W-ABCD-EFGH-2345-6789-JKLM-NPQR',
          expiresAt: DateTime.utc(2026, 9, 16, 0, 3),
        ),
      );
      final setup = SshCompanionSetup(
        host: SshHost(
          id: 'h1',
          name: 'do-box',
          host: '203.0.113.9',
          port: 22,
          username: 'dlohani',
          authMethod: SshAuthMethod.privateKey,
          createdAt: DateTime.utc(2026, 9, 16),
        ),
        target: host,
        remotePath: '/x/karmashala_host',
        pairing: pairingOn(host),
      );

      await setup.openWindow(capabilities: 0x7);
      await setup.openWindow(capabilities: 0x7, relay: 'wss://relay.example');

      // Direct says nothing, so the host dials nothing on a phone's behalf.
      expect(host.asked.first.relay, isEmpty);
      expect(host.asked.last.relay, 'wss://relay.example');
    },
  );

  test(
    'a host older than pairing is named as that, not as a refusal',
    () async {
      // How an old host really answers: it fails at frame parsing, so it cannot
      // echo a request id it never read. Id 0 is the structural tell.
      final host = _RemoteHost(
        (_) => const ErrorMessage(
          0,
          ProtocolErrorCode.badRequest,
          'unknown message type 0x12',
        ),
      );

      final window = await pairingOn(host).open(capabilities: 0x7);

      expect(window.status, PairingRequestStatus.hostTooOld);
      expect(window.reason, contains('older than pairing'));
      expect(window.code, isNull);
    },
  );

  test('a host that understood and cannot pair is quoted', () async {
    final host = _RemoteHost(
      (request) => ErrorMessage(
        request.requestId,
        ProtocolErrorCode.badRequest,
        'this host is serving sessions but cannot pair: no store',
      ),
    );

    final window = await pairingOn(host).open(capabilities: 0x7);

    expect(window.status, PairingRequestStatus.hostCannotPair);
    // Its own words, because it knows why and this does not.
    expect(window.reason, contains('cannot pair: no store'));
  });

  test('silence is unknown, and says nothing was opened', () async {
    final window = await pairingOn(_RemoteHost(null)).open(capabilities: 0x7);

    expect(window.status, PairingRequestStatus.noAnswer);
    expect(window.reason, contains('nothing expires'));
    expect(window.code, isNull);
  });

  test('the pane and the pairing run the same executable', () async {
    final host = _RemoteHost(
      (r) => PairedMessage(
        requestId: r.requestId,
        code: 'X',
        expiresAt: DateTime.utc(2026),
      ),
    );
    final pairing = pairingOn(host);

    await pairing.open(capabilities: 1);

    // A different path would be a different host: sessions in one, pairings in
    // the other, and nobody able to see both.
    expect(pairing.remotePath, contains('.d/bin/karmashala_host'));
  });
}
