import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a page outside the app.
typedef ExternalUrlOpener = Future<bool> Function(String url);

/// How the app opens a web page. A provider so a widget test can record what a
/// link would have opened instead of launching a browser at the machine.
final openExternalUrlProvider = Provider<ExternalUrlOpener>(
  (ref) => openInBrowser,
);

/// Opens [url] in the user's browser, refusing anything that is not http(s).
///
/// Every URL the app builds is https, derived from a remote it read out of a
/// repository. Refusing the rest means a malformed or hostile `origin` cannot
/// turn a click into a launched scheme handler.
Future<bool> openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
