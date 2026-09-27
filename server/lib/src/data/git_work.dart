import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What answers the git a client asks the server to do (`GitWorkRequest`:
/// reads and writes of a checkout, worktrees, their cleanup, GitHub) — the
/// server's git components, set once `serve` has built them.
abstract interface class GitWork {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(GitWorkRequest<Object?> request);
}
