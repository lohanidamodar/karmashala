import '../domain/detected_session.dart';
import 'codex_app_server_launch.dart';
import 'store_scan_slots.dart';

/// One CLI's on-disk session store, read into the shape detection speaks.
///
/// The seam that makes a new agent *data* rather than a branch: a descriptor
/// names an `AgentStoreFormat`, and `CliDetectionService` looks the reader up
/// by that format. Adding pi means adding a descriptor and, only if its layout
/// is genuinely new, one implementation of this.
abstract interface class StoreSessionReader {
  /// Reads every session under [storeHome], tagged with [environmentId].
  ///
  /// [directories] narrows the read to the store subdirectories with those
  /// (lowercased) names — an optimisation only a store whose layout is
  /// *addressable* from a working directory can honour, which today is Claude
  /// Code's alone. A reader that cannot narrow ignores it and reads everything;
  /// nothing is ever missed by passing it.
  ///
  /// [slots] bounds how many reads this call may have in flight. Null means
  /// unbounded, which is what a test that wants to see the bound work asks for.
  ///
  /// [appServer] says how to reach a store's own server rather than its files —
  /// a per-reader hint in the same spirit as [directories], and today Codex's
  /// alone. A reader that has no server ignores it and walks the store.
  Future<List<DetectedSession>> read(
    String storeHome,
    String environmentId, {
    Set<String>? directories,
    StoreScanSlots? slots,
    CodexAppServerLaunch? appServer,
  });
}
