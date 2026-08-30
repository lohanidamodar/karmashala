import 'dart:async';
import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/lifecycle/app_lifecycle.dart';
import 'package:chitragupta/src/features/mcp/launcher_control_server.dart';
import 'package:chitragupta/src/features/notifications/application/notification_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../features/system/fake_native_adapters.dart';

/// The application lifecycle owner.
///
/// The 2026-08-30 audit found that nothing in the app owned shutdown:
/// `SystemIntegrationService` was a temporary expression, `LauncherControlServer`
/// sat in a local whose comment claimed otherwise, and `stop()` — which deletes
/// the bridge handshake — had no caller at all. A normal quit therefore left a
/// handshake on disk advertising a port nothing was listening on.
/// Whether [container] has been disposed.
///
/// Riverpod 3.3 does not expose a `disposed` getter, and reading through a
/// disposed container is exactly what the lifecycle owner must have made
/// impossible, so the observable behaviour is the assertion.
bool isDisposed(ProviderContainer container) {
  try {
    container.read(agentStatusWatcherProvider);
    return false;
  } on StateError {
    return true;
  }
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('chitra_lifecycle_');
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() {
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('the control server it owns', () {
    test('graceful shutdown deletes the handshake', () async {
      final lifecycle = AppLifecycle(container);
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      // `startControlServer` starts its own; this test owns the paths, so it
      // hands over an already-started instance the same way the app hands over
      // a freshly built one.
      lifecycle.adopt(controlServer: server);
      expect(File(bridge).existsSync(), isTrue);

      await lifecycle.shutdown();

      expect(
        File(bridge).existsSync(),
        isFalse,
        reason: 'a stale handshake points a bridge at a dead port',
      );
      expect(File(p.join(tmp.path, 'ipc', 'rpc.sock')).existsSync(), isFalse);
    });

    test('the pid stays in the handshake for the crash case', () async {
      // Graceful quit removes the file; a crash cannot, which is why the pid it
      // publishes has to stay there for a reader to validate.
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      addTearDown(server.stop);

      expect(File(bridge).readAsStringSync(), contains('"pid":$pid'));
    });
  });

  group('ordering', () {
    test('runs outermost first and disposes the container last', () async {
      final order = <String>[];
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      final service = await lifecycle.startSystemIntegration(
        adapters: natives.adapters,
      );
      // Force the watcher to exist so the step has something to do.
      container.read(agentStatusWatcherProvider);
      lifecycle.adopt(
        controlServer: _RecordingControlServer(container, order),
        hookInstallation: Future<void>(() => order.add('hooks')),
      );
      natives.tray.onDestroy = () => order.add('system integration');

      await lifecycle.shutdown();

      expect(order, ['hooks', 'control server', 'system integration']);
      expect(isDisposed(container), isTrue);
      // And the service really is detached, not merely marked so.
      expect(natives.window.listeners, isEmpty);
      expect(natives.tray.listeners, isEmpty);
      expect(service, isNotNull);
    });

    test('a step that throws does not stop the ones after it', () async {
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(adapters: natives.adapters);
      lifecycle.adopt(
        hookInstallation: Future<void>.error(StateError('hook write failed')),
      );

      await lifecycle.shutdown();

      expect(natives.tray.destroyed, isTrue);
      expect(isDisposed(container), isTrue);
    });
  });

  group('the budget', () {
    test('a step that hangs does not starve the ones after it', () async {
      // The first draft shared one budget across the sequence, so a hook
      // rewrite that never returned spent all of it and the control server —
      // the step that deletes the handshake — was skipped entirely. That is the
      // exact failure this owner exists to prevent, so it gets its own test.
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(adapters: natives.adapters);
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      // A hook rewrite that never returns — the shape of Loop 48's build that
      // could not exit at all.
      lifecycle.adopt(
        controlServer: server,
        hookInstallation: Completer<void>().future,
      );

      final watch = Stopwatch()..start();
      await lifecycle.shutdown();
      watch.stop();

      expect(watch.elapsed, lessThan(kShutdownBudget + kShutdownBudget));
      expect(File(bridge).existsSync(), isFalse, reason: 'handshake removed');
      expect(natives.tray.destroyed, isTrue);
      expect(isDisposed(container), isTrue);
      expect(lifecycle.lastShutdownDuration, isNotNull);
    });

    test('every step hanging still finishes inside the deadline', () async {
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(adapters: natives.adapters);
      lifecycle.adopt(hookInstallation: Completer<void>().future);
      natives.tray.destroyDelay = const Duration(seconds: 30);

      final watch = Stopwatch()..start();
      await lifecycle.shutdown();
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(milliseconds: 900)));
      expect(isDisposed(container), isTrue);
    });

    test('a clean shutdown is far inside the budget', () async {
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(adapters: natives.adapters);
      final server = LauncherControlServer(container);
      await server.start(
        bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      lifecycle.adopt(controlServer: server);

      await lifecycle.shutdown();

      expect(lifecycle.lastShutdownDuration, lessThan(kShutdownBudget));
    });
  });

  group('idempotence', () {
    test('a second shutdown is the same shutdown', () async {
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(adapters: natives.adapters);

      await Future.wait([lifecycle.shutdown(), lifecycle.shutdown()]);
      await lifecycle.shutdown();

      expect(
        natives.tray.calls.where((c) => c == 'destroy'),
        hasLength(1),
        reason: 'the sequence runs once however many exits call it',
      );
      expect(lifecycle.isShuttingDown, isTrue);
    });

    test('quitting from the tray runs the whole sequence', () async {
      // The wiring the audit asked for: the graceful quit path goes through
      // this owner *before* the window is destroyed.
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      final service = await lifecycle.startSystemIntegration(
        adapters: natives.adapters,
      );
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      lifecycle.adopt(controlServer: server);

      await service.quit();

      expect(File(bridge).existsSync(), isFalse);
      expect(natives.window.destroyed, isTrue);
      expect(isDisposed(container), isTrue);
    });

    test('closing the window runs the whole sequence too', () async {
      // The X is the default way out, and it used to run none of this:
      // prevent-close was derived from close-to-tray (off by default), so
      // `WM_CLOSE` fell through to `DefWindowProc` and destroyed the window
      // before the `close` event reached Dart. The first expectation below is
      // the whole fix; the rest is what it buys.
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      final service = await lifecycle.startSystemIntegration(
        adapters: natives.adapters,
      );
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      lifecycle.adopt(controlServer: server);

      expect(
        natives.window.preventClose,
        isTrue,
        reason: 'without this the window is gone before onWindowClose runs',
      );

      service.onWindowClose();
      // The same sequence, awaited: `shutdown` is idempotent, so this is the
      // future the window's close path started, not a second one.
      await lifecycle.shutdown();
      await pumpEventQueue();

      expect(File(bridge).existsSync(), isFalse);
      expect(natives.window.destroyed, isTrue);
      expect(isDisposed(container), isTrue);
    });
  });
}

/// A control server that records when it was stopped, without binding a port.
class _RecordingControlServer extends LauncherControlServer {
  _RecordingControlServer(super.container, this._order);

  final List<String> _order;

  @override
  Future<void> stop() async {
    _order.add('control server');
    await super.stop();
  }
}
