import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/domain/environment_path.dart';

/// Shows [path] in the desktop's own file manager.
typedef RevealInFileManager = Future<void> Function(EnvironmentPath path);

/// The seam the Explorer's "Open in File Explorer" goes through.
///
/// **The default does nothing on purpose.** Launching a file manager is a shell
/// capability, not a tree's — it needs `explorer.exe` / `open` / `xdg-open`, the
/// WSL path translation for a `/home/...` row, and a story for a path that no
/// longer exists. That helper lives in `app/shell` and is being written in
/// parallel; wiring an override in one line at merge is the whole point of
/// naming the seam now rather than growing a second launcher here.
///
/// A no-op rather than a throw: a menu item that reports an internal error is
/// worse than one that is quietly inert, and the row already offers *Copy path*,
/// which works today and needs nothing from the platform.
final revealInFileManagerProvider = Provider<RevealInFileManager>(
  (ref) => _notWiredUp,
);

Future<void> _notWiredUp(EnvironmentPath path) async {}
