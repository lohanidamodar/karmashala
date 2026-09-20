import 'package:test/test.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

import './fake_vm_service.dart';

AppLogRecord _line(
  String message, {
  AppLogSource source = AppLogSource.stdout,
}) => AppLogRecord(
  source: source,
  at: DateTime.utc(2026, 9, 8),
  message: message,
);

void main() {
  group('AppLogBuffer', () {
    test('counts what it dropped rather than timing anything', () {
      final buffer = AppLogBuffer(capacity: 3);
      for (var i = 0; i < 5; i++) {
        buffer.add(_line('line $i'));
      }
      expect(buffer.length, 3);
      expect(buffer.dropped, 2);
      expect(buffer.records.first.message, 'line 2');
    });

    test('a tail is the newest lines, oldest first', () {
      final buffer = AppLogBuffer();
      for (var i = 0; i < 10; i++) {
        buffer.add(_line('line $i'));
      }
      expect(buffer.tail(limit: 3).map((r) => r.message), [
        'line 7',
        'line 8',
        'line 9',
      ]);
    });

    test('a tail can be narrowed to one origin', () {
      final buffer = AppLogBuffer()
        ..add(_line('out'))
        ..add(_line('boom', source: AppLogSource.stderr))
        ..add(_line('out again'));
      expect(
        buffer.tail(sources: const {AppLogSource.stderr}).map((r) => r.message),
        ['boom'],
      );
    });
  });

  group('summariseFlutterError', () {
    test('uses the summary node the framework marked, not the category', () {
      final record = summariseFlutterError(
        flutterErrorTree(),
        at: DateTime.utc(2026, 9, 8),
      );
      expect(
        record.message,
        'The following StateError was thrown building Boom:',
      );
      expect(record.source, AppLogSource.flutterError);
      expect(record.isError, isTrue);
      expect(record.detail, contains('Bad state: broken'));
    });

    test('falls back to the category when there is no summary node', () {
      final record = summariseFlutterError(const <Object?, Object?>{
        'description': 'Exception caught by rendering library',
      }, at: DateTime.utc(2026, 9, 8));
      expect(record.message, 'Exception caught by rendering library');
    });

    test('bounds the body, because a diagnostics tree has no bound', () {
      final record = summariseFlutterError(
        flutterErrorTree(body: List<String>.generate(200, (i) => 'frame $i')),
        at: DateTime.utc(2026, 9, 8),
        detailLines: 5,
      );
      expect(record.detail!.split('\n'), hasLength(5));
    });

    test('says something rather than nothing for an empty payload', () {
      final record = summariseFlutterError(
        const <Object?, Object?>{},
        at: DateTime.utc(2026, 9, 8),
      );
      expect(record.message, isNotEmpty);
    });
  });
}
