import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:karmashala_core/logging.dart';

/// Thin wrapper around Google Play Core's flexible in-app update, ported from
/// the beej template's `in_app_update` brick.
///
/// Every method is Android-only and swallows its errors: a failed update check
/// is never a user-facing problem, and a null result means "no update". On an
/// install that did not come from Play (debug, sideloaded) and on every other
/// platform these are no-ops.
class AppUpdateService {
  AppUpdateService({@visibleForTesting this.debugIsAndroid});

  /// Forces the Android branch on in tests, where Platform.isAndroid is false.
  @visibleForTesting
  final bool? debugIsAndroid;

  static final AppLogger _log = AppLogger.named('update');

  // dart:io's Platform is unimplemented on the web — touching any member
  // throws — so short-circuit on kIsWeb before reading it.
  bool get _isAndroid => debugIsAndroid ?? (!kIsWeb && Platform.isAndroid);

  Future<AppUpdateInfo?> checkForUpdate() async {
    if (!_isAndroid) return null;
    try {
      final info = await InAppUpdate.checkForUpdate();
      // One line a check, so "did it run, and what did Play say" is in the
      // log: a sideloaded install answers, and it says no update.
      _log.info(
        'Play update check: ${info.updateAvailability.name}, '
        'install ${info.installStatus.name}, '
        'flexible ${info.flexibleUpdateAllowed ? 'allowed' : 'not allowed'}.',
      );
      return info;
    } on Object catch (error) {
      _log.info('Update check did not answer: $error');
      return null;
    }
  }

  Future<AppUpdateResult?> startFlexibleUpdate() async {
    if (!_isAndroid) return null;
    try {
      return await InAppUpdate.startFlexibleUpdate();
    } on Object catch (error) {
      _log.info('Flexible update did not start: $error');
      return null;
    }
  }

  Future<void> completeFlexibleUpdate() async {
    if (!_isAndroid) return;
    try {
      await InAppUpdate.completeFlexibleUpdate();
    } on Object catch (error) {
      _log.info('Flexible update did not complete: $error');
    }
  }
}

final appUpdateServiceProvider = Provider<AppUpdateService>(
  (ref) => AppUpdateService(),
);
