import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/lifecycle/before_quit.dart';
import 'package:karmashala/src/features/system/system_integration_service.dart';
import 'package:karmashala_store/database.dart';

import '../../features/system/fake_native_adapters.dart';

/// What a feature can ask of a quit: a question that may cancel it, and a
/// write that lands before the shutdown — bounded, and once per quit.
void main() {
  group('BeforeQuitHooks', () {
    test(
      'a guard that says no cancels, and the ones after it are not asked',
      () async {
        final hooks = BeforeQuitHooks();
        final asked = <String>[];
        hooks
          ..addGuard('first', () async {
            asked.add('first');
            return false;
          })
          ..addGuard('second', () async {
            asked.add('second');
            return true;
          });

        expect(await hooks.confirm(), isFalse);
        expect(asked, ['first']);
      },
    );

    test('a guard that throws does not hold the quit', () async {
      final hooks = BeforeQuitHooks()
        ..addGuard('broken', () async => throw StateError('no navigator'));

      expect(await hooks.confirm(), isTrue);
    });

    test('a removed hook no longer runs', () async {
      final hooks = BeforeQuitHooks();
      var flushed = 0;
      final remove = hooks.addFlush('drafts', () => flushed++);
      remove();

      await hooks.flush();
      expect(flushed, 0);
    });

    test('a flush that never finishes is left behind at the budget', () async {
      final hooks = BeforeQuitHooks(
        flushBudget: const Duration(milliseconds: 50),
      );
      var quick = false;
      hooks
        ..addFlush('stuck database', () => Completer<void>().future)
        ..addFlush('quick', () => quick = true)
        ..addFlush('throws', () => throw StateError('disk full'));

      final watch = Stopwatch()..start();
      await hooks.flush();

      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(quick, isTrue, reason: 'one stuck flush does not starve another');
    });
  });

  group('quitting', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = AppDatabase.memory();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          beforeQuitHooksProvider.overrideWithValue(
            BeforeQuitHooks(flushBudget: const Duration(milliseconds: 50)),
          ),
        ],
      );
    });
    tearDown(() {
      container.dispose();
      db.close();
    });

    BeforeQuitHooks hooks() => container.read(beforeQuitHooksProvider);

    SystemIntegrationService service(
      List<String> order, {
      void Function()? ended,
    }) => SystemIntegrationService(
      container,
      adapters: FakeNatives().adapters,
      registerOsQuit: (_) {},
      endProcess: ended ?? () {},
      onQuitRequested: () async => order.add('shutdown'),
    );

    test('the hooks run once per quit, before the shutdown', () async {
      final order = <String>[];
      hooks()
        ..addGuard('ask', () async {
          order.add('guard');
          return true;
        })
        ..addFlush('write', () => order.add('flush'));
      final quitting = service(order);

      await Future.wait([quitting.quit(), quitting.quit()]);
      await quitting.quit();

      expect(order, ['guard', 'flush', 'shutdown']);
    });

    test(
      'a guard that cancels keeps the app open, and a later quit still goes',
      () async {
        final order = <String>[];
        var answer = false;
        var ended = 0;
        hooks()
          ..addGuard('ask', () async => answer)
          ..addFlush('write', () => order.add('flush'));
        final quitting = service(order, ended: () => ended++);

        await quitting.quit();
        expect(order, isEmpty);
        expect(ended, 0);

        answer = true;
        await quitting.quit();
        expect(order, ['flush', 'shutdown']);
        expect(ended, 1);
      },
    );

    test(
      'asking again while the question is up only raises the window',
      () async {
        final order = <String>[];
        final answer = Completer<bool>();
        var asked = 0;
        hooks().addGuard('ask', () {
          asked++;
          return answer.future;
        });
        final natives = FakeNatives()..window.visible = false;
        final quitting = SystemIntegrationService(
          container,
          adapters: natives.adapters,
          registerOsQuit: (_) {},
          endProcess: () {},
          onQuitRequested: () async => order.add('shutdown'),
        );

        final first = quitting.quit();
        await pumpEventQueue();
        await quitting.quit();

        expect(asked, 1);
        expect(natives.window.calls, contains('show'));
        expect(order, isEmpty);

        answer.complete(true);
        await first;
        expect(order, ['shutdown']);
      },
    );

    test('a flush that hangs does not stop the quit', () async {
      final order = <String>[];
      hooks().addFlush('stuck', () => Completer<void>().future);
      var ended = 0;

      await service(order, ended: () => ended++).quit();

      expect(order, ['shutdown']);
      expect(ended, 1);
    });
  });

  testWidgets('an exit the engine asks about is answered by the one quit', (
    tester,
  ) async {
    var quits = 0;
    final listener = listenForExitRequests(() async => quits++);
    addTearDown(listener.dispose);

    final response = await tester.binding.handleRequestAppExit();

    expect(response, AppExitResponse.cancel);
    expect(quits, 1);
  });
}
