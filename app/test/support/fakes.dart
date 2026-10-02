import 'package:agent_cli/discovery.dart' as agent_cli;
import 'package:karmashala_core/paths.dart';
import 'package:karmashala_core/util.dart';

/// A [Clock] that always returns a fixed instant.
///
/// It implements the package's copy of the interface as well as core's.
/// `agent_cli` is published and carries verbatim copies of `Clock` and
/// `IdGenerator` rather than depending on `karmashala_core` for them;
/// one fake satisfying both is what keeps every
/// suite that pins a time or an id on a single double.
class FixedClock implements Clock, agent_cli.Clock {
  FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime nowUtc() => _now.toUtc();
}

/// A [Clock] a test can move, for the schedules a fixed instant cannot show.
///
/// Satisfies both copies of the interface, for the same reason [FixedClock]
/// does.
class MovableClock implements Clock, agent_cli.Clock {
  MovableClock(this.now);

  DateTime now;

  @override
  DateTime nowUtc() => now.toUtc();

  void advance(Duration by) => now = now.add(by);
}

/// An [IdGenerator] that returns predictable, sequential ids (`id-0`, `id-1`…).
class SequentialIdGenerator implements IdGenerator, agent_cli.IdGenerator {
  SequentialIdGenerator([this._prefix = 'id-']);
  final String _prefix;
  int _next = 0;
  @override
  String newId() => '$_prefix${_next++}';
}



/// A disk on which every recorded path opens and nothing is a reparse point.
///
/// The launcher checks the agent's executable before it spawns anything
/// (CLAUDE.md §20), and the fixtures spell paths like `C:\Users\me\.bin` that
/// no machine has — so without this every suite that starts a session would be
/// refused, and would be refused differently on a host that happened to have
/// one of them. Tests that are *about* the check describe their own disk.
class EveryPathOpens implements PathProbe {
  const EveryPathOpens();

  @override
  bool? fileExists(String path) => true;

  @override
  bool isLink(String path) => false;

  @override
  String? linkTarget(String path) => null;
}

/// The one every test shares; see [EveryPathOpens].
const everyPathOpens = EveryPathOpens();
