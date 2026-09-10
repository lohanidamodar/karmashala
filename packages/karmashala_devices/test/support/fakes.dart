import 'package:agent_cli/discovery.dart' as agent_cli;
import 'package:karmashala_core/util.dart';

/// The instant every suite here pins, so a rendered age is the same string on
/// every machine and in every year.
final testTime = DateTime.utc(2026, 1, 2, 3, 4, 5);

/// A [Clock] that always returns a fixed instant. It satisfies `agent_cli`'s
/// verbatim copy of the interface as well as core's — see PACKAGE_SPLIT.md §2
/// for why there are two.
class FixedClock implements Clock, agent_cli.Clock {
  FixedClock(this._now);

  final DateTime _now;

  @override
  DateTime nowUtc() => _now.toUtc();
}
