/// Opening the file browser from wherever a machine is already named: a host's
/// row, a menu. Here rather than in the tab so a caller needs neither the pane
/// id spelling nor the environment lookup.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/workbench_tabs.dart';
import '../../environments/application/environment_providers.dart';
import 'file_space_providers.dart';

/// Opens the browser with this machine on the left and [environmentId] on the
/// right — a host, a distribution, or this machine again. [path] is where the
/// right side starts, when the caller knows.
void openFilesTabOn(WidgetRef ref, String environmentId, {String? path}) {
  final here = _thisMachine(ref);
  openFilesTab(
    ref,
    leftEnvironmentId: here ?? environmentId,
    rightEnvironmentId: environmentId,
    rightPath: path ?? '',
  );
}

/// Opens the browser on this machine, both sides — the plain file manager,
/// with somewhere to copy to.
void openFilesTabHere(WidgetRef ref) {
  final here = _thisMachine(ref);
  if (here == null) return;
  openFilesTab(ref, leftEnvironmentId: here, rightEnvironmentId: here);
}

/// This desktop's own environment id, or the first machine the browser can
/// show — a workspace whose local row has not been written yet still browses.
String? _thisMachine(WidgetRef ref) =>
    ref.read(localEnvironmentProvider)?.id ??
    ref.read(browsableEnvironmentsProvider).firstOrNull?.id;
