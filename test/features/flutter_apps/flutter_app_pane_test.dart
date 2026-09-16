import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_app_providers.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala/src/features/flutter_apps/presentation/flutter_app_pane.dart';
import 'package:karmashala_ui/panes.dart';

import '../../support/fakes.dart';
import 'fake_vm_service.dart';

void main() {
  late Directory temp;
  late Map<String, FakeVmService> reachable;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('karmashala-flutter-pane');
    reachable = <String, FakeVmService>{};
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  FakeVmService serve(String wsUri) =>
      reachable[wsUri] = FakeVmService(selectedWidget: null);

  void writeUriFile(String name, String wsUri) =>
      File('${temp.path}${Platform.pathSeparator}$name')
          .writeAsStringSync(wsUri);

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1100)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 9, 8))),
        flutterAppDiscoveryDirectoryProvider.overrideWith(
          (ref) async => VmServiceUriDirectory(temp),
        ),
        // This test knows about no tooling daemons. Without it the real
        // ones on the machine running the suite are read, and a live
        // `flutter run` in another window becomes an extra row.
        dtdPidFilesProvider.overrideWithValue(const DtdPidFiles(<String>[])),
        // And no Android SDK and no devices, so opening the pane spawns no
        // `adb` and reads no real phone.
        adbServiceProvider.overrideWithValue(null),
        devicesProvider.overrideWith((ref) async => const []),
        vmServiceConnectorProvider.overrideWithValue((uri) async {
          final fake = reachable[uri.toString()];
          if (fake == null) throw const _Refused();
          return fake.client;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FlutterAppPane())),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('its status line is the shared one the browser pane uses', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(PaneStatusRow), findsOneWidget);
    expect(find.byType(StatusDot), findsOneWidget);
    expect(find.byTooltip('Look again'), findsOneWidget);
  });

  testWidgets('says nothing is running, and how to make one visible', (
    tester,
  ) async {
    await pump(tester);
    expect(
      find.text(
        'No Flutter app is running that we can see.\n\n'
        'A run Karmashala started, a "flutter run" started anywhere else on '
        'this machine, and an app on a connected Android device are all found '
        'on their own. A run on another machine is the one that still needs '
        'its address attached by hand.',
      ),
      findsOneWidget,
    );
    // The one remaining lever. The button that copied a flag to paste into
    // somebody else's command is gone with the flag.
    expect(find.text('Attach by address'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('opening the pane looks once, and never again on its own', (
    tester,
  ) async {
    const uri = 'ws://127.0.0.1:1/a=/ws';
    final fake = serve(uri);
    writeUriFile('windows.uri', uri);
    await pump(tester);
    expect(fake.methods.where((m) => m == 'getVM'), hasLength(1));

    // Nothing polls: pumping the tree for a while adds no further traffic.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(fake.methods.where((m) => m == 'getVM'), hasLength(1));
  });

  testWidgets('shows the console, and marks what was replayed', (tester) async {
    const uri = 'ws://127.0.0.1:1/a=/ws';
    final fake = serve(uri);
    writeUriFile('windows.uri', uri);
    await pump(tester);

    fake.emitStdout('flutter: hello\n', at: DateTime.utc(2026, 9, 8, 1));
    fake.emitStdout('older\n', at: DateTime.utc(2026, 9, 7));
    await tester.pumpAndSettle();

    expect(find.text('flutter: hello'), findsOneWidget);
    expect(find.text('older'), findsOneWidget);
    expect(find.text('before attach'), findsOneWidget);
  });

  testWidgets('an error offers itself and is never sent', (tester) async {
    const uri = 'ws://127.0.0.1:1/a=/ws';
    final fake = serve(uri);
    writeUriFile('windows.uri', uri);
    await pump(tester);

    fake.emitFlutterError(flutterErrorTree());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('newest error: The following StateError'),
      findsOneWidget,
    );
    expect(find.text('Offer error to session'), findsOneWidget);
  });

  testWidgets('hot reload is off, with the reason, until a tool attaches', (
    tester,
  ) async {
    const uri = 'ws://127.0.0.1:1/a=/ws';
    final fake = serve(uri);
    writeUriFile('windows.uri', uri);
    await pump(tester);

    Tooltip tooltipFor(String label) => tester.widget<Tooltip>(
      find.ancestor(of: find.text(label), matching: find.byType(Tooltip)),
    );

    expect(
      tooltipFor('Hot reload').message,
      contains('No Flutter tool is attached'),
    );
    expect(
      tester
          .widget<TextButton>(
            find.ancestor(
              of: find.text('Hot reload'),
              matching: find.byType(TextButton),
            ),
          )
          .onPressed,
      isNull,
    );

    fake.emitServiceRegistered('reloadSources', 's1.reloadSources');
    await tester.pumpAndSettle();
    expect(tooltipFor('Hot reload').message, 'Hot reload');
  });

  testWidgets('lists every app when more than one is running', (tester) async {
    const desktop = 'ws://127.0.0.1:1/a=/ws';
    const phone = 'ws://127.0.0.1:2/b=/ws';
    serve(desktop);
    serve(phone);
    writeUriFile('windows.uri', desktop);
    writeUriFile('pixel.uri', phone);
    await pump(tester);

    expect(find.text('2 Flutter apps attached.  ·  checked just now'), findsOneWidget);
    expect(find.text('windows'), findsOneWidget);
    expect(find.text('pixel'), findsOneWidget);
    // Each row says where it was found and how old that reading is.
    expect(
      find.textContaining('started here · found just now'),
      findsNWidgets(2),
    );
  });

  testWidgets('says a build carries no widget locations rather than nothing', (
    tester,
  ) async {
    const uri = 'ws://127.0.0.1:1/a=/ws';
    final fake = serve(uri);
    fake.handlers['ext.flutter.inspector.isWidgetCreationTracked'] =
        (_) => <String, Object?>{'type': '_extensionType', 'result': false};
    writeUriFile('release.uri', uri);
    await pump(tester);

    expect(
      find.text('This build carries no widget locations.'),
      findsOneWidget,
    );
  });

  testWidgets('an address nothing answers on says so and offers Forget', (
    tester,
  ) async {
    writeUriFile('stale.uri', 'ws://127.0.0.1:9/gone=/ws');
    await pump(tester);
    expect(
      find.textContaining('1 address is on record and nothing answers on it.'),
      findsOneWidget,
    );
    expect(find.text('Forget'), findsOneWidget);
    expect(find.text('Detach'), findsNothing);
  });
}

class _Refused implements Exception {
  const _Refused();
  @override
  String toString() => 'Connection refused';
}
