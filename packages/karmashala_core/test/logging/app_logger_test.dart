import 'package:karmashala_core/logging.dart';
import 'package:test/test.dart';
import 'package:logging/logging.dart';

void main() {
  group('AppLogger', () {
    test('routes messages at each level through the root handler', () {
      final records = <LogRecord>[];
      AppLogger.initialize(level: Level.ALL, onRecord: records.add);
      final logger = AppLogger.named('test');

      logger.debug('a debug message');
      logger.info('an info message');
      logger.warning('a warning message');
      logger.error('an error message');

      expect(records.map((r) => r.message), [
        'a debug message',
        'an info message',
        'a warning message',
        'an error message',
      ]);
      expect(records.every((r) => r.loggerName == 'test'), isTrue);
    });

    test('attaches error and stack trace to error records', () {
      final records = <LogRecord>[];
      AppLogger.initialize(level: Level.ALL, onRecord: records.add);
      final logger = AppLogger.named('errs');
      final stack = StackTrace.current;

      logger.error('boom', 'the-error', stack);

      expect(records.single.error, 'the-error');
      expect(records.single.stackTrace, stack);
    });
  });
}
