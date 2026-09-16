import 'dart:async';
import 'dart:io';

import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('karmashala-dtd'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String under(String relative) =>
      '${root.path}${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}';

  void writePidFile(String directory, int pid, {required int epoch}) {
    Directory(directory).createSync(recursive: true);
    File('$directory${Platform.pathSeparator}$pid').writeAsStringSync(
      '{"wsUri":"ws://127.0.0.1:$pid/t=","epoch":$epoch,"pid":$pid,'
      '"workspaceRoot":"/w/$pid"}',
    );
  }

  group('scanning', () {
    test('reads every candidate directory, newest first, once per pid', () {
      final state = under('state/Dart/dtd');
      final data = under('data/dtd');
      writePidFile(state, 11, epoch: 1000);
      writePidFile(state, 12, epoch: 3000);
      writePidFile(data, 21, epoch: 2000);
      // The same daemon seen through two candidates is one daemon.
      writePidFile(data, 11, epoch: 1000);

      final found = DtdPidFiles([data, under('missing/dtd'), state]).scan();

      expect(found.map((instance) => instance.pid), [12, 21, 11]);
    });

    test('no candidates is nothing, not an error', () {
      expect(const DtdPidFiles(<String>[]).scan(), isEmpty);
    });
  });

  group('watching', () {
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 300));

    Future<void> waitFor(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test(
      'a directory that exists fires when a daemon writes itself down',
      () async {
        final dtd = under('Dart/dtd');
        Directory(dtd).createSync(recursive: true);
        var fired = 0;
        final subscription = DtdPidFiles([
          dtd,
        ]).changes().listen((_) => fired++);
        addTearDown(subscription.cancel);
        await settle();

        writePidFile(dtd, 42, epoch: 1);
        await waitFor(() => fired > 0);

        expect(fired, greaterThan(0));
      },
    );

    test('a directory missing at startup is noticed once the first daemon '
        'creates it', () async {
      final dtd = under('Dart/dtd');
      final pidFiles = DtdPidFiles([dtd]);
      var fired = 0;
      final subscription = pidFiles.changes().listen((_) => fired++);
      addTearDown(subscription.cancel);
      await settle();
      expect(fired, 0);

      // What the SDK does: createSync(recursive: true), then the file.
      writePidFile(dtd, 42, epoch: 1);
      await waitFor(() => fired > 0 && pidFiles.scan().isNotEmpty);
      expect(fired, greaterThan(0));
      expect(pidFiles.scan().single.pid, 42);

      // And the watch is now on the directory itself.
      fired = 0;
      await settle();
      fired = 0;
      writePidFile(dtd, 43, epoch: 2);
      await waitFor(() => fired > 0);
      expect(fired, greaterThan(0));
    });

    test('a directory deleted and made again is still watched', () async {
      final dtd = under('Dart/dtd');
      Directory(dtd).createSync(recursive: true);
      var fired = 0;
      final subscription = DtdPidFiles([dtd]).changes().listen((_) => fired++);
      addTearDown(subscription.cancel);
      await settle();

      Directory(under('Dart')).deleteSync(recursive: true);
      await settle();
      fired = 0;
      writePidFile(dtd, 44, epoch: 1);
      await waitFor(() => fired > 0);

      expect(fired, greaterThan(0));
    });

    test('cancelling stops the watch', () async {
      final dtd = under('Dart/dtd');
      var fired = 0;
      final subscription = DtdPidFiles([dtd]).changes().listen((_) => fired++);
      await settle();
      await subscription.cancel();

      writePidFile(dtd, 45, epoch: 1);
      await settle();

      expect(fired, 0);
    });
  });
}
