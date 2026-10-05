import 'package:agent_cli/read.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 10, 5, 1, 50);

BackgroundRun _run(String id, BackgroundRunState state, {DateTime? endedAt}) =>
    BackgroundRun(
      id: id,
      kind: BackgroundRunKind.agent,
      state: state,
      description: 'Sleep then report',
      endedAt: endedAt,
    );

/// Whether a session that went idle is still waiting on what it started in
/// the background — the rule its status, inbox and phone share.
void main() {
  test('nothing in the background is no wait', () {
    expect(waitsOnBackground(const [], idleAt: _t0, now: _t0), isFalse);
  });

  test('a run still running is a wait', () {
    expect(
      waitsOnBackground(
        [
          _run('a1', BackgroundRunState.running),
          _run(
            'a0',
            BackgroundRunState.completed,
            endedAt: _t0.subtract(const Duration(minutes: 5)),
          ),
        ],
        idleAt: _t0,
        now: _t0.add(const Duration(minutes: 3)),
      ),
      isTrue,
    );
  });

  test('the last one ended: a wait until the turn after it ends', () {
    final ended = _t0.add(const Duration(seconds: 90));
    final runs = [_run('a1', BackgroundRunState.completed, endedAt: ended)];
    expect(
      waitsOnBackground(
        runs,
        idleAt: _t0,
        now: ended.add(const Duration(seconds: 2)),
      ),
      isTrue,
      reason: 'the idle is from before it ended: its own turn has not run',
    );
    expect(
      waitsOnBackground(
        runs,
        idleAt: ended.add(const Duration(seconds: 3)),
        now: ended.add(const Duration(seconds: 4)),
      ),
      isFalse,
      reason: 'the turn after it ended',
    );
  });

  test('no turn after the last end: the wait gives up after the grace', () {
    final ended = _t0.add(const Duration(seconds: 90));
    final runs = [_run('a1', BackgroundRunState.ended)];
    expect(
      waitsOnBackground(
        runs,
        idleAt: _t0,
        now: ended.add(kBackgroundTurnGrace),
      ),
      isFalse,
      reason: 'no end time was recorded, so nothing is awaited',
    );
    final completed = [
      _run('a1', BackgroundRunState.completed, endedAt: ended),
    ];
    expect(
      waitsOnBackground(
        completed,
        idleAt: _t0,
        now: ended.add(kBackgroundTurnGrace),
      ),
      isFalse,
    );
  });
}
