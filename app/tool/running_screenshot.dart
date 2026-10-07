// Renders the Running tab over a realistic fixture into PNGs, so its layout
// can be looked at. Lives under tool/ so `flutter test` never picks it up:
//
//   flutter test tool/running_screenshot.dart
//
// Images land in build/running-screenshots/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/descriptors.dart' show AgentRegistry;
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_routes.dart';
import 'package:karmashala/src/app/shell/running_tab_view.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/browser/application/browser_pane_controller.dart';
import 'package:karmashala/src/features/environments/application/environment_providers.dart';
import 'package:karmashala/src/features/environments/application/environments_controller.dart';
import 'package:karmashala/src/features/running/application/running_providers.dart';
import 'package:karmashala/src/features/running/domain/port_label.dart';
import 'package:karmashala/src/features/sessions/application/background_runs_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_agent_providers.dart';
import 'package:karmashala/src/features/terminal/data/terminals_client.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../test/features/running/running_fixture.dart';

const _outDir = 'build/running-screenshots';

class _Terminals implements TerminalsClient {
  @override
  Future<RunningReading> running() async => runningFixture;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Browser extends BrowserPaneController {
  @override
  BrowserPaneState build() => const BrowserPaneState();

  @override
  Future<void> navigate(String url) async {}
}

class _Environments extends EnvironmentsController {
  @override
  List<ExecutionEnvironment> build() => [fixtureLocal, fixtureWsl, fixtureBox];
}

class _Routes implements PhoneShellRoutes {
  @override
  void showInbox() {}
  @override
  void showMore(PhoneMoreEntry entry) {}
  @override
  void showProjects() {}
  @override
  void showWorkbench() {}
}

class _Preferences implements PreferenceStore {
  @override
  String? read(String key) => null;
  @override
  void write(String key, String value) {}
  @override
  void remove(String key) {}
}

/// The app's own faces, from the asset bundle: flutter_test draws boxes
/// otherwise.
Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> assets) async {
    final loader = FontLoader(family);
    for (final asset in assets) {
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }

  await load(kBundledSansFamily, [
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      'packages/karmashala_ui/fonts/Geist-$weight.ttf',
  ]);
  await load(kBundledMonoFamily, [
    'packages/karmashala_ui/fonts/JetBrainsMono-Regular.ttf',
  ]);
  await load('packages/picons/PhosphorRegular', [
    'packages/picons/lib/fonts/Phosphor.ttf',
  ]);
  await load('MaterialIcons', ['fonts/MaterialIcons-Regular.otf']);
  await load('packages/picons/PhosphorFill', [
    'packages/picons/lib/fonts/Phosphor-Fill.ttf',
  ]);
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    Directory(_outDir).createSync(recursive: true);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    required Brightness brightness,
    bool phone = false,
    double textScale = 1,
    Future<void> Function(WidgetTester tester)? then,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final router = PhoneShellRouter();
    if (phone) router.attach(_Routes());
    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          terminalsClientProvider.overrideWithValue(_Terminals()),
          browserPaneControllerProvider.overrideWith(_Browser.new),
          environmentsControllerProvider.overrideWith(_Environments.new),
          localEnvironmentProvider.overrideWithValue(fixtureLocal),
          portFactsProvider.overrideWithValue(
            const PortFacts(vmServicePorts: {55134}),
          ),
          sessionBackgroundRunsProvider.overrideWith((ref, _) => const []),
          sessionAgentIdProvider.overrideWith(
            (ref, id) => id == 'sd' ? 'codex' : 'claudeCode',
          ),
          agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
          runningPreferencesProvider.overrideWithValue(_Preferences()),
          phoneShellRouterProvider.overrideWithValue(router),
        ],
        child: RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            home: const Scaffold(body: RunningTabView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Agent logos are images: decode them for real before the shot.
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        final image = element.widget as Image;
        await precacheImage(image.image, element);
      }
    });
    await tester.pumpAndSettle();
    if (then != null) await then(tester);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  for (final brightness in Brightness.values) {
    final theme = brightness.name;
    testWidgets('desktop $theme', (tester) async {
      await shoot(
        tester,
        'running-desktop-1440x900-$theme',
        size: const Size(1440, 900),
        brightness: brightness,
      );
    });
    testWidgets('phone $theme', (tester) async {
      await shoot(
        tester,
        'running-phone-390x844-$theme',
        size: const Size(390, 844),
        brightness: brightness,
        phone: true,
      );
    });
  }

  testWidgets('phone, a session opened', (tester) async {
    await shoot(
      tester,
      'running-phone-390x844-dark-session-open',
      size: const Size(390, 844),
      brightness: Brightness.dark,
      phone: true,
      then: (tester) async {
        final card = find.byKey(const ValueKey('running-session-pn'));
        await tester.scrollUntilVisible(
          card,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(card);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('running-helpers-pn')));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -80));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('desktop, the server opened and text at 1.6x', (tester) async {
    await shoot(
      tester,
      'running-desktop-1440x900-light-text1.6',
      size: const Size(1440, 900),
      brightness: Brightness.light,
      textScale: 1.6,
      then: (tester) async {
        await tester.tap(find.byKey(const ValueKey('running-server-toggle')));
        await tester.pumpAndSettle();
      },
    );
  });
}
