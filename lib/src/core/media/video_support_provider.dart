import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'media_foundation.dart';
import 'video_writer.dart';

/// The one reading of what this host can write a video with.
///
/// Measured when first asked and then kept: an installed encoder does not come
/// and go while the app runs, so nothing here polls. Overridden in tests so a
/// surface can be checked both ways on any host.
final videoSupportProvider = Provider<VideoSupport>(
  (ref) => probeVideoSupport(),
);
