import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// The channel `AppSettingsChannel.kt` answers. Method: `open`.
const _channel = MethodChannel('karmashala/app_settings');

/// Opens this app's page in the phone's system settings, where a permission
/// refused for good is turned back on. False where there is none to open.
Future<bool> openAppSettings() async {
  if (kIsWeb) return false;
  try {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('open') ?? false;
    }
    if (Platform.isIOS) return await launchUrl(Uri.parse('app-settings:'));
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
  return false;
}
