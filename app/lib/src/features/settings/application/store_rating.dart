import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:in_app_review/in_app_review.dart';
import 'package:karmashala_core/logging.dart';
import 'package:url_launcher/url_launcher.dart';

/// Play's listing for the phone app.
final Uri kPlayListing = Uri.parse(
  'https://play.google.com/store/apps/details?id=com.popupbits.karmashala',
);

/// Whether this device rates the app on a store: Android, for now. iOS joins
/// with its App Store listing; a desktop is not in either store.
bool get ratesOnStore => !kIsWeb && Platform.isAndroid;

/// Asks for a store rating — the beej template's `ReviewPrompt`.
///
/// The native sheet is the good path: it never leaves the app and the store
/// counts it. But the platform decides whether to show it — rate-limited per
/// user, ignored on an install not from the store, unavailable without the
/// store app — and `requestReview` returns normally either way, so a tap that
/// showed nothing cannot be told apart. From a row someone tapped on purpose,
/// nothing is the wrong outcome, so the listing opens as well when the sheet
/// is not available.
Future<void> requestStoreRating() async {
  try {
    final review = InAppReview.instance;
    if (await review.isAvailable()) {
      await review.requestReview();
      return;
    }
  } on Object catch (error) {
    AppLogger.named('rating').info('In-app rating unavailable: $error');
  }
  await launchUrl(kPlayListing, mode: LaunchMode.externalApplication);
}
