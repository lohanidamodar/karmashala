import 'package:riverpod/riverpod.dart';

import '../application/store_groups.dart';

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

/// Which apps the list shows.
enum StoresFilter {
  attention('Needs attention'),
  inProgress('In progress'),
  newReviews('New reviews'),
  all('All');

  const StoresFilter(this.label);
  final String label;

  /// Whether [group] is one this filter shows.
  bool shows(StoreAppGroup group) => switch (this) {
    StoresFilter.all => true,
    StoresFilter.attention => group.needsAttention,
    StoresFilter.inProgress => !group.needsAttention && group.inFlight,
    StoresFilter.newReviews => group.newReviewCount > 0,
  };
}

/// The list's filter; outside the layout for the same reason as the
/// selection.
class StoresFilterState extends Notifier<StoresFilter> {
  @override
  StoresFilter build() => StoresFilter.all;

  /// Picking the filter already on goes back to every app.
  void toggle(StoresFilter filter) =>
      state = state == filter ? StoresFilter.all : filter;
}

final storesFilterProvider = NotifierProvider<StoresFilterState, StoresFilter>(
  StoresFilterState.new,
);
