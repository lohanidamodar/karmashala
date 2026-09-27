import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// One client link, as file work sees it: what a watch tells goes to it
/// alone (`files.watch` → [FileChanged]).
abstract interface class FileWatchLink {
  /// Tells this link — no other — [changes].
  void tell(List<DataChange> changes);
}

/// What answers the file work a client asks of the server
/// (`FilesWorkRequest`: listing, reading and writing a machine's files, the
/// Quick Open index, watches) — the server's files, set once `serve` has
/// built them.
abstract interface class FilesWork {
  /// Does [request]'s work for [link] and answers it; throws [DataRefused].
  Future<Object?> handle(FilesWorkRequest<Object?> request, FileWatchLink link);

  /// [link] closed: whatever it watched is dropped.
  void linkClosed(FileWatchLink link);
}
