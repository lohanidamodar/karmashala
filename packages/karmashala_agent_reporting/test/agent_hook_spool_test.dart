import 'dart:io';

import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'support/temp_directory.dart';

/// Reading back what a WSL agent's hook script wrote.
///
/// The writer is four lines of `sh` in `AgentHookInstaller._posixScript` and
/// runs on the other side of a `\\wsl.localhost` share; this is the half that
/// runs here. `live_wsl_hook_test.dart` proves the two agree against a real
/// distribution — these cases pin what this half does with what it finds,
/// including the shapes a real one cannot be made to produce on demand.
void main() {
  const spool = AgentHookSpool();
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('karmashala_spool_'));
  tearDown(() => removeTempDirectory(dir));

  /// One payload, in the envelope the script writes: two headers, a blank
  /// line, then the agent's own JSON verbatim.
  File write(
    String name,
    String body, {
    String agent = 'claudeCode',
    String event = 'Stop',
    DateTime? at,
  }) {
    final file = File(p.join(dir.path, name))
      ..writeAsStringSync('agent=$agent\nevent=$event\n\n$body');
    if (at != null) file.setLastModifiedSync(at);
    return file;
  }

  test('reads a payload, and takes it off disk', () async {
    write('100-0.json', '{"session_id":"s1"}');

    final events = await spool.drain(dir);

    expect(events, hasLength(1));
    expect(events.single.agentId, 'claudeCode');
    expect(events.single.event, 'Stop');
    expect(events.single.body, '{"session_id":"s1"}');
    expect(
      dir.listSync(),
      isEmpty,
      reason: 'a payload read twice is a status reported twice',
    );
  });

  test('the payload is timed by its own file, not by the drain', () async {
    // What makes an unclean exit harmless. A backlog drained on the next launch
    // carries its real age, so the five-minute window in `AgentStatusService`
    // discards it instead of announcing a stale status as news.
    final long = DateTime.now().subtract(const Duration(hours: 3));
    write('100-0.json', '{}', at: long);

    final drained = (await spool.drain(dir)).single;

    expect(
      drained.firedAt.difference(long).abs(),
      lessThan(const Duration(seconds: 2)),
    );
  });

  test('oldest first, because order is the whole meaning', () async {
    // `PreToolUse` then `Stop` read in the other order leaves a finished
    // session saying `working` until the next event happens to arrive.
    final base = DateTime.now().subtract(const Duration(minutes: 1));
    write('7-0.json', '{"n":2}', event: 'Stop', at: base.add(const Duration(seconds: 2)));
    write('3-0.json', '{"n":1}', event: 'PreToolUse', at: base);
    write('9-0.json', '{"n":3}', event: 'SessionEnd', at: base.add(const Duration(seconds: 4)));

    expect(
      (await spool.drain(dir)).map((e) => e.event),
      ['PreToolUse', 'Stop', 'SessionEnd'],
    );
  });

  test('a half-written payload is not read at all', () async {
    // The script writes `<pid>-<n>.part` and renames it, so a `.json` is
    // always whole. Reading a `.part` would hand the receiver truncated JSON
    // and lose the event when the rename landed a millisecond later.
    File(p.join(dir.path, '5-0.part')).writeAsStringSync('agent=claudeCode\nev');

    expect(await spool.drain(dir), isEmpty);
    expect(
      File(p.join(dir.path, '5-0.part')).existsSync(),
      isTrue,
      reason: 'and it is left for the rename that is about to happen',
    );
  });

  test('a payload it cannot parse is removed, not left to accumulate', () async {
    // It will not become parseable, and the script's own cap cannot see it.
    File(p.join(dir.path, '5-0.json')).writeAsStringSync('not an envelope');

    expect(await spool.drain(dir), isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test('a payload with no headers, or half of them, is refused', () {
    for (final raw in [
      '\n{"session_id":"s"}',
      'agent=claudeCode\n\n{}',
      'event=Stop\n\n{}',
      'agent=claudeCode\nevent=Stop\n{}',
    ]) {
      expect(spool.parse(raw, firedAt: DateTime.now()), isNull, reason: raw);
    }
  });

  test('a payload that starts with a header line is still the payload', () {
    // The blank line is the terminator, so the body is taken whole — a JSON
    // document that happens to contain `event=` is not a second header.
    final parsed = spool.parse(
      'agent=codex\nevent=Stop\n\nevent=not-a-header\n',
      firedAt: DateTime.now(),
    );

    expect(parsed!.agentId, 'codex');
    expect(parsed.body, 'event=not-a-header\n');
  });

  test('one drain is bounded, and the rest waits for the next', () async {
    // A launch that finds a backlog from an unclean exit must not hold the
    // isolate while it reads all of it over a 9p share.
    final base = DateTime.now().subtract(const Duration(minutes: 1));
    for (var i = 0; i < 10; i++) {
      write('$i-0.json', '{"n":$i}', at: base.add(Duration(seconds: i)));
    }

    expect(await spool.drain(dir, limit: 4), hasLength(4));
    expect(dir.listSync(), hasLength(6));
    expect((await spool.drain(dir, limit: 4)).first.body, '{"n":4}');
  });

  test('a directory that is not there is nothing to do, not an error', () async {
    // The exit path deletes it, and a distribution can go away mid-tick.
    expect(await spool.drain(Directory(p.join(dir.path, 'gone'))), isEmpty);
  });

  test('anything that is not a payload is left where it is', () async {
    File(p.join(dir.path, 'notes.txt')).writeAsStringSync('hello');
    Directory(p.join(dir.path, 'nested')).createSync();

    expect(await spool.drain(dir), isEmpty);
    expect(dir.listSync(), hasLength(2));
  });
}
