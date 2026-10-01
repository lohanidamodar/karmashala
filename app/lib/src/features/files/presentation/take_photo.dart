import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/picking.dart' show DevicePhotos;

import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/app_settings.dart';

final _log = AppLogger.named('camera');

/// "Photos" and "Take a photo" for an attach, or null where
/// [Capabilities.takesPhotos] says no. Read per attach, like the pick server.
DevicePhotos? devicePhotosFor(BuildContext context, WidgetRef ref) {
  if (!ref.read(capabilitiesProvider).takesPhotos) return null;
  return DevicePhotos(
    take: () => _photo(context, ImageSource.camera),
    choose: () => _photo(context, ImageSource.gallery),
  );
}

/// The system camera app, or the system photo picker, through
/// `image_picker`: 2048 px on the long edge at quality 85 (Stage 3, answer
/// 8); a photo taken is never saved to the gallery.
Future<XFile?> _photo(BuildContext context, ImageSource source) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    return await ImagePicker().pickImage(
      source: source,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
      requestFullMetadata: false,
    );
  } on PlatformException catch (error, stack) {
    _log.warning('The camera did not give a photo.', error, stack);
    final refused =
        error.code == 'camera_access_denied' ||
        error.code == 'camera_access_restricted';
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          refused
              ? 'Camera access is off for Karmashala.'
              : error.code == 'no_available_camera'
              ? 'This phone has no camera app to take a photo with.'
              : 'The camera could not take a photo: '
                    '${error.message ?? error.code}',
        ),
        action: refused
            ? SnackBarAction(
                label: 'Settings',
                onPressed: () => unawaited(openAppSettings()),
              )
            : null,
      ),
    );
    return null;
  }
}
