import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/lifecycle/app_lifecycle.dart';
import 'package:karmashala_core/logging.dart';

import '../../features/system/fake_native_adapters.dart';

/// A quit that cannot describe itself.
///
/// The 2026-09-09 app soak counted 20 launches, 17 `window close` lines and 8
/// `shutdown in N ms` lines: `lifecycle`'s account of its own quit was missing
/// more often than it was present. `LogFileSink.add` arms a 400 ms timer and
/// that timer is a task for *this* isolate, so a line logged in the last
/// stretch of a quit dies with the process unless somebody asks for it — and
/// the flush that used to ask was itself a shutdown step, bounded by the same
/// deadline it was reporting on. So exactly the quits that overran their budget
/// were the ones that lost their own record, which is the wrong way round.
///
/// Both cases below read the file **from inside `endProcess`**, which is the
/// only moment that matters: one instruction later there is no isolate.
void main() {
  late Directory dir;
  late Diagnostics previous;
  late LogFileSink sink;
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('karmashala-quitlog');
    previous = Diagnostics.instance;
    Diagnostics.instance = Diagnostics();
    AppLogger.initialize(onRecord: Diagnostics.instance.handle);
    sink = LogFileSink(directory: dir);
    Diagnostics.instance.attachFile(sink);
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    await sink.close();
    Diagnostics.instance = previous;
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String logOnDisk() =>
      sink.file.existsSync() ? sink.file.readAsStringSync() : '';

  /// Drives the **window's X**, not the tray's Quit: `onWindowClose` is the
  /// route a real quit takes and the one the soak's `CloseMainWindow` posts,
  /// and it returns before any of the teardown has run. What is awaited is the
  /// process ending, which is the last thing that happens and the only moment
  /// worth reading the file at.
  Future<String> closeTheWindowCapturingTheLog({Duration? budget}) async {
    final ended = Completer<String>();
    final lifecycle = AppLifecycle(container, shutdownBudget: budget);
    final natives = FakeNatives();
    final service = await lifecycle.startSystemIntegration(
      adapters: natives.adapters,
      registerOsQuit: (_) {},
      endProcess: () => ended.complete(logOnDisk()),
    );
    service.onWindowClose();
    return ended.future;
  }

  test('the shutdown line is on disk before the process is ended', () async {
    final atExit = await closeTheWindowCapturingTheLog();

    expect(
      atExit,
      contains('lifecycle: shutdown in'),
      reason: 'the quit ended before its own account reached the file',
    );
    expect(atExit, contains('window close → quit'));
  });

  test('a shutdown that spends its budget still writes its own account', () async {
    // The regression this replaces, exactly: the flush was a `_step`, and
    // `_step` bounds every action by what is left of the shared deadline. With
    // none left it logged `skipped log flush` — into the queue that was about
    // to be dropped — and the whole tail of the quit went with it.
    final atExit = await closeTheWindowCapturingTheLog(budget: Duration.zero);

    expect(
      atExit,
      contains('lifecycle: shutdown in'),
      reason: 'the quits worth reading are the ones that overran',
    );
    expect(
      atExit,
      contains('skipped'),
      reason: 'and the skips that explain why they overran',
    );
  });
}
