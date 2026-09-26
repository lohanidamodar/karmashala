import 'dart:async';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_host/src/sessions/client_panes.dart';
import 'package:test/test.dart';

import '../serve/pipe_connection.dart';

Future<void> pump() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The panes wire (slice 2b): a client reports every pane it has as facts on
/// its lifecycle link, the host server hands them to its receiver, the
/// receiver asks back for tails, and a link that ends takes its panes with it.
void main() {
  group('PaneFacts', () {
    test('travel whole, and the defaults stay off the wire', () {
      const facts = PaneFacts(
        paneId: 'pane-1',
        workingDirectory: r'C:\src\app',
        live: true,
        hostsLaunchedSession: true,
        lastCommandId: 'cmd-0',
        lastCommandLine: 'claude',
        lastCommandRunning: false,
        tail: ['a', 'b'],
      );
      final decoded = decodeMessage(
        FrameParser()
            .add(PaneFactsMessage(const [facts]).toFrame().encode())
            .single,
      );
      expect((decoded as PaneFactsMessage).panes.single, facts);

      const bare = PaneFacts(paneId: 'p', live: false);
      expect(bare.toJson(), {'paneId': 'p', 'live': false});
      expect(PaneFacts.fromJson(bare.toJson()), bare);
    });

    test('a tail out of shape is refused', () {
      expect(
        () => PaneFacts.fromJson({
          'paneId': 'p',
          'live': true,
          'tail': [1],
        }),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('the tails wanted travel whole', () {
      final decoded = decodeMessage(
        FrameParser()
            .add(
              const PaneTailsWantedMessage(
                paneIds: ['a', 'b'],
                lines: 12,
              ).toFrame().encode(),
            )
            .single,
      );
      expect((decoded as PaneTailsWantedMessage).paneIds, ['a', 'b']);
      expect(decoded.lines, 12);
    });
  });

  test('over a link: reported, asked back, and forgotten with it', () async {
    final registry = SessionRegistry(launcher: FakePtyLauncher());
    final server = HostServer(registry: registry, ptyLibrary: 'libc.so.6');
    final panes = ClientPanes();
    final seen = <List<PaneFacts>>[];
    panes.onChanged = seen.add;
    server.panes = panes;

    final (client, host) = PipeEnd.pair();
    final served = server.serveConnection(host);
    final watch = await HostLifecycleWatch.over(client, clientId: 'app');
    final wanted = <PaneTailsWantedMessage>[];
    final wants = watch.paneTailsWanted.listen(wanted.add);

    watch.reportPanes(const [
      PaneFacts(paneId: 'pane-1', live: true, lastCommandId: 'c'),
    ]);
    await pump();
    expect(panes.all.single.paneId, 'pane-1');

    panes.want(['pane-1', 'unknown'], 20);
    await pump();
    expect(wanted.single.paneIds, ['pane-1']);
    expect(wanted.single.lines, 20);

    watch.reportPanes(const [
      PaneFacts(paneId: 'pane-1', live: true, tail: ['row']),
    ]);
    await pump();
    expect(panes.takeTails(), {
      'pane-1': ['row'],
    });
    expect(panes.takeTails(), isEmpty, reason: 'a tail is read once');
    expect(panes.all.single.tail, isNull);

    await watch.close();
    await served;
    await wants.cancel();
    expect(panes.all, isEmpty);
    expect(seen.last, isEmpty);
  });
}
