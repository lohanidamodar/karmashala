import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/paths/app_support_directory.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

const String kVmServiceDirectoryName = 'vmservice';

/// Where `flutter_run` points `--vmservice-out-file`. Under application support,
/// not the project: the address belongs to one run, not to the code.
final flutterAppDiscoveryDirectoryProvider =
    FutureProvider<VmServiceUriDirectory>((ref) async {
      final support = await appSupportDirectory();
      final directory = VmServiceUriDirectory(
        Directory(p.join(support.path, kVmServiceDirectoryName)),
      );
      await directory.ensureExists();
      return directory;
    });

/// Where the Dart Tooling Daemons on this machine record themselves.
final dtdPidFilesProvider = Provider<DtdPidFiles>(
  (ref) => DtdPidFiles.forEnvironment(
    Platform.environment,
    operatingSystem: Platform.operatingSystem,
  ),
);

/// How a channel to a tooling daemon is opened. Overridden in tests.
final dtdChannelOpenerProvider = Provider<DtdChannelOpener>(
  (ref) => openDtdOverWebSocket,
);

/// How a VM service connection is opened. Overridden in tests with a connector
/// that answers JSON-RPC in Dart.
final vmServiceConnectorProvider = Provider<VmServiceConnector>(
  (ref) => connectVmServiceOverWebSocket,
);
