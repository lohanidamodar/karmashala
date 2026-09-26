import 'package:karmashala/src/features/environments/application/system_health.dart';
import 'package:karmashala/src/features/environments/application/system_health_service.dart';

/// A [SystemHealthController] that already holds a reading and never probes.
///
/// The real controller spawns the MCP bridge, a shell inside every WSL
/// distribution, `adb`, and a volume query. A widget test wants the rows those
/// produce, not the processes, so it is handed a finished report — and
/// [refresh] is a no-op rather than a fake success, so a test cannot
/// accidentally assert on a check that never ran.
class FixedSystemHealthController extends SystemHealthController {
  FixedSystemHealthController(this.report);

  final SystemHealthReport report;

  @override
  SystemHealthReport build() => report;

  @override
  Future<void> refresh() async {}
}
