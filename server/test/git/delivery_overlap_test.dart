import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/mcp/tools/checkout_delivery.dart';
import 'package:karmashala_host/src/mcp/tools/checkout_reach.dart';
import 'package:test/test.dart';

import '../mcp/tools/repo_tool_fixture.dart';

/// **A delivery reading's two comparisons against the base run together.**
///
/// `git rev-list --left-right --count` and `git diff --numstat` ask different
/// questions of the same base and neither needs the other's answer; the
/// reading every checkout pays for (`git.delivery`, the delivery strip, every
/// Explorer row) once awaited one before starting the other. Counted, not
/// timed: each command yields before it runs, and what was in flight at that
/// moment is recorded.
void main() {
  late RepoToolFixture f;

  setUp(() => f = RepoToolFixture());
  tearDown(() => f.dispose());

  test('rev-list and diff --numstat are in flight at once', () async {
    final app = f.repository(f.path('work/app'));
    f.origin(app);
    final overlap = _Overlap();
    final reader = CheckoutDeliveryReader(
      CheckoutReach(f.database, runners: overlap),
    );

    final delivery = await reader.local(f.here(app));

    expect(delivery.baseBranch, 'origin/main', reason: 'a base was read');
    expect(
      overlap.together.any(
        (set) => set.contains('rev-list') && set.contains('--numstat'),
      ),
      isTrue,
      reason: 'seen in flight: ${overlap.together}',
    );
  });
}

/// Runs git for real, yielding once before each command and recording which
/// of the two comparisons were in flight together.
class _Overlap extends CommandRunnerFactory {
  final _inFlight = <String>{};
  final together = <Set<String>>[];

  @override
  CommandRunner forEnvironment(ExecutionEnvironment environment) =>
      _Runner(super.forEnvironment(environment), this);
}

class _Runner implements CommandRunner {
  _Runner(this._inner, this._overlap);

  final CommandRunner _inner;
  final _Overlap _overlap;

  @override
  String get environmentId => _inner.environmentId;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    final args = request.arguments;
    final key = args.contains('rev-list')
        ? 'rev-list'
        : args.contains('--numstat')
        ? '--numstat'
        : null;
    if (key != null) _overlap._inFlight.add(key);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (key != null) _overlap.together.add({..._overlap._inFlight});
    try {
      return await _inner.run(request);
    } finally {
      if (key != null) _overlap._inFlight.remove(key);
    }
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) => _inner.start(request);
}
