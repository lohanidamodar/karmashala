/// Driving an Android device or an iOS simulator from a desktop. `devices.dart`
/// is the vocabulary and every driver; this adds the three policies above
/// them — where a pulled file is put, whether a dead mirror is dialled again,
/// and who is allowed to drive a device while somebody else has it.
///
/// The Riverpod graph, the pane and its widgets are separate libraries:
/// `providers.dart`, `pane.dart`, `widgets.dart`, `dialogs.dart`, and
/// `ports.dart` for the seams a host fills.
library;

export 'devices.dart';
export 'src/application/device_claims.dart';
export 'src/application/device_file_staging.dart';
export 'src/application/stream_restart_policy.dart';
