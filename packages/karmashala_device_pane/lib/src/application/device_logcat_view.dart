import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_devices/karmashala_devices.dart';
import 'device_logcat_session.dart';

/// One device's logcat view: the query, the selected match, and where the view
/// was cleared. Kept outside the section, and outside the `autoDispose`
/// session, so closing the strip or switching devices keeps it.
class DeviceLogcatView {
  const DeviceLogcatView({
    this.query = const LogcatQuery(),
    this.currentMatch,
    this.clearedSession,
    this.clearedBefore = 0,
  });

  final LogcatQuery query;

  /// Sequence number of the selected match.
  final int? currentMatch;

  /// The session [clearedBefore] numbers lines on — a reopened strip is a new
  /// session, numbered from zero.
  final Object? clearedSession;
  final int clearedBefore;

  @override
  bool operator ==(Object other) =>
      other is DeviceLogcatView &&
      other.query == query &&
      other.currentMatch == currentMatch &&
      identical(other.clearedSession, clearedSession) &&
      other.clearedBefore == clearedBefore;

  @override
  int get hashCode => Object.hash(
    query,
    currentMatch,
    identityHashCode(clearedSession),
    clearedBefore,
  );
}

/// Logcat views by device serial.
class DeviceLogcatViews extends Notifier<Map<String, DeviceLogcatView>> {
  @override
  Map<String, DeviceLogcatView> build() => const {};

  DeviceLogcatView of(String serial) =>
      state[serial] ?? const DeviceLogcatView();

  void _put(String serial, DeviceLogcatView view) =>
      state = {...state, serial: view};

  void setQuery(String serial, LogcatQuery query) {
    final view = of(serial);
    if (view.query == query) return;
    // A match picked under another query means nothing under this one.
    _put(
      serial,
      DeviceLogcatView(
        query: query,
        clearedSession: view.clearedSession,
        clearedBefore: view.clearedBefore,
      ),
    );
  }

  void selectMatch(String serial, int? sequence) {
    final view = of(serial);
    _put(
      serial,
      DeviceLogcatView(
        query: view.query,
        currentMatch: sequence,
        clearedSession: view.clearedSession,
        clearedBefore: view.clearedBefore,
      ),
    );
  }

  /// Hides what is on screen now. The session's tail keeps it, and the
  /// device's own log buffer is never touched (no `logcat -c`).
  void clear(String serial, DeviceLogcatSession session) => _put(
    serial,
    DeviceLogcatView(
      query: of(serial).query,
      clearedSession: session,
      clearedBefore: session.appended,
    ),
  );
}

final deviceLogcatViewsProvider =
    NotifierProvider<DeviceLogcatViews, Map<String, DeviceLogcatView>>(
      DeviceLogcatViews.new,
    );

final deviceLogcatViewProvider = Provider.family<DeviceLogcatView, String>(
  (ref, serial) => ref.watch(
    deviceLogcatViewsProvider.select(
      (views) => views[serial] ?? const DeviceLogcatView(),
    ),
  ),
);

final _filterCacheProvider = Provider.autoDispose
    .family<LogcatFilterCache, String>((ref, serial) => LogcatFilterCache());

/// The device's log under its view, recomputed per flush but searching only the
/// new lines. `autoDispose`, like the session it reads: watched only while the
/// strip is open.
final deviceLogcatFilterProvider = Provider.autoDispose
    .family<LogcatFilterResult, String>((ref, serial) {
      final session = ref.watch(deviceLogcatSessionProvider(serial));
      void changed() => ref.invalidateSelf();
      session.addListener(changed);
      ref.onDispose(() => session.removeListener(changed));
      final view = ref.watch(deviceLogcatViewProvider(serial));
      return session.filter(
        ref.watch(_filterCacheProvider(serial)),
        view.query,
        hideBefore: identical(view.clearedSession, session)
            ? view.clearedBefore
            : 0,
      );
    });
