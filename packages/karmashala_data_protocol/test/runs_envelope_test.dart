import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_browser/browser.dart'
    show ElementBox, ElementCapture;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:test/test.dart';

/// The Flutter apps, hosted runs and browser the server owns (slice 3d):
/// every request, answer and change through the envelope as JSON text, and
/// a live stream's three messages.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 8);
  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  final app = AttachedApp(
    id: '127.0.0.1:53119/AbC=',
    uri: Uri.parse('ws://127.0.0.1:53119/AbC=/ws'),
    discovery: AppDiscovery.deviceLog,
    reachability: AppReachability.attached,
    observedAt: t0,
    label: 'pixel',
    sourcePath: 'emulator-5554',
    isolateId: 'isolates/1',
    widgetLocations: WidgetLocationSupport.tracked,
    reloadMethod: 's0.reloadSources',
    restartMethod: 's0.hotRestart',
  );

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const FlutterApps(look: true),
      const FlutterAttach(
        'http://127.0.0.1:1/a=/',
        deviceSerial: 'e',
        label: 'x',
      ),
      const FlutterReload('a', full: true),
      const FlutterDetach('a'),
      const FlutterForget('a'),
      const FlutterPickWidget('a', timeoutSeconds: 30),
      const FlutterSdk('env', force: true),
      const BrowserStateGet(),
      const BrowserConnect(spawn: false, url: 'localhost:3000'),
      const BrowserDisconnect(),
      const BrowserNavigate('https://example.com'),
      const BrowserTabs(),
      const BrowserSelectTab('PAGE-2'),
      const BrowserScreenshot(),
      const BrowserPickElement(),
      const BrowserCancelPick(),
      const BrowserEvaluate('document.title'),
      const BrowserFind(selector: '#go', limit: 5),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.kind, request.kind);
      expect(
        jsonEncode(read.request!.argumentsToJson()),
        jsonEncode(request.argumentsToJson()),
        reason: request.kind,
      );
    }
  });

  test('an attached app crosses whole, reload methods and all', () {
    final back = const FlutterAttach('x').resultFromJson(
      jsonDecode(jsonEncode(const FlutterAttach('x').resultToJson(app))),
    );
    expect(back.id, app.id);
    expect(back.uri, app.uri);
    expect(back.discovery, AppDiscovery.deviceLog);
    expect(back.canHotReload, isTrue);
    expect(back.restartMethod, 's0.hotRestart');
    expect(back.widgetLocations, WidgetLocationSupport.tracked);

    final registry = FlutterAppRegistry(
      apps: [app],
      lookedAt: t0,
      discoveryDirectory: '/data/vmservice',
    );
    final told =
        DataChange.fromJson(overTheWire(FlutterAppsChanged(registry).toJson()))!
            as FlutterAppsChanged;
    expect(told.registry.apps.single.label, 'pixel');
    expect(told.registry.lookedAt, t0);
    expect(told.registry.discoveryDirectory, '/data/vmservice');
  });

  test('a hosted run names the session a pane attaches to', () {
    final run = HostedRun(
      runId: 'r1',
      title: 'run · app',
      family: HostedRunFamily.flutter,
      startedAt: t0,
    );
    expect(run.paneId, 'hosted-r1');
    // The terminal's `hostSessionIdFor(paneId:)` rule, spelled once here.
    expect(run.hostSessionId, 'karmashala_local_hosted-r1');
    final told =
        DataChange.fromJson(overTheWire(HostedRunChanged(run).toJson()))!
            as HostedRunChanged;
    expect(told.run.sameAs(run), isTrue);
    expect(told.run.isLive, isTrue);
    final gone =
        DataChange.fromJson(overTheWire(const HostedRunRemoved('r1').toJson()))!
            as HostedRunRemoved;
    expect(gone.runId, 'r1');
  });

  test('the browser, a pick and a picture cross whole', () {
    const state = BrowserState(
      status: BrowserStatus.connected,
      connection: 'Attached to the browser already listening on port 9222',
      url: 'https://example.com',
      title: 'Example',
      tabs: [
        BrowserTab(id: 'P1', title: 'Example', url: 'https://example.com'),
      ],
      currentTargetId: 'P1',
      headless: true,
    );
    final told =
        DataChange.fromJson(
              overTheWire(const BrowserStateChanged(state).toJson()),
            )!
            as BrowserStateChanged;
    expect(told.state.sameAs(state), isTrue);
    expect(told.state.headless, isTrue);

    final pick = BrowserPick(
      ElementCapture(
        selector: '#hero',
        tagName: 'section',
        outerHtml: '<section id="hero"></section>',
        computedStyles: const {'display': 'block'},
        box: const ElementBox(x: 0, y: 0, width: 10, height: 10),
        pageUrl: 'https://example.com',
        pageTitle: 'Example',
        capturedAt: t0,
        screenshotPng: Uint8List.fromList([1, 2, 3]),
      ),
      captureFile: '/data/captures/element_1.png',
    );
    final back = const BrowserPickElement().resultFromJson(
      jsonDecode(jsonEncode(const BrowserPickElement().resultToJson(pick))),
    );
    expect(back.capture.selector, '#hero');
    expect(back.capture.screenshotPng, [1, 2, 3]);
    expect(back.promptText, contains('Screenshot file: /data/captures'));

    final png = const BrowserScreenshot().resultFromJson(
      jsonDecode(
        jsonEncode(
          const BrowserScreenshot().resultToJson(Uint8List.fromList([9, 8])),
        ),
      ),
    );
    expect(png, [9, 8]);
  });

  test('a stream opens, carries batches with what was dropped, and closes', () {
    final open = DataStreamEnvelope.readOpen(
      overTheWire(DataStreamEnvelope.open(4, kFlutterLogsStream, 'app')),
    )!;
    expect(open.streamId, 4);
    expect(open.source, kFlutterLogsStream);
    expect(open.key, 'app');

    final record = AppLogRecord(
      source: AppLogSource.stderr,
      at: t0,
      message: 'boom',
      beforeAttach: true,
    );
    final batch = DataStreamEnvelope.readItems(
      overTheWire(
        DataStreamEnvelope.items(
          DataStreamItems(4, [record.toJson()], dropped: 7, ended: 'gone'),
        ),
      ),
    )!;
    expect(batch.dropped, 7);
    expect(batch.ended, 'gone');
    final line = appLogRecordFromJson(
      (batch.items.single! as Map).cast<String, Object?>(),
    );
    expect(line.message, 'boom');
    expect(line.source, AppLogSource.stderr);
    expect(line.beforeAttach, isTrue);

    expect(
      DataStreamEnvelope.readClose(overTheWire(DataStreamEnvelope.close(4))),
      4,
    );
    expect(DataStreamEnvelope.readOpen(const {'streamId': 'x'}), isNull);
  });
}
