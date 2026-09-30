import 'package:riverpod/riverpod.dart';

/// The app whose detail is open, by bundle id. Kept outside the layout, so a
/// resize or a rotation between the split and the single column keeps it.
class StoresSelection extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? bundleId) => state = bundleId;
}

final storesSelectionProvider = NotifierProvider<StoresSelection, String?>(
  StoresSelection.new,
);
