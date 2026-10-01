import 'package:riverpod/riverpod.dart';

/// The app whose detail is open, by the `StoreApp.key` of an app in it — so
/// it stays open when that app is combined with another or separated from
/// it. Kept outside the layout, so a resize or a rotation between the split
/// and the single column keeps it.
class StoresSelection extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? appKey) => state = appKey;
}

final storesSelectionProvider = NotifierProvider<StoresSelection, String?>(
  StoresSelection.new,
);
