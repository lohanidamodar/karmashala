import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/media.dart';

/// The one reading of what this host can write a video with.
///
/// Measured when first asked and then kept: an installed encoder does not come
/// and go while the app runs, so nothing here polls. Overridden in tests so a
/// surface can be checked both ways on any host.
final videoSupportProvider = Provider<VideoSupport>(
  // The app asks for the hardware encoder; `flutter test` must not — see
  // [appHardwareTransforms].
  (ref) => probeVideoSupport(hardwareTransforms: appHardwareTransforms),
);

/// Whether a recording this app renders may use the hardware encoder.
///
/// [appHardwareTransforms] here; a test that renders a real MP4 overrides it to
/// `false`, because the vendor MFTs the attribute loads have taken
/// `flutter_tester.exe` down twenty times. A provider rather than a constant
/// only so the render path can be told without reading the environment.
final hardwareTransformsProvider = Provider<bool>(
  (ref) => appHardwareTransforms,
);
