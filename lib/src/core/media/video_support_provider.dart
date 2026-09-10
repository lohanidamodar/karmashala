import 'package:riverpod/riverpod.dart';

import 'package:karmashala_media/media.dart';

/// The one reading of what this host can write a video with. Measured when
/// first asked and then kept — an installed encoder does not come and go.
final videoSupportProvider = Provider<VideoSupport>(
  // The app asks for the hardware encoder; `flutter test` must not — see
  // [appHardwareTransforms].
  (ref) => probeVideoSupport(hardwareTransforms: appHardwareTransforms),
);

/// Whether a recording this app renders may use the hardware encoder. A test
/// that renders a real MP4 overrides it: the vendor MFTs crash `flutter_tester`.
final hardwareTransformsProvider = Provider<bool>(
  (ref) => appHardwareTransforms,
);
