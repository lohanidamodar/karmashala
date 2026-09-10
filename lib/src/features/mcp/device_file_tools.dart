import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:karmashala_devices/devices.dart';
import 'device_tool_support.dart';

/// Files on a device: the places it can reach, what is in one, and a copy in
/// either direction. No delete tool at all.
class DeviceFileTools extends DeviceToolFamily {
  DeviceFileTools(super.container, {super.callerSessionId});

  static const Set<String> _names = <String>{
    'device_files_list',
    'device_file_pull',
    'device_file_push',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'device_files_list' => _filesList(
          deviceIdIn(args),
          args['path'] as String?,
        ),
        'device_file_pull' => _filePull(
          deviceIdIn(args),
          args['device_path'] as String?,
          args['destination_directory'] as String?,
        ),
        'device_file_push' => _filePush(
          deviceIdIn(args),
          args['host_path'] as String?,
          args['device_path'] as String?,
          args['overwrite'] == true,
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// **Roots when no path is given, a listing when one is**: the roots are not
  /// branches of one tree, and on iOS `/` is not reachable at all.
  Future<Object?> _filesList(String? id, String? path) async {
    final driver = await driverThatCan(
      id,
      'device_files_list',
      DeviceCapability.files,
    );
    if (path == null || path.isEmpty) {
      final roots = await driver.fileRoots();
      return {
        'device': driver.target.id,
        'roots': [
          for (final root in roots)
            {
              'path': root.path,
              'label': root.label,
              'description': root.description,
              'writable': root.writable,
            },
        ],
        'note':
            'Pass one of these paths back as `path` to list it. These are the '
            'places this device can reach, not branches of one filesystem.',
      };
    }
    final listing = await driver.listDirectory(path);
    return {
      'device': driver.target.id,
      'path': listing.path,
      'entries': [
        for (final entry in listing.entries)
          {
            'name': entry.name,
            'path': entry.path,
            'kind': entry.kind.name,
            'readable': entry.readable,
            'size_bytes': ?entry.sizeBytes,
            'modified': ?entry.modifiedLabel,
            'mode': ?entry.mode,
            'link_target': ?entry.linkTarget,
          },
      ],
      // Never dropped: `ls -l` differs by device, and omitting an unparsable
      // line would tell the agent the directory is shorter than it is.
      if (listing.skipped.isNotEmpty)
        'unparsed': [
          for (final skipped in listing.skipped)
            {'line': skipped.line, 'reason': skipped.reason},
        ],
      'note': ?listing.note,
    };
  }

  /// Copies a file off the device into the system temp directory, so the reply's
  /// `host_path` can be handed straight to a file read.
  Future<Object?> _filePull(
    String? id,
    String? devicePath,
    String? destinationDirectory,
  ) async {
    final driver = await driverThatCan(
      id,
      'device_file_pull',
      DeviceCapability.files,
    );
    if (devicePath == null || devicePath.isEmpty) {
      throw DeviceRefusal(
        'device_file_pull: device_path is required. Call device_files_list '
        'first to find one.',
      );
    }
    final directory = destinationDirectory ?? Directory.systemTemp.path;
    final moved = await driver.pullFile(
      devicePath: devicePath,
      hostPath: p.join(
        directory,
        'karmashala_${driver.target.fileSafeId}_'
        '${p.posix.basename(devicePath)}',
      ),
    );
    return {
      'device': driver.target.id,
      'device_path': moved.devicePath,
      'host_path': moved.hostPath,
      'bytes': ?moved.bytes,
      'note': ?moved.note,
    };
  }

  /// Copies a file from this computer onto the device. [overwrite] is off unless
  /// asked for: there is no undo on the far side.
  Future<Object?> _filePush(
    String? id,
    String? hostPath,
    String? devicePath,
    bool overwrite,
  ) async {
    final driver = await driverToDrive(
      id,
      'device_file_push',
      DeviceCapability.files,
    );
    if (hostPath == null || hostPath.isEmpty || devicePath == null ||
        devicePath.isEmpty) {
      throw DeviceRefusal(
        'device_file_push: host_path and device_path are both required.',
      );
    }
    if (!File(hostPath).existsSync()) {
      throw DeviceRefusal('device_file_push: no file at $hostPath.');
    }
    final moved = await driver.pushFile(
      hostPath: hostPath,
      devicePath: devicePath,
      overwrite: overwrite,
    );
    return {
      'device': driver.target.id,
      'host_path': moved.hostPath,
      'device_path': moved.devicePath,
      'bytes': ?moved.bytes,
      'note': ?moved.note,
    };
  }

  // **No delete tool, deliberately**: the pane's confirmation is the only thing
  // between a mistyped path and an unrecoverable `rm -rf` on somebody's phone.
}

/// The schemas for [DeviceFileTools].
const Map<String, dynamic> deviceFilesListSchema = {
  'name': 'device_files_list',
  'description':
      "Look at a device's storage. Called with no path it returns the "
      'places this device can reach, each with whether it is writable — '
      'these are not branches of one filesystem, so do not assume "/". '
      'Called with a path it lists that directory. A directory this device '
      'will not let us read comes back as a refusal, never as an empty '
      'listing, and any lines the listing could not be parsed from are '
      'reported under `unparsed` rather than dropped.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'path': {
        'type': 'string',
        'description':
            'A directory on the device. Omit to get the reachable roots.',
      },
    },
  },
};

const Map<String, dynamic> deviceFilePullSchema = {
  'name': 'device_file_pull',
  'description':
      'Copy a file off the device onto this computer. Returns `host_path`, '
      'which is a real path on this machine that can be read straight '
      'afterwards. Defaults to the system temp directory; pass '
      'destination_directory to choose somewhere else.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'device_path': {
        'type': 'string',
        'description':
            'The file on the device. Use device_files_list to find one.',
      },
      'destination_directory': {
        'type': 'string',
        'description': 'Where to put it on this computer. Optional.',
      },
    },
    'required': ['device_path'],
  },
};

const Map<String, dynamic> deviceFilePushSchema = {
  'name': 'device_file_push',
  'description':
      'Copy a file from this computer onto the device. Refuses rather than '
      'replacing an existing file unless overwrite is true, because there '
      'is no undo on the device. If device_path names a directory the file '
      'lands inside it under its own name, and the reply says so.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'serial': {'type': 'string'},
      'udid': {'type': 'string', 'description': 'Alias for serial.'},
      'host_path': {
        'type': 'string',
        'description': 'The file on this computer.',
      },
      'device_path': {
        'type': 'string',
        'description': 'Destination path on the device.',
      },
      'overwrite': {
        'type': 'boolean',
        'description': 'Replace an existing file. Default false.',
      },
    },
    'required': ['host_path', 'device_path'],
  },
};
