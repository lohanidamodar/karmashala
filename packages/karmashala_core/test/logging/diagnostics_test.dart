import 'package:karmashala_core/logging.dart';
import 'package:test/test.dart';
import 'package:logging/logging.dart';

/// A buffer that fails the way a sink fails: on the caller's thread.
class _BrokenBuffer extends LogRingBuffer {
  _BrokenBuffer() : super(capacity: kMinLogBufferCapacity);

  @override
  void add(LogEntry entry) => throw StateError('sink is broken');
}

void main() {
  late Diagnostics previous;

  setUp(() => previous = Diagnostics.instance);
  tearDown(() {
    Diagnostics.instance = previous;
    Logger.root.level = Level.INFO;
  });

  group('Diagnostics fan-out', () {
    test('a record logged through AppLogger lands in the buffer', () {
      final diagnostics = Diagnostics(echoToConsole: false);
      Diagnostics.instance = diagnostics;
      AppLogger.initialize(level: Level.ALL);

      AppLogger.named('remote').warning('pairing failed', 'timeout');

      final held = diagnostics.buffer.snapshot();
      expect(held, hasLength(1));
      expect(held.single.channel, 'remote');
      expect(held.single.level, Level.WARNING);
      expect(held.single.message, 'pairing failed');
      expect(held.single.error, 'timeout');
    });

    test('the entry is in the buffer the moment the caller returns', () {
      // The point of the whole sink design: logging is a synchronous store, so
      // nothing that logs is waiting on a disk, a frame or a microtask.
      final diagnostics = Diagnostics(echoToConsole: false);
      Diagnostics.instance = diagnostics;
      AppLogger.initialize(level: Level.ALL);

      AppLogger.named('sessions').info('created session s-1');

      expect(diagnostics.buffer.length, 1);
    });

    test('a sink that throws never reaches the caller', () {
      final diagnostics = Diagnostics(
        buffer: _BrokenBuffer(),
        echoToConsole: false,
      );
      Diagnostics.instance = diagnostics;
      AppLogger.initialize(level: Level.ALL);

      expect(
        () => AppLogger.named('remote').warning('still fine'),
        returnsNormally,
      );
    });

    test('initialising twice does not double every line', () {
      final diagnostics = Diagnostics(echoToConsole: false);
      Diagnostics.instance = diagnostics;
      AppLogger.initialize(level: Level.ALL);
      AppLogger.initialize(level: Level.ALL);

      AppLogger.named('remote').info('once');

      expect(diagnostics.buffer.length, 1);
    });

    test('warnings are recorded with debug mode off (root at INFO)', () {
      // The buffer has to be filling *before* anybody opens the panel —
      // otherwise seeing a failure means reproducing it first.
      final diagnostics = Diagnostics(echoToConsole: false);
      Diagnostics.instance = diagnostics;
      AppLogger.initialize();

      final logger = AppLogger.named('ssh.connection');
      logger.debug('a fine detail');
      logger.warning('host unreachable');

      expect(diagnostics.buffer.snapshot().map((e) => e.message), [
        'host unreachable',
      ]);
    });

    test('a token never reaches the buffer', () {
      // The buffer is the source for the panel, the clipboard, the report and
      // the log file, so this is the one place the invariant has to hold.
      const token = 'sk-ant-api03-Zx9Qw8Lm2Nv4Bt7Rk1Cy6Hd0Sf3Jg5Pu-AA';
      const hostKey =
          'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH4tFbGqDLrRcYqPZ0mQeRs7WvKjBn';
      final diagnostics = Diagnostics(echoToConsole: false);
      Diagnostics.instance = diagnostics;
      AppLogger.initialize(level: Level.ALL);

      AppLogger.named('claude-auth').warning('refresh failed for $token');
      AppLogger.named('ssh.hostkey').warning('mismatch', 'host key $hostKey');
      AppLogger.named(
        'remote',
      ).warning('giving up', StateError(r'at C:\Users\dlohani\.karmashala'));

      final text = diagnostics.buffer
          .snapshot()
          .map((e) => e.format())
          .join('\n');
      expect(text, isNot(contains(token)));
      expect(text, isNot(contains('AAAAC3NzaC1lZDI1NTE5')));
      expect(text, isNot(contains('dlohani')));
      expect(text, contains('[redacted:token]'));
      expect(text, contains('[redacted:key]'));
      expect(text, contains(r'C:\Users\<user>'));
    });

    test(
      'a flood is absorbed at the bound without the caller paying for it',
      () {
        final diagnostics = Diagnostics(
          buffer: LogRingBuffer(capacity: 1000),
          echoToConsole: false,
        );
        Diagnostics.instance = diagnostics;
        AppLogger.initialize(level: Level.ALL);
        final logger = AppLogger.named('device-stream');

        final watch = Stopwatch()..start();
        for (var i = 0; i < 50000; i++) {
          logger.info('frame $i');
        }
        watch.stop();

        expect(diagnostics.buffer.length, 1000);
        expect(diagnostics.buffer.dropped, 49000);
        expect(diagnostics.buffer.snapshot().last.message, 'frame 49999');
        // Generous by two orders of magnitude: this is a smoke alarm for a sink
        // that has started doing I/O on the caller's thread, not a benchmark.
        expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      },
    );
  });
}
