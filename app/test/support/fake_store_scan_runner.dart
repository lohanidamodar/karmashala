import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/cli_detection/data/store_scan_worker.dart';

/// A [StoreScanRunner] that answers every scan with a fixed list, so a test
/// never walks the machine's own stores, and counts the scans asked of it.
class FixedScanRunner implements StoreScanRunner {
  FixedScanRunner(this.sessions);

  final List<DetectedSession> sessions;

  /// How many scans were asked: the number a batch exists to keep at one.
  int scans = 0;

  @override
  Stream<StoreScanChunk> scan(StoreScanRequest request) async* {
    scans++;
    yield StoreScanChunk(
      agentId: 'fixed',
      environmentId: 'fixed',
      sessions: List.of(sessions),
      isolate: kStoreScanIsolateName,
    );
  }

  @override
  Future<void> shutdown() async {}
}
