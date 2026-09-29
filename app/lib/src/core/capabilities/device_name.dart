import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// This device's own model, or null when it cannot be read.
///
/// Best effort by design: a phone that refuses to describe itself still pairs,
/// under the fallback [companionDeviceName] builds.
Future<String?> readDeviceModel() async {
  if (kIsWeb) return null;
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      // The manufacturer is dropped when the model already carries it, which
      // is how "OPPO OPPO Reno11" happens.
      final model = android.model.trim();
      final maker = android.manufacturer.trim();
      if (maker.isEmpty) return model;
      return model.toLowerCase().startsWith(maker.toLowerCase())
          ? model
          : '$maker $model';
    }
    if (Platform.isIOS) {
      // `name` is the generic "iPhone" from iOS 16 without an entitlement.
      // The plugin's model table answers "Unknown device" past its newest.
      final ios = await info.iosInfo;
      final model = ios.modelName.trim();
      return model.isEmpty || model == 'Unknown device'
          ? ios.name.trim()
          : model;
    }
    if (Platform.isMacOS) return (await info.macOsInfo).computerName.trim();
    if (Platform.isWindows) return (await info.windowsInfo).computerName.trim();
    if (Platform.isLinux) return (await info.linuxInfo).prettyName.trim();
  } on Object {
    // A platform that will not say is not a failure to pair.
    return null;
  }
  return null;
}
