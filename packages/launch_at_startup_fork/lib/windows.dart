/// The Windows launcher on its own, so a test can drive it against a scratch
/// registry key. Never import this from shared code: it reaches `dart:ffi`.
library;

export 'src/app_auto_launcher_impl_windows.dart';
