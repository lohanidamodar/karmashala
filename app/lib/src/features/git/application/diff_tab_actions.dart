import 'package:agent_cli/process.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import '../data/git_data.dart';
import 'changes_providers.dart';

/// One file's diff, named in full. A diff tab carries its own checkout rather
/// than reading whichever one the sidebar is pointed at now.
@immutable
class DiffTarget {
  const DiffTarget({required this.checkout, required this.path});

  final EnvironmentPath checkout;

  /// Relative to the checkout root, spelled the way git prints it.
  final String path;

  String get name => path.split('/').last;

  @override
  bool operator ==(Object other) =>
      other is DiffTarget && other.checkout == checkout && other.path == path;

  @override
  int get hashCode => Object.hash(checkout, path);

  @override
  String toString() => 'DiffTarget(${checkout.path} :: $path)';
}

/// [target] as a document pane id.
String diffPaneIdFor(DiffTarget target) => diffPaneId(
  environmentId: target.checkout.environmentId,
  checkoutPath: target.checkout.path,
  path: target.path,
);

/// What diff pane [paneId] shows, or null when it is not one.
DiffTarget? diffTargetOf(String paneId) {
  final parts = diffPaneTarget(paneId);
  if (parts == null) return null;
  return DiffTarget(
    checkout: EnvironmentPath(
      environmentId: parts.environmentId,
      path: parts.checkoutPath,
    ),
    path: parts.path,
  );
}

/// The unified diff for [target]. Its own family rather than
/// `fileDiffByPathProvider`, which follows the sidebar: a tab has to keep
/// showing the file it was opened on.
///
/// Against `HEAD`, so the tab measures what the sidebar's `+N −M` measures: a
/// staged change is absent from a bare `git diff` and the row promised it.
final diffForTargetProvider = FutureProvider.autoDispose
    .family<String, DiffTarget>((ref, target) async {
      ref.watchCheckout(target.checkout);
      return ref
          .read(gitDataProvider)
          .diffForFile(target.checkout, target.path, base: 'HEAD');
    });

/// The file the diff tab on screen is showing, or null when the active tab is
/// not a diff. Derived rather than stored: a stored selection and the tab strip
/// disagreed the moment a chip was clicked or a tab closed.
final activeDiffFileProvider = Provider<String?>((ref) {
  final tab = ref.watch(
    terminalSessionsControllerProvider.select((s) => s.activeTab),
  );
  final paneId = tab?.focusedPaneId;
  return paneId == null ? null : diffTargetOf(paneId)?.path;
});

/// Opening a file's diff in a tab of its own.
class DiffTabActions {
  DiffTabActions(this._ref);

  final Ref _ref;

  /// Opens [path] of the checkout being viewed. Null when nothing is selected —
  /// there is no checkout to diff it against.
  String? open(String path) {
    final checkout = _ref.read(viewedCheckoutProvider);
    if (checkout == null) return null;
    return openFor(DiffTarget(checkout: checkout, path: path));
  }

  /// Opens [target], or brings its tab forward.
  String openFor(DiffTarget target) => _ref
      .read(terminalSessionsControllerProvider.notifier)
      .openDocumentTab(diffPaneIdFor(target));
}

final diffTabActionsProvider = Provider<DiffTabActions>(
  (ref) => DiffTabActions(ref),
);
