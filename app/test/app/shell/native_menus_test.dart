import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/shell_state.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_ssh/host.dart'
    show HostDeployment, HostDeploymentStatus;
import 'package:karmashala_store/database.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show HostSupervision, HostSupervisionPhase;

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// What the app hands the macOS menu bar, caught before the platform channel.
class _CapturedMenus extends PlatformMenuDelegate {
  List<PlatformMenuItem> menus = const [];

  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) => menus = topLevelMenus;

  @override
  void clearMenus() => menus = const [];

  @override
  bool debugLockDelegate(BuildContext context) => true;

  @override
  bool debugUnlockDelegate(BuildContext context) => true;
}

Iterable<PlatformMenuItem> _all(Iterable<PlatformMenuItem> items) sync* {
  for (final item in items) {
    yield item;
    if (item is PlatformMenu) yield* _all(item.menus);
    if (item is PlatformMenuItemGroup) yield* _all(item.members);
  }
}

void main() {
  late AppDatabase db;
  late _CapturedMenus captured;
  late PlatformMenuDelegate original;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    captured = _CapturedMenus();
    original = WidgetsBinding.instance.platformMenuDelegate;
    WidgetsBinding.instance.platformMenuDelegate = captured;
  });
  tearDown(() {
    WidgetsBinding.instance.platformMenuDelegate = original;
    db.close();
  });

  Future<ProviderContainer> pumpMac(WidgetTester tester) async {
    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('on macOS the menus are in the system menu bar, not the window', (
    tester,
  ) async {
    await pumpMac(tester);

    expect(
      [for (final menu in captured.menus) (menu as PlatformMenu).label],
      ['Karmashala', 'Workspace', 'View', 'Tools', 'Window'],
    );
    expect(find.text('Workspace'), findsNothing, reason: 'no in-window bar');
    final labels = [for (final item in _all(captured.menus)) item.label];
    for (final label in [
      'About Karmashala',
      'Settings…',
      'Quit Karmashala',
      'New project',
      'New session',
      'Go to…',
      'Detect CLI sessions',
    ]) {
      expect(labels, contains(label));
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a toggle says what it will do, and follows the state', (
    tester,
  ) async {
    final container = await pumpMac(tester);
    PlatformMenuItem item(String label) =>
        _all(captured.menus).firstWhere((i) => i.label == label);

    expect(container.read(shellControllerProvider).explorerPaneVisible, isTrue);
    item('Hide Explorer').onSelected!();
    await tester.pumpAndSettle();

    expect(
      container.read(shellControllerProvider).explorerPaneVisible,
      isFalse,
    );
    expect(_all(captured.menus).map((i) => i.label), contains('Show Explorer'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('elsewhere the window keeps its own menu bar', (tester) async {
    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Workspace'), findsOneWidget);
    expect(captured.menus, isEmpty);
  });

  // Found live: the host killed and its binary hidden with the app open, and
  // the session host banner appearing re-created the shell under it — a second
  // PlatformMenuBar mounted while the first still held the delegate. The real
  // delegate's lock is what caught it, so the real delegate is used here.
  testWidgets('the host going missing and coming back keeps one menu bar, '
      'and the shell under the banner is not rebuilt', (tester) async {
    const channel = MethodChannel('karmashala/test/menu');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    WidgetsBinding.instance.platformMenuDelegate = DefaultPlatformMenuDelegate(
      channel: channel,
    );
    final supervision = StreamController<HostSupervision?>();
    addTearDown(supervision.close);
    HostSupervision running() => HostSupervision(
      phase: HostSupervisionPhase.running,
      observedAt: DateTime.now(),
    );
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        localHostSupervisionProvider.overrideWith((ref) => supervision.stream),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    supervision.add(running());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlatformMenuBar), findsOneWidget);
    final shell = tester.element(find.byType(Scaffold).first);

    supervision.add(
      HostSupervision(
        phase: HostSupervisionPhase.stopped,
        observedAt: DateTime.now(),
        reason: 'No karmashala_host beside this app.',
        reading: HostDeployment(
          status: HostDeploymentStatus.noBinary,
          observedAt: DateTime.now(),
          reason: 'No karmashala_host beside this app.',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('session_host_banner')), findsOneWidget);
    expect(find.byType(PlatformMenuBar), findsOneWidget);
    expect(
      tester.element(find.byType(Scaffold).first),
      same(shell),
      reason: 'the shell keeps its state when the banner appears',
    );

    supervision.add(running());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('session_host_banner')), findsNothing);
    expect(find.byType(PlatformMenuBar), findsOneWidget);
    expect(tester.element(find.byType(Scaffold).first), same(shell));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
