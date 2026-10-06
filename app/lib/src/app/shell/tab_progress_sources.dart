import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_core/geometry.dart';

import '../../core/util/tab_progress.dart';
import '../../features/stores/application/stores_controller.dart';

/// What a document tab's header says about its page's work, by pane id:
/// null for a page that reports none. A page that wants a ring in its tab
/// adds its own provider here.
final documentTabProgressProvider = Provider.family<TabProgress?, String>((
  ref,
  paneId,
) {
  if (isStoresPane(paneId)) return ref.watch(storesTabProgressProvider);
  return null;
});
