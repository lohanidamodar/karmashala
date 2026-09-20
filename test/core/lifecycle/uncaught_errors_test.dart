import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/lifecycle/uncaught_errors.dart';
import 'package:karmashala_core/logging.dart';
import 'package:logging/logging.dart';

void main() {
  late List<LogRecord> records;
  late UncaughtErrorHandlers handlers;

  setUp(() {
    records = [];
    AppLogger.initialize(level: Level.ALL, onRecord: records.add);
    handlers = UncaughtErrorHandlers(AppLogger.named('test'), repeatBound: 3);
    handlers.install();
  });

  tearDown(() {
    handlers.uninstall();
    AppLogger.initialize();
  });

  test('an uncaught async error is logged as severe and marked handled', () {
    final handled = PlatformDispatcher.instance.onError!(
      StateError('boom'),
      StackTrace.current,
    );
    expect(handled, isTrue);
    expect(records, hasLength(1));
    expect(records.single.level, Level.SEVERE);
    expect(records.single.message, 'Uncaught error');
    expect(records.single.error, isA<StateError>());
    expect(records.single.stackTrace, isNotNull);
  });

  test('a framework error is logged with its context', () {
    FlutterError.onError!(
      FlutterErrorDetails(
        exception: ArgumentError('bad'),
        context: ErrorDescription('building Foo'),
      ),
    );
    expect(records.single.message, 'Flutter error (building Foo)');
    expect(records.single.error, isA<ArgumentError>());
  });

  test('the same error past the bound is counted, not written', () {
    for (var i = 0; i < 10; i++) {
      PlatformDispatcher.instance.onError!(
        StateError('same'),
        StackTrace.empty,
      );
    }
    expect(records, hasLength(3));
    expect(records.last.message, contains('further repeats withheld'));
    expect(handlers.suppressed, 7);

    PlatformDispatcher.instance.onError!(
      StateError('different'),
      StackTrace.empty,
    );
    expect(records, hasLength(4));
  });

  test('uninstall restores what was there', () {
    final mine = handlers;
    bool marker(Object e, StackTrace s) => false;
    mine.uninstall();
    PlatformDispatcher.instance.onError = marker;
    final again = UncaughtErrorHandlers(AppLogger.named('test'))..install();
    expect(PlatformDispatcher.instance.onError, isNot(equals(marker)));
    again.uninstall();
    expect(PlatformDispatcher.instance.onError, equals(marker));
    PlatformDispatcher.instance.onError = null;
    mine.install();
  });
}
