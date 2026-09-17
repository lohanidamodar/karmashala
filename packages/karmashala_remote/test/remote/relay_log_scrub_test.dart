/// A relay URL can carry a box relay's access token in its path, and the
/// endpoint carries the rendezvous id. `dart:io` quotes the whole URL in the
/// exception for a refused upgrade, so neither may reach a log line as it is.
library;

import 'dart:async';

import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import './transport_harness.dart';

const _token = '0123456789abcdef0123456789abcdef';
final _rendezvous = RendezvousId.parse('fedcba9876543210fedcba9876543210');

void main() {
  test(
    'a refused upgrade is logged without the token or the rendezvous',
    () async {
      // Token-gated, and dialled with the WRONG token: the relay answers 404 and
      // `WebSocket.connect` throws an exception that quotes the URL it dialled.
      final relay = await RelayServer.bind(
        address: '127.0.0.1',
        port: 0,
        options: const RelayOptions(accessToken: _token),
      );
      addTearDown(relay.close);
      const wrong = 'ffffffffffffffffffffffffffffffff';
      final lines = <String>[];
      final failed = Completer<void>();
      final transport = RelayTransport(
        endpoint: RelayTransport.endpointFor(
          Uri.parse('ws://127.0.0.1:${relay.port}/k/$wrong'),
          _rendezvous,
        ),
        backoff: fastBackoff(),
        onLog: (line) {
          lines.add(line);
          if (line.contains('failed') && !failed.isCompleted) failed.complete();
        },
      )..start();
      addTearDown(transport.close);

      await failed.future.timeout(const Duration(seconds: 5));

      final logged = lines.join('\n');
      expect(logged, isNot(contains(wrong)));
      expect(logged, isNot(contains(_rendezvous.value)));
    },
  );

  test(
    'the scrub keeps what a person needs and drops what a stranger could use',
    () {
      expect(
        scrubRelayLog(
          "Connection to 'http://203.0.113.9:8787/k/$_token/v1/"
          "${_rendezvous.value}#' was not upgraded to websocket",
        ),
        "Connection to 'http://203.0.113.9:8787/k/…/v1/…#' was not upgraded to "
        'websocket',
      );
      expect(
        scrubRelayLog('relay closed the connection (4408)'),
        'relay closed the connection (4408)',
      );
    },
  );
}
