import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/src/data/hosted_run_intents.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// What the server asks a window to show (slice 5b) goes to one desktop
/// client — the one a person last used — never to every client, and with
/// none connected the asker is told at once.
void main() {
  late AppDatabase database;
  late DataService data;

  setUp(() {
    database = AppDatabase.memory();
    data = DataService(database);
  });
  tearDown(() => database.close());

  ({List<DataChange> told, void Function() close, dynamic link}) window() {
    final told = <DataChange>[];
    final link = data.open((batch) => told.addAll(batch.changes));
    link.handle(const DataSubscribe());
    return (told: told, close: link.close, link: link);
  }

  test('with no desktop client, an intent is refused at once', () {
    expect(data.tellIntent(const SelectCheckout('r1')), isFalse);
    // A phone's companion link never subscribes: it is no window.
    data.open((_) {});
    expect(data.tellIntent(const SelectCheckout('r1')), isFalse);
  });

  test('the only window connected is told, alone', () {
    final a = window();
    expect(data.tellIntent(const SelectCheckout('r1')), isTrue);
    expect(a.told.whereType<SelectCheckout>().single.repositoryId, 'r1');
  });

  test('window A drops without a clean close, window B connects: intents '
      'go to B', () {
    final a = window();
    a.link.handle(const ClientActive(focusedPaneId: 'pa'));
    // A's transport died; nothing closed its link.
    final b = window();
    expect(data.tellIntent(const SelectCheckout('r1')), isTrue);
    expect(a.told.whereType<SelectCheckout>(), isEmpty);
    expect(b.told.whereType<SelectCheckout>(), hasLength(1));
    expect(data.focusedPaneId, isNull, reason: 'B has not said yet');
  });

  test('the window a person last acted in wins, with its focused pane', () {
    final a = window();
    final b = window();
    a.link.handle(const ClientActive(focusedPaneId: 'pa'));
    expect(data.focusedPaneId, 'pa');
    data.tellIntent(const OpenTerminalTab(paneId: 'x', title: 'x'));
    expect(a.told.whereType<OpenTerminalTab>(), hasLength(1));
    expect(b.told.whereType<OpenTerminalTab>(), isEmpty);
    b.link.handle(const ClientActive(focusedPaneId: 'pb'));
    expect(data.focusedPaneId, 'pb');
  });

  test('a closed window is never the target', () {
    final a = window();
    a.close();
    expect(data.tellIntent(const SelectCheckout('r1')), isFalse);
    expect(a.told.whereType<SelectCheckout>(), isEmpty);
  });

  test('an intent survives the envelope a remote window reads it through', () {
    final intent = OpenSessionTab(sessionId: 's1', title: 'Fix it');
    final back = DataChange.fromJson(intent.toJson());
    expect(back, isA<OpenSessionTab>());
    expect((back! as OpenSessionTab).sessionId, 's1');
  });

  test('a run the server starts is shown once, in the window last used', () {
    final a = window();
    HostedRunIntents(data).attach();
    final run = HostedRun(
      runId: 'r1',
      family: HostedRunFamily.flutter,
      title: 'flutter run',
      startedAt: DateTime.utc(2026),
    );
    data.announce([HostedRunChanged(run)]);
    data.announce([HostedRunChanged(run)]);
    expect(
      a.told.whereType<OpenTerminalTab>().map((i) => i.paneId),
      ['hosted-r1'],
    );
  });
}
