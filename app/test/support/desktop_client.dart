import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala_ui/tokens.dart';

/// This machine's client at [density]. `flutter_test` reports Android as the
/// platform, so [ClientCapabilities.measure] reads touch density, and the
/// whole app (`KarmashalaApp`) then draws 48dp targets and touch headers. A
/// test of the desktop shell overrides `clientCapabilitiesProvider` with this.
ClientCapabilities desktopClient({UiDensity density = UiDensity.pointer}) {
  final measured = ClientCapabilities.measure();
  return ClientCapabilities(
    systemIntegration: measured.systemIntegration,
    osToasts: measured.osToasts,
    localNotifications: measured.localNotifications,
    localDevices: measured.localDevices,
    externalApps: measured.externalApps,
    fileDrop: measured.fileDrop,
    relaunch: measured.relaunch,
    density: density,
    hostsServer: measured.hostsServer,
    multicastLock: measured.multicastLock,
    mediaPlayback: measured.mediaPlayback,
    deviceName: measured.deviceName,
    camera: measured.camera,
  );
}
