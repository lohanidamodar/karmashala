import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/shell_menus.dart';
import 'package:karmashala/src/app/shell/shell_state.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_host_protocol/host_access.dart'
    show HostDeployment, HostDeploymentStatus;
import 'package:karmashala_terminal_runtime/host_link.dart'
    show HostSupervision, HostSupervisionPhase;

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import 'package:agent_cli/process.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

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
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late _CapturedMenus captured;
  late PlatformMenuDelegate original;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    data = await server.override();
    captured = _CapturedMenus();
    original = WidgetsBinding.instance.platformMenuDelegate;
    WidgetsBinding.instance.platformMenuDelegate = captured;
  });
  tearDown(() {
    WidgetsBinding.instance.platformMenuDelegate = original;
  });

  Future<ProviderContainer> pumpMac(WidgetTester tester) async {
    final container = fakeTerminalContainer(machine: db, data: data);
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
      // No Tools: Settings and About are the app menu's on a Mac.
      ['Karmashala', 'Workspace', 'View', 'Window'],
    );
    expect(
      find.byType(ShellMenuButton),
      findsNothing,
      reason: 'no in-window menu',
    );
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
    item('Hide sidebar').onSelected!();
    await tester.pumpAndSettle();

    expect(
      container.read(shellControllerProvider).explorerPaneVisible,
      isFalse,
    );
    expect(_all(captured.menus).map((i) => i.label), contains('Show sidebar'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('View lists each control once, with the keymap\'s chords', (
    tester,
  ) async {
    await pumpMac(tester);
    final view = captured.menus.whereType<PlatformMenu>().firstWhere(
      (m) => m.label == 'View',
    );
    final labels = [for (final item in _all(view.menus)) item.label];
    for (final label in ['Inbox', 'Tools in More', 'Show Explorer']) {
      expect(labels, isNot(contains(label)));
    }
    expect(labels.where((l) => l == 'Media'), hasLength(1));

    final panel = _all(
      view.menus,
    ).firstWhere((i) => i.label.endsWith('context panel'));
    final chord = panel.shortcut! as SingleActivator;
    expect(chord.trigger, LogicalKeyboardKey.keyB, reason: 'not ⌘3, Terminals');
    expect(chord.alt, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('elsewhere the window keeps its own menu bar', (tester) async {
    final container = fakeTerminalContainer(machine: db, data: data);
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

    // The title bar's one menu glyph, which opens Workspace, View and Tools.
    expect(find.byType(ShellMenuButton), findsOneWidget);
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
        ...fakeTerminalOverrides(machine: db, data: data),
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
