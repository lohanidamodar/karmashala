import 'package:test/test.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

AttachedApp _app(
  String id, {
  AppReachability reachability = AppReachability.attached,
  AppDiscovery discovery = AppDiscovery.uriFile,
}) => AttachedApp(
  id: id,
  uri: Uri.parse('ws://127.0.0.1:1/$id/ws'),
  discovery: discovery,
  reachability: reachability,
  observedAt: DateTime.utc(2026, 9, 8),
);

void main() {
  final looked = DateTime.utc(2026, 9, 8, 12);

  group('describeRegistry — the four sentences', () {
    test('"we have not looked" is not "nothing is running"', () {
      expect(
        describeRegistry(const FlutterAppRegistry()),
        'We have not looked for a running Flutter app yet.',
      );
      expect(
        describeRegistry(FlutterAppRegistry(lookedAt: looked)),
        'No Flutter app is running that we can see.',
      );
    });

    test('an address nothing answers on is its own sentence', () {
      final registry = FlutterAppRegistry(
        lookedAt: looked,
        apps: [_app('a', reachability: AppReachability.unreachable)],
      );
      expect(
        describeRegistry(registry),
        '1 address is on record and nothing answers on it.',
      );
    });

    test('a failure to look is never reported as a finding of nothing', () {
      final registry = FlutterAppRegistry(
        lookedAt: looked,
        discoveryFailure: 'access is denied',
      );
      expect(describeRegistry(registry), 'We could not look: access is denied');
    });

    test('several apps at once, with the dead ones counted separately', () {
      final registry = FlutterAppRegistry(
        lookedAt: looked,
        apps: [
          _app('a'),
          _app('b'),
          _app('c', reachability: AppReachability.ended),
        ],
      );
      expect(
        describeRegistry(registry),
        '2 Flutter apps attached, and 1 address nothing answers on.',
      );
    });
  });

  group('choosing an app', () {
    test('one attached app is the obvious one', () {
      final registry = FlutterAppRegistry(
        lookedAt: looked,
        apps: [
          _app('a'),
          _app('b', reachability: AppReachability.unreachable),
        ],
      );
      expect(registry.onlyAttached?.id, 'a');
    });

    test('two attached apps are not resolved by guessing', () {
      final registry = FlutterAppRegistry(
        lookedAt: looked,
        apps: [_app('a'), _app('b')],
      );
      expect(registry.onlyAttached, isNull);
    });
  });

  group('AttachedApp', () {
    test('one app reached two ways is one row', () {
      expect(
        AttachedApp.idFor(Uri.parse('ws://127.0.0.1:53119/tok=/ws')),
        AttachedApp.idFor(Uri.parse('ws://127.0.0.1:53119/tok=')),
      );
    });

    test('two runs on the same port are two rows', () {
      expect(
        AttachedApp.idFor(Uri.parse('ws://127.0.0.1:53119/one=/ws')),
        isNot(AttachedApp.idFor(Uri.parse('ws://127.0.0.1:53119/two=/ws'))),
      );
    });

    test('reachable is not the same as reloadable', () {
      final reachable = _app('a');
      expect(reachable.isAttached, isTrue);
      expect(
        reachable.canHotReload,
        isFalse,
        reason: 'no flutter_tools service is registered on this connection',
      );
      expect(
        reachable.copyWith(reloadMethod: 's1.reloadSources').canHotReload,
        isTrue,
      );
    });
  });
}
