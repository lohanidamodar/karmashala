import 'package:flutter/material.dart';

import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_ui/tokens.dart';

import 'device_app_controls.dart';

/// **Install, launch or stop an app on one device**, from its row in the
/// list — so it needs no live view and no other device to be put aside. The
/// same controls a preview carries under its picture.
class DeviceAppsDialog extends StatelessWidget {
  const DeviceAppsDialog({required this.device, super.key});

  final AndroidDevice device;

  static Future<void> show(BuildContext context, AndroidDevice device) =>
      showDialog<void>(
        context: context,
        builder: (context) => DeviceAppsDialog(device: device),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Apps on ${device.displayName}'),
    contentPadding: EdgeInsets.zero,
    content: SizedBox(
      width: DialogWidth.regular,
      child: DeviceAppControls(device: device),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}
