import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/cli_detection/application/pane_facts_reporter.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala_host/lifecycle_client.dart'
    show PaneFacts, PaneTailsWantedMessage;

/// This app's half of adoption and attribution since slice 2b: it reports
/// its panes to the server as facts — only when they changed — and sends a
/// pane's last rows only when the server asks, and never a replayed buffer's.
/// What the server does with them is tested in the server's `test/sessions/`.
void main() {
  late List<AdoptablePane> panes;
  late Map<String, List<String>?> screens;
  late List<List<PaneFacts>> sent;
  late StreamController<PaneTailsWantedMessage> wants;
  late PaneFactsReporter reporter;

  setUp(() {
    panes = [];
    screens = {};
    sent = [];
    wants = StreamController<PaneTailsWantedMessage>.broadcast(sync: true);
    reporter = PaneFactsReporter(
      readPanes: () => List.of(panes),
      readTail: (paneId, lines) {
        final screen = screens[paneId];
        if (screen == null) return null;
        return screen.length <= lines
            ? screen
            : screen.sublist(screen.length - lines);
      },
    );
  });
  tearDown(() => wants.close());

  HostLifecycleFeed feed() => HostLifecycleFeed(
    snapshot: const [],
    events: const Stream.empty(),
    close: () async {},
    reportPanes: sent.add,
    paneTailsWanted: wants.stream,
  );

  AdoptablePane pane(String id, {String? line, bool running = true}) =>
      AdoptablePane(
        paneId: id,
        workingDirectory: r'C:\src\demo\app',
        isLive: true,
        hostsLaunchedSession: false,
        lastCommandId: line == null ? null : 'cmd-0',
        lastCommandLine: line,
        lastCommandRunning: running,
      );

  test('nothing is sent without a link', () {
    panes.add(pane('pane-1'));
    reporter.report();
    expect(sent, isEmpty);
  });

  test('a link is told every pane at once, then only what changed', () {
    panes.add(pane('pane-1'));
    reporter.attached(feed());
    expect(sent.single.single.paneId, 'pane-1');

    for (var i = 0; i < 100; i++) {
      reporter.report();
    }
    expect(sent, hasLength(1), reason: 'a pane nobody touched costs nothing');

    panes
      ..clear()
      ..add(pane('pane-1', line: 'claude'));
    reporter.report();
    expect(sent, hasLength(2));
    final facts = sent.last.single;
    expect(facts.lastCommandLine, 'claude');
    expect(facts.lastCommandId, 'cmd-0');
    expect(facts.lastCommandRunning, isTrue);
    expect(facts.workingDirectory, r'C:\src\demo\app');
    expect(facts.tail, isNull);
  });

  test('a pane gone is reported as the list without it', () {
    panes.add(pane('pane-1'));
    reporter.attached(feed());
    panes.clear();
    reporter.report();
    expect(sent.last, isEmpty);
  });

  test('tails go only when asked, once, at the depth asked', () {
    panes
      ..add(pane('pane-1'))
      ..add(pane('pane-2'));
    screens['pane-1'] = ['a', 'b', 'c'];
    screens['pane-2'] = ['x'];
    reporter.attached(feed());

    wants.add(const PaneTailsWantedMessage(paneIds: ['pane-1'], lines: 2));
    // Answered at once: the server reads a screen as it is now.
    expect(sent, hasLength(2));
    expect(sent.last.first.tail, ['b', 'c']);
    expect(sent.last.last.tail, isNull);

    reporter.report();
    expect(sent, hasLength(2), reason: 'a tail is sent once per ask');
  });

  test('a replayed buffer sends no tail, though asked', () {
    panes.add(pane('pane-1'));
    screens['pane-1'] = null;
    reporter.attached(feed());
    wants.add(const PaneTailsWantedMessage(paneIds: ['pane-1'], lines: 5));
    expect(sent.last.single.tail, isNull);
  });

  test('a new link is told everything again; a lost one nothing', () {
    panes.add(pane('pane-1'));
    reporter.attached(feed());
    reporter.detached();
    reporter.report();
    expect(sent, hasLength(1));

    reporter.attached(feed());
    expect(sent, hasLength(2));
  });
}
