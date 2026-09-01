// This is a generated file - do not edit.
//
// Generated from idb.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use settingDescriptor instead')
const Setting$json = {
  '1': 'Setting',
  '2': [
    {'1': 'LOCALE', '2': 0},
    {'1': 'ANY', '2': 1},
  ],
};

/// Descriptor for `Setting`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List settingDescriptor =
    $convert.base64Decode('CgdTZXR0aW5nEgoKBkxPQ0FMRRAAEgcKA0FOWRAB');

@$core.Deprecated('Use payloadDescriptor instead')
const Payload$json = {
  '1': 'Payload',
  '2': [
    {'1': 'file_path', '3': 1, '4': 1, '5': 9, '9': 0, '10': 'filePath'},
    {'1': 'data', '3': 2, '4': 1, '5': 12, '9': 0, '10': 'data'},
    {'1': 'url', '3': 3, '4': 1, '5': 9, '9': 0, '10': 'url'},
    {
      '1': 'compression',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.idb.Payload.Compression',
      '9': 0,
      '10': 'compression'
    },
  ],
  '4': [Payload_Compression$json],
  '8': [
    {'1': 'source'},
  ],
};

@$core.Deprecated('Use payloadDescriptor instead')
const Payload_Compression$json = {
  '1': 'Compression',
  '2': [
    {'1': 'GZIP', '2': 0},
    {'1': 'ZSTD', '2': 1},
  ],
};

/// Descriptor for `Payload`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List payloadDescriptor = $convert.base64Decode(
    'CgdQYXlsb2FkEh0KCWZpbGVfcGF0aBgBIAEoCUgAUghmaWxlUGF0aBIUCgRkYXRhGAIgASgMSA'
    'BSBGRhdGESEgoDdXJsGAMgASgJSABSA3VybBI8Cgtjb21wcmVzc2lvbhgEIAEoDjIYLmlkYi5Q'
    'YXlsb2FkLkNvbXByZXNzaW9uSABSC2NvbXByZXNzaW9uIiEKC0NvbXByZXNzaW9uEggKBEdaSV'
    'AQABIICgRaU1REEAFCCAoGc291cmNl');

@$core.Deprecated('Use processOutputDescriptor instead')
const ProcessOutput$json = {
  '1': 'ProcessOutput',
  '2': [
    {
      '1': 'interface',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.ProcessOutput.Interface',
      '10': 'interface'
    },
    {'1': 'data', '3': 2, '4': 1, '5': 12, '10': 'data'},
  ],
  '4': [ProcessOutput_Interface$json],
};

@$core.Deprecated('Use processOutputDescriptor instead')
const ProcessOutput_Interface$json = {
  '1': 'Interface',
  '2': [
    {'1': 'STDOUT', '2': 0},
    {'1': 'STDERR', '2': 1},
  ],
};

/// Descriptor for `ProcessOutput`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List processOutputDescriptor = $convert.base64Decode(
    'Cg1Qcm9jZXNzT3V0cHV0EjoKCWludGVyZmFjZRgBIAEoDjIcLmlkYi5Qcm9jZXNzT3V0cHV0Lk'
    'ludGVyZmFjZVIJaW50ZXJmYWNlEhIKBGRhdGEYAiABKAxSBGRhdGEiIwoJSW50ZXJmYWNlEgoK'
    'BlNURE9VVBAAEgoKBlNUREVSUhAB');

@$core.Deprecated('Use companionInfoDescriptor instead')
const CompanionInfo$json = {
  '1': 'CompanionInfo',
  '2': [
    {'1': 'udid', '3': 1, '4': 1, '5': 9, '10': 'udid'},
    {'1': 'is_local', '3': 4, '4': 1, '5': 8, '10': 'isLocal'},
    {'1': 'metadata', '3': 6, '4': 1, '5': 12, '10': 'metadata'},
  ],
};

/// Descriptor for `CompanionInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List companionInfoDescriptor = $convert.base64Decode(
    'Cg1Db21wYW5pb25JbmZvEhIKBHVkaWQYASABKAlSBHVkaWQSGQoIaXNfbG9jYWwYBCABKAhSB2'
    'lzTG9jYWwSGgoIbWV0YWRhdGEYBiABKAxSCG1ldGFkYXRh');

@$core.Deprecated('Use settingRequestDescriptor instead')
const SettingRequest$json = {
  '1': 'SettingRequest',
  '2': [
    {
      '1': 'hardwareKeyboard',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.SettingRequest.HardwareKeyboard',
      '9': 0,
      '10': 'hardwareKeyboard'
    },
    {
      '1': 'stringSetting',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.SettingRequest.StringSetting',
      '9': 0,
      '10': 'stringSetting'
    },
  ],
  '3': [
    SettingRequest_HardwareKeyboard$json,
    SettingRequest_StringSetting$json
  ],
  '8': [
    {'1': 'setting'},
  ],
};

@$core.Deprecated('Use settingRequestDescriptor instead')
const SettingRequest_HardwareKeyboard$json = {
  '1': 'HardwareKeyboard',
  '2': [
    {'1': 'enabled', '3': 1, '4': 1, '5': 8, '10': 'enabled'},
  ],
};

@$core.Deprecated('Use settingRequestDescriptor instead')
const SettingRequest_StringSetting$json = {
  '1': 'StringSetting',
  '2': [
    {
      '1': 'setting',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.Setting',
      '10': 'setting'
    },
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
    {'1': 'name', '3': 3, '4': 1, '5': 9, '10': 'name'},
    {'1': 'domain', '3': 4, '4': 1, '5': 9, '10': 'domain'},
    {'1': 'value_type', '3': 5, '4': 1, '5': 9, '10': 'valueType'},
  ],
};

/// Descriptor for `SettingRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List settingRequestDescriptor = $convert.base64Decode(
    'Cg5TZXR0aW5nUmVxdWVzdBJSChBoYXJkd2FyZUtleWJvYXJkGAEgASgLMiQuaWRiLlNldHRpbm'
    'dSZXF1ZXN0LkhhcmR3YXJlS2V5Ym9hcmRIAFIQaGFyZHdhcmVLZXlib2FyZBJJCg1zdHJpbmdT'
    'ZXR0aW5nGAIgASgLMiEuaWRiLlNldHRpbmdSZXF1ZXN0LlN0cmluZ1NldHRpbmdIAFINc3RyaW'
    '5nU2V0dGluZxosChBIYXJkd2FyZUtleWJvYXJkEhgKB2VuYWJsZWQYASABKAhSB2VuYWJsZWQa'
    'mAEKDVN0cmluZ1NldHRpbmcSJgoHc2V0dGluZxgBIAEoDjIMLmlkYi5TZXR0aW5nUgdzZXR0aW'
    '5nEhQKBXZhbHVlGAIgASgJUgV2YWx1ZRISCgRuYW1lGAMgASgJUgRuYW1lEhYKBmRvbWFpbhgE'
    'IAEoCVIGZG9tYWluEh0KCnZhbHVlX3R5cGUYBSABKAlSCXZhbHVlVHlwZUIJCgdzZXR0aW5n');

@$core.Deprecated('Use settingResponseDescriptor instead')
const SettingResponse$json = {
  '1': 'SettingResponse',
};

/// Descriptor for `SettingResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List settingResponseDescriptor =
    $convert.base64Decode('Cg9TZXR0aW5nUmVzcG9uc2U=');

@$core.Deprecated('Use getSettingRequestDescriptor instead')
const GetSettingRequest$json = {
  '1': 'GetSettingRequest',
  '2': [
    {
      '1': 'setting',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.Setting',
      '10': 'setting'
    },
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'domain', '3': 3, '4': 1, '5': 9, '10': 'domain'},
  ],
};

/// Descriptor for `GetSettingRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getSettingRequestDescriptor = $convert.base64Decode(
    'ChFHZXRTZXR0aW5nUmVxdWVzdBImCgdzZXR0aW5nGAEgASgOMgwuaWRiLlNldHRpbmdSB3NldH'
    'RpbmcSEgoEbmFtZRgCIAEoCVIEbmFtZRIWCgZkb21haW4YAyABKAlSBmRvbWFpbg==');

@$core.Deprecated('Use getSettingResponseDescriptor instead')
const GetSettingResponse$json = {
  '1': 'GetSettingResponse',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 9, '10': 'value'},
  ],
};

/// Descriptor for `GetSettingResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getSettingResponseDescriptor = $convert
    .base64Decode('ChJHZXRTZXR0aW5nUmVzcG9uc2USFAoFdmFsdWUYASABKAlSBXZhbHVl');

@$core.Deprecated('Use listSettingRequestDescriptor instead')
const ListSettingRequest$json = {
  '1': 'ListSettingRequest',
  '2': [
    {
      '1': 'setting',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.Setting',
      '10': 'setting'
    },
  ],
};

/// Descriptor for `ListSettingRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listSettingRequestDescriptor = $convert.base64Decode(
    'ChJMaXN0U2V0dGluZ1JlcXVlc3QSJgoHc2V0dGluZxgBIAEoDjIMLmlkYi5TZXR0aW5nUgdzZX'
    'R0aW5n');

@$core.Deprecated('Use listSettingResponseDescriptor instead')
const ListSettingResponse$json = {
  '1': 'ListSettingResponse',
  '2': [
    {'1': 'values', '3': 1, '4': 3, '5': 9, '10': 'values'},
  ],
};

/// Descriptor for `ListSettingResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listSettingResponseDescriptor =
    $convert.base64Decode(
        'ChNMaXN0U2V0dGluZ1Jlc3BvbnNlEhYKBnZhbHVlcxgBIAMoCVIGdmFsdWVz');

@$core.Deprecated('Use listAppsRequestDescriptor instead')
const ListAppsRequest$json = {
  '1': 'ListAppsRequest',
  '2': [
    {
      '1': 'suppress_process_state',
      '3': 1,
      '4': 1,
      '5': 8,
      '10': 'suppressProcessState'
    },
  ],
};

/// Descriptor for `ListAppsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listAppsRequestDescriptor = $convert.base64Decode(
    'Cg9MaXN0QXBwc1JlcXVlc3QSNAoWc3VwcHJlc3NfcHJvY2Vzc19zdGF0ZRgBIAEoCFIUc3VwcH'
    'Jlc3NQcm9jZXNzU3RhdGU=');

@$core.Deprecated('Use listAppsResponseDescriptor instead')
const ListAppsResponse$json = {
  '1': 'ListAppsResponse',
  '2': [
    {
      '1': 'apps',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.idb.InstalledAppInfo',
      '10': 'apps'
    },
  ],
};

/// Descriptor for `ListAppsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listAppsResponseDescriptor = $convert.base64Decode(
    'ChBMaXN0QXBwc1Jlc3BvbnNlEikKBGFwcHMYASADKAsyFS5pZGIuSW5zdGFsbGVkQXBwSW5mb1'
    'IEYXBwcw==');

@$core.Deprecated('Use installedAppInfoDescriptor instead')
const InstalledAppInfo$json = {
  '1': 'InstalledAppInfo',
  '2': [
    {'1': 'bundle_id', '3': 1, '4': 1, '5': 9, '10': 'bundleId'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'architectures', '3': 3, '4': 3, '5': 9, '10': 'architectures'},
    {'1': 'install_type', '3': 4, '4': 1, '5': 9, '10': 'installType'},
    {
      '1': 'process_state',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.idb.InstalledAppInfo.AppProcessState',
      '10': 'processState'
    },
    {'1': 'debuggable', '3': 6, '4': 1, '5': 8, '10': 'debuggable'},
    {
      '1': 'process_identifier',
      '3': 7,
      '4': 1,
      '5': 4,
      '10': 'processIdentifier'
    },
  ],
  '4': [InstalledAppInfo_AppProcessState$json],
};

@$core.Deprecated('Use installedAppInfoDescriptor instead')
const InstalledAppInfo_AppProcessState$json = {
  '1': 'AppProcessState',
  '2': [
    {'1': 'UNKNOWN', '2': 0},
    {'1': 'NOT_RUNNING', '2': 1},
    {'1': 'RUNNING', '2': 2},
  ],
};

/// Descriptor for `InstalledAppInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List installedAppInfoDescriptor = $convert.base64Decode(
    'ChBJbnN0YWxsZWRBcHBJbmZvEhsKCWJ1bmRsZV9pZBgBIAEoCVIIYnVuZGxlSWQSEgoEbmFtZR'
    'gCIAEoCVIEbmFtZRIkCg1hcmNoaXRlY3R1cmVzGAMgAygJUg1hcmNoaXRlY3R1cmVzEiEKDGlu'
    'c3RhbGxfdHlwZRgEIAEoCVILaW5zdGFsbFR5cGUSSgoNcHJvY2Vzc19zdGF0ZRgFIAEoDjIlLm'
    'lkYi5JbnN0YWxsZWRBcHBJbmZvLkFwcFByb2Nlc3NTdGF0ZVIMcHJvY2Vzc1N0YXRlEh4KCmRl'
    'YnVnZ2FibGUYBiABKAhSCmRlYnVnZ2FibGUSLQoScHJvY2Vzc19pZGVudGlmaWVyGAcgASgEUh'
    'Fwcm9jZXNzSWRlbnRpZmllciI8Cg9BcHBQcm9jZXNzU3RhdGUSCwoHVU5LTk9XThAAEg8KC05P'
    'VF9SVU5OSU5HEAESCwoHUlVOTklORxAC');

@$core.Deprecated('Use installRequestDescriptor instead')
const InstallRequest$json = {
  '1': 'InstallRequest',
  '2': [
    {
      '1': 'destination',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.InstallRequest.Destination',
      '9': 0,
      '10': 'destination'
    },
    {
      '1': 'payload',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '9': 0,
      '10': 'payload'
    },
    {'1': 'name_hint', '3': 3, '4': 1, '5': 9, '9': 0, '10': 'nameHint'},
    {
      '1': 'make_debuggable',
      '3': 4,
      '4': 1,
      '5': 8,
      '9': 0,
      '10': 'makeDebuggable'
    },
    {'1': 'bundle_id', '3': 5, '4': 1, '5': 9, '9': 0, '10': 'bundleId'},
    {
      '1': 'link_dsym_to_bundle',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.idb.InstallRequest.LinkDsymToBundle',
      '9': 0,
      '10': 'linkDsymToBundle'
    },
    {
      '1': 'override_modification_time',
      '3': 7,
      '4': 1,
      '5': 8,
      '9': 0,
      '10': 'overrideModificationTime'
    },
    {
      '1': 'skip_signing_bundles',
      '3': 8,
      '4': 1,
      '5': 8,
      '9': 0,
      '10': 'skipSigningBundles'
    },
  ],
  '3': [InstallRequest_LinkDsymToBundle$json],
  '4': [InstallRequest_Destination$json],
  '8': [
    {'1': 'value'},
  ],
};

@$core.Deprecated('Use installRequestDescriptor instead')
const InstallRequest_LinkDsymToBundle$json = {
  '1': 'LinkDsymToBundle',
  '2': [
    {
      '1': 'bundle_type',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.InstallRequest.LinkDsymToBundle.BundleType',
      '10': 'bundleType'
    },
    {'1': 'bundle_id', '3': 2, '4': 1, '5': 9, '10': 'bundleId'},
  ],
  '4': [InstallRequest_LinkDsymToBundle_BundleType$json],
};

@$core.Deprecated('Use installRequestDescriptor instead')
const InstallRequest_LinkDsymToBundle_BundleType$json = {
  '1': 'BundleType',
  '2': [
    {'1': 'APP', '2': 0},
    {'1': 'XCTEST', '2': 1},
  ],
};

@$core.Deprecated('Use installRequestDescriptor instead')
const InstallRequest_Destination$json = {
  '1': 'Destination',
  '2': [
    {'1': 'APP', '2': 0},
    {'1': 'XCTEST', '2': 1},
    {'1': 'DYLIB', '2': 2},
    {'1': 'DSYM', '2': 3},
    {'1': 'FRAMEWORK', '2': 4},
  ],
};

/// Descriptor for `InstallRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List installRequestDescriptor = $convert.base64Decode(
    'Cg5JbnN0YWxsUmVxdWVzdBJDCgtkZXN0aW5hdGlvbhgBIAEoDjIfLmlkYi5JbnN0YWxsUmVxdW'
    'VzdC5EZXN0aW5hdGlvbkgAUgtkZXN0aW5hdGlvbhIoCgdwYXlsb2FkGAIgASgLMgwuaWRiLlBh'
    'eWxvYWRIAFIHcGF5bG9hZBIdCgluYW1lX2hpbnQYAyABKAlIAFIIbmFtZUhpbnQSKQoPbWFrZV'
    '9kZWJ1Z2dhYmxlGAQgASgISABSDm1ha2VEZWJ1Z2dhYmxlEh0KCWJ1bmRsZV9pZBgFIAEoCUgA'
    'UghidW5kbGVJZBJVChNsaW5rX2RzeW1fdG9fYnVuZGxlGAYgASgLMiQuaWRiLkluc3RhbGxSZX'
    'F1ZXN0LkxpbmtEc3ltVG9CdW5kbGVIAFIQbGlua0RzeW1Ub0J1bmRsZRI+ChpvdmVycmlkZV9t'
    'b2RpZmljYXRpb25fdGltZRgHIAEoCEgAUhhvdmVycmlkZU1vZGlmaWNhdGlvblRpbWUSMgoUc2'
    'tpcF9zaWduaW5nX2J1bmRsZXMYCCABKAhIAFISc2tpcFNpZ25pbmdCdW5kbGVzGqQBChBMaW5r'
    'RHN5bVRvQnVuZGxlElAKC2J1bmRsZV90eXBlGAEgASgOMi8uaWRiLkluc3RhbGxSZXF1ZXN0Lk'
    'xpbmtEc3ltVG9CdW5kbGUuQnVuZGxlVHlwZVIKYnVuZGxlVHlwZRIbCglidW5kbGVfaWQYAiAB'
    'KAlSCGJ1bmRsZUlkIiEKCkJ1bmRsZVR5cGUSBwoDQVBQEAASCgoGWENURVNUEAEiRgoLRGVzdG'
    'luYXRpb24SBwoDQVBQEAASCgoGWENURVNUEAESCQoFRFlMSUIQAhIICgREU1lNEAMSDQoJRlJB'
    'TUVXT1JLEARCBwoFdmFsdWU=');

@$core.Deprecated('Use installResponseDescriptor instead')
const InstallResponse$json = {
  '1': 'InstallResponse',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'uuid', '3': 2, '4': 1, '5': 9, '10': 'uuid'},
    {'1': 'progress', '3': 3, '4': 1, '5': 1, '10': 'progress'},
  ],
};

/// Descriptor for `InstallResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List installResponseDescriptor = $convert.base64Decode(
    'Cg9JbnN0YWxsUmVzcG9uc2USEgoEbmFtZRgBIAEoCVIEbmFtZRISCgR1dWlkGAIgASgJUgR1dW'
    'lkEhoKCHByb2dyZXNzGAMgASgBUghwcm9ncmVzcw==');

@$core.Deprecated('Use screenshotRequestDescriptor instead')
const ScreenshotRequest$json = {
  '1': 'ScreenshotRequest',
  '2': [
    {
      '1': 'format',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.ScreenshotRequest.Format',
      '10': 'format'
    },
    {
      '1': 'compression_quality',
      '3': 2,
      '4': 1,
      '5': 1,
      '10': 'compressionQuality'
    },
    {
      '1': 'crop',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.ScreenshotRequest.Rect',
      '10': 'crop'
    },
    {'1': 'scale_factor', '3': 4, '4': 1, '5': 1, '9': 0, '10': 'scaleFactor'},
    {
      '1': 'fit',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.idb.ScreenshotRequest.Fit',
      '9': 0,
      '10': 'fit'
    },
    {
      '1': 'unit',
      '3': 6,
      '4': 1,
      '5': 14,
      '6': '.idb.ScreenshotRequest.Unit',
      '10': 'unit'
    },
  ],
  '3': [ScreenshotRequest_Rect$json, ScreenshotRequest_Fit$json],
  '4': [ScreenshotRequest_Format$json, ScreenshotRequest_Unit$json],
  '8': [
    {'1': 'scale'},
  ],
};

@$core.Deprecated('Use screenshotRequestDescriptor instead')
const ScreenshotRequest_Rect$json = {
  '1': 'Rect',
  '2': [
    {'1': 'x', '3': 1, '4': 1, '5': 1, '10': 'x'},
    {'1': 'y', '3': 2, '4': 1, '5': 1, '10': 'y'},
    {'1': 'width', '3': 3, '4': 1, '5': 1, '10': 'width'},
    {'1': 'height', '3': 4, '4': 1, '5': 1, '10': 'height'},
  ],
};

@$core.Deprecated('Use screenshotRequestDescriptor instead')
const ScreenshotRequest_Fit$json = {
  '1': 'Fit',
  '2': [
    {'1': 'max_width', '3': 1, '4': 1, '5': 13, '10': 'maxWidth'},
    {'1': 'max_height', '3': 2, '4': 1, '5': 13, '10': 'maxHeight'},
  ],
};

@$core.Deprecated('Use screenshotRequestDescriptor instead')
const ScreenshotRequest_Format$json = {
  '1': 'Format',
  '2': [
    {'1': 'PNG', '2': 0},
    {'1': 'JPEG', '2': 1},
    {'1': 'TIFF', '2': 2},
  ],
};

@$core.Deprecated('Use screenshotRequestDescriptor instead')
const ScreenshotRequest_Unit$json = {
  '1': 'Unit',
  '2': [
    {'1': 'PIXELS', '2': 0},
    {'1': 'POINTS', '2': 1},
  ],
};

/// Descriptor for `ScreenshotRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List screenshotRequestDescriptor = $convert.base64Decode(
    'ChFTY3JlZW5zaG90UmVxdWVzdBI1CgZmb3JtYXQYASABKA4yHS5pZGIuU2NyZWVuc2hvdFJlcX'
    'Vlc3QuRm9ybWF0UgZmb3JtYXQSLwoTY29tcHJlc3Npb25fcXVhbGl0eRgCIAEoAVISY29tcHJl'
    'c3Npb25RdWFsaXR5Ei8KBGNyb3AYAyABKAsyGy5pZGIuU2NyZWVuc2hvdFJlcXVlc3QuUmVjdF'
    'IEY3JvcBIjCgxzY2FsZV9mYWN0b3IYBCABKAFIAFILc2NhbGVGYWN0b3ISLgoDZml0GAUgASgL'
    'MhouaWRiLlNjcmVlbnNob3RSZXF1ZXN0LkZpdEgAUgNmaXQSLwoEdW5pdBgGIAEoDjIbLmlkYi'
    '5TY3JlZW5zaG90UmVxdWVzdC5Vbml0UgR1bml0GlAKBFJlY3QSDAoBeBgBIAEoAVIBeBIMCgF5'
    'GAIgASgBUgF5EhQKBXdpZHRoGAMgASgBUgV3aWR0aBIWCgZoZWlnaHQYBCABKAFSBmhlaWdodB'
    'pBCgNGaXQSGwoJbWF4X3dpZHRoGAEgASgNUghtYXhXaWR0aBIdCgptYXhfaGVpZ2h0GAIgASgN'
    'UgltYXhIZWlnaHQiJQoGRm9ybWF0EgcKA1BORxAAEggKBEpQRUcQARIICgRUSUZGEAIiHgoEVW'
    '5pdBIKCgZQSVhFTFMQABIKCgZQT0lOVFMQAUIHCgVzY2FsZQ==');

@$core.Deprecated('Use screenshotResponseDescriptor instead')
const ScreenshotResponse$json = {
  '1': 'ScreenshotResponse',
  '2': [
    {'1': 'image_data', '3': 1, '4': 1, '5': 12, '10': 'imageData'},
    {'1': 'image_format', '3': 2, '4': 1, '5': 9, '10': 'imageFormat'},
    {
      '1': 'destination',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.ScreenshotResponse.Size',
      '10': 'destination'
    },
    {
      '1': 'source',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.idb.ScreenshotResponse.Size',
      '10': 'source'
    },
    {'1': 'screen_scale', '3': 5, '4': 1, '5': 1, '10': 'screenScale'},
  ],
  '3': [ScreenshotResponse_Size$json],
};

@$core.Deprecated('Use screenshotResponseDescriptor instead')
const ScreenshotResponse_Size$json = {
  '1': 'Size',
  '2': [
    {'1': 'width', '3': 1, '4': 1, '5': 13, '10': 'width'},
    {'1': 'height', '3': 2, '4': 1, '5': 13, '10': 'height'},
  ],
};

/// Descriptor for `ScreenshotResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List screenshotResponseDescriptor = $convert.base64Decode(
    'ChJTY3JlZW5zaG90UmVzcG9uc2USHQoKaW1hZ2VfZGF0YRgBIAEoDFIJaW1hZ2VEYXRhEiEKDG'
    'ltYWdlX2Zvcm1hdBgCIAEoCVILaW1hZ2VGb3JtYXQSPgoLZGVzdGluYXRpb24YAyABKAsyHC5p'
    'ZGIuU2NyZWVuc2hvdFJlc3BvbnNlLlNpemVSC2Rlc3RpbmF0aW9uEjQKBnNvdXJjZRgEIAEoCz'
    'IcLmlkYi5TY3JlZW5zaG90UmVzcG9uc2UuU2l6ZVIGc291cmNlEiEKDHNjcmVlbl9zY2FsZRgF'
    'IAEoAVILc2NyZWVuU2NhbGUaNAoEU2l6ZRIUCgV3aWR0aBgBIAEoDVIFd2lkdGgSFgoGaGVpZ2'
    'h0GAIgASgNUgZoZWlnaHQ=');

@$core.Deprecated('Use focusRequestDescriptor instead')
const FocusRequest$json = {
  '1': 'FocusRequest',
};

/// Descriptor for `FocusRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List focusRequestDescriptor =
    $convert.base64Decode('CgxGb2N1c1JlcXVlc3Q=');

@$core.Deprecated('Use focusResponseDescriptor instead')
const FocusResponse$json = {
  '1': 'FocusResponse',
};

/// Descriptor for `FocusResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List focusResponseDescriptor =
    $convert.base64Decode('Cg1Gb2N1c1Jlc3BvbnNl');

@$core.Deprecated('Use pointDescriptor instead')
const Point$json = {
  '1': 'Point',
  '2': [
    {'1': 'x', '3': 1, '4': 1, '5': 1, '10': 'x'},
    {'1': 'y', '3': 2, '4': 1, '5': 1, '10': 'y'},
  ],
};

/// Descriptor for `Point`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pointDescriptor =
    $convert.base64Decode('CgVQb2ludBIMCgF4GAEgASgBUgF4EgwKAXkYAiABKAFSAXk=');

@$core.Deprecated('Use accessibilityInfoRequestDescriptor instead')
const AccessibilityInfoRequest$json = {
  '1': 'AccessibilityInfoRequest',
  '2': [
    {'1': 'point', '3': 2, '4': 1, '5': 11, '6': '.idb.Point', '10': 'point'},
    {
      '1': 'format',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.idb.AccessibilityInfoRequest.Format',
      '10': 'format'
    },
    {'1': 'marker', '3': 4, '4': 1, '5': 9, '10': 'marker'},
    {
      '1': 'match_key',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.idb.AccessibilityActionRequest.SearchableKey',
      '10': 'matchKey'
    },
    {'1': 'depth', '3': 6, '4': 1, '5': 13, '10': 'depth'},
    {'1': 'keys', '3': 7, '4': 3, '5': 9, '10': 'keys'},
    {
      '1': 'backend',
      '3': 8,
      '4': 1,
      '5': 14,
      '6': '.idb.AccessibilityInfoRequest.Backend',
      '10': 'backend'
    },
    {'1': 'profile', '3': 9, '4': 1, '5': 8, '10': 'profile'},
    {
      '1': 'collect_frame_coverage',
      '3': 10,
      '4': 1,
      '5': 8,
      '10': 'collectFrameCoverage'
    },
  ],
  '4': [
    AccessibilityInfoRequest_Format$json,
    AccessibilityInfoRequest_Backend$json
  ],
};

@$core.Deprecated('Use accessibilityInfoRequestDescriptor instead')
const AccessibilityInfoRequest_Format$json = {
  '1': 'Format',
  '2': [
    {'1': 'LEGACY', '2': 0},
    {'1': 'NESTED', '2': 1},
    {'1': 'COMPLETE', '2': 2},
  ],
};

@$core.Deprecated('Use accessibilityInfoRequestDescriptor instead')
const AccessibilityInfoRequest_Backend$json = {
  '1': 'Backend',
  '2': [
    {'1': 'BACKEND_UNSPECIFIED', '2': 0},
    {'1': 'AX', '2': 1},
    {'1': 'AXBRIDGE', '2': 2},
    {'1': 'AXBRIDGE_PERSISTENT', '2': 3},
  ],
};

/// Descriptor for `AccessibilityInfoRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List accessibilityInfoRequestDescriptor = $convert.base64Decode(
    'ChhBY2Nlc3NpYmlsaXR5SW5mb1JlcXVlc3QSIAoFcG9pbnQYAiABKAsyCi5pZGIuUG9pbnRSBX'
    'BvaW50EjwKBmZvcm1hdBgDIAEoDjIkLmlkYi5BY2Nlc3NpYmlsaXR5SW5mb1JlcXVlc3QuRm9y'
    'bWF0UgZmb3JtYXQSFgoGbWFya2VyGAQgASgJUgZtYXJrZXISSgoJbWF0Y2hfa2V5GAUgASgOMi'
    '0uaWRiLkFjY2Vzc2liaWxpdHlBY3Rpb25SZXF1ZXN0LlNlYXJjaGFibGVLZXlSCG1hdGNoS2V5'
    'EhQKBWRlcHRoGAYgASgNUgVkZXB0aBISCgRrZXlzGAcgAygJUgRrZXlzEj8KB2JhY2tlbmQYCC'
    'ABKA4yJS5pZGIuQWNjZXNzaWJpbGl0eUluZm9SZXF1ZXN0LkJhY2tlbmRSB2JhY2tlbmQSGAoH'
    'cHJvZmlsZRgJIAEoCFIHcHJvZmlsZRI0ChZjb2xsZWN0X2ZyYW1lX2NvdmVyYWdlGAogASgIUh'
    'Rjb2xsZWN0RnJhbWVDb3ZlcmFnZSIuCgZGb3JtYXQSCgoGTEVHQUNZEAASCgoGTkVTVEVEEAES'
    'DAoIQ09NUExFVEUQAiJRCgdCYWNrZW5kEhcKE0JBQ0tFTkRfVU5TUEVDSUZJRUQQABIGCgJBWB'
    'ABEgwKCEFYQlJJREdFEAISFwoTQVhCUklER0VfUEVSU0lTVEVOVBAD');

@$core.Deprecated('Use accessibilityInfoResponseDescriptor instead')
const AccessibilityInfoResponse$json = {
  '1': 'AccessibilityInfoResponse',
  '2': [
    {'1': 'json', '3': 1, '4': 1, '5': 9, '10': 'json'},
  ],
};

/// Descriptor for `AccessibilityInfoResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List accessibilityInfoResponseDescriptor =
    $convert.base64Decode(
        'ChlBY2Nlc3NpYmlsaXR5SW5mb1Jlc3BvbnNlEhIKBGpzb24YASABKAlSBGpzb24=');

@$core.Deprecated('Use accessibilityActionRequestDescriptor instead')
const AccessibilityActionRequest$json = {
  '1': 'AccessibilityActionRequest',
  '2': [
    {'1': 'marker', '3': 1, '4': 1, '5': 9, '9': 0, '10': 'marker'},
    {
      '1': 'point',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.Point',
      '9': 0,
      '10': 'point'
    },
    {
      '1': 'match_key',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.idb.AccessibilityActionRequest.SearchableKey',
      '10': 'matchKey'
    },
    {'1': 'depth', '3': 4, '4': 1, '5': 13, '10': 'depth'},
    {
      '1': 'tap',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.idb.AccessibilityActionRequest.Tap',
      '9': 1,
      '10': 'tap'
    },
    {
      '1': 'scroll',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.idb.AccessibilityActionRequest.Scroll',
      '9': 1,
      '10': 'scroll'
    },
    {
      '1': 'set_value',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.idb.AccessibilityActionRequest.SetValue',
      '9': 1,
      '10': 'setValue'
    },
  ],
  '3': [
    AccessibilityActionRequest_Tap$json,
    AccessibilityActionRequest_Scroll$json,
    AccessibilityActionRequest_SetValue$json
  ],
  '4': [AccessibilityActionRequest_SearchableKey$json],
  '8': [
    {'1': 'target'},
    {'1': 'action'},
  ],
};

@$core.Deprecated('Use accessibilityActionRequestDescriptor instead')
const AccessibilityActionRequest_Tap$json = {
  '1': 'Tap',
  '2': [
    {
      '1': 'check_expected_value',
      '3': 1,
      '4': 1,
      '5': 8,
      '10': 'checkExpectedValue'
    },
    {'1': 'expected_value', '3': 2, '4': 1, '5': 9, '10': 'expectedValue'},
    {
      '1': 'expected_key',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.idb.AccessibilityActionRequest.SearchableKey',
      '10': 'expectedKey'
    },
  ],
};

@$core.Deprecated('Use accessibilityActionRequestDescriptor instead')
const AccessibilityActionRequest_Scroll$json = {
  '1': 'Scroll',
  '2': [
    {
      '1': 'direction',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.AccessibilityActionRequest.Scroll.Direction',
      '10': 'direction'
    },
  ],
  '4': [AccessibilityActionRequest_Scroll_Direction$json],
};

@$core.Deprecated('Use accessibilityActionRequestDescriptor instead')
const AccessibilityActionRequest_Scroll_Direction$json = {
  '1': 'Direction',
  '2': [
    {'1': 'UP', '2': 0},
    {'1': 'DOWN', '2': 1},
    {'1': 'LEFT', '2': 2},
    {'1': 'RIGHT', '2': 3},
    {'1': 'VISIBLE', '2': 4},
  ],
};

@$core.Deprecated('Use accessibilityActionRequestDescriptor instead')
const AccessibilityActionRequest_SetValue$json = {
  '1': 'SetValue',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 9, '10': 'value'},
  ],
};

@$core.Deprecated('Use accessibilityActionRequestDescriptor instead')
const AccessibilityActionRequest_SearchableKey$json = {
  '1': 'SearchableKey',
  '2': [
    {'1': 'LABEL', '2': 0},
    {'1': 'UNIQUE_ID', '2': 1},
    {'1': 'VALUE', '2': 2},
    {'1': 'TITLE', '2': 3},
    {'1': 'ROLE', '2': 4},
    {'1': 'ROLE_DESCRIPTION', '2': 5},
    {'1': 'SUBROLE', '2': 6},
    {'1': 'HELP', '2': 7},
    {'1': 'PLACEHOLDER', '2': 8},
  ],
};

/// Descriptor for `AccessibilityActionRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List accessibilityActionRequestDescriptor = $convert.base64Decode(
    'ChpBY2Nlc3NpYmlsaXR5QWN0aW9uUmVxdWVzdBIYCgZtYXJrZXIYASABKAlIAFIGbWFya2VyEi'
    'IKBXBvaW50GAIgASgLMgouaWRiLlBvaW50SABSBXBvaW50EkoKCW1hdGNoX2tleRgDIAEoDjIt'
    'LmlkYi5BY2Nlc3NpYmlsaXR5QWN0aW9uUmVxdWVzdC5TZWFyY2hhYmxlS2V5UghtYXRjaEtleR'
    'IUCgVkZXB0aBgEIAEoDVIFZGVwdGgSNwoDdGFwGAUgASgLMiMuaWRiLkFjY2Vzc2liaWxpdHlB'
    'Y3Rpb25SZXF1ZXN0LlRhcEgBUgN0YXASQAoGc2Nyb2xsGAYgASgLMiYuaWRiLkFjY2Vzc2liaW'
    'xpdHlBY3Rpb25SZXF1ZXN0LlNjcm9sbEgBUgZzY3JvbGwSRwoJc2V0X3ZhbHVlGAcgASgLMigu'
    'aWRiLkFjY2Vzc2liaWxpdHlBY3Rpb25SZXF1ZXN0LlNldFZhbHVlSAFSCHNldFZhbHVlGrABCg'
    'NUYXASMAoUY2hlY2tfZXhwZWN0ZWRfdmFsdWUYASABKAhSEmNoZWNrRXhwZWN0ZWRWYWx1ZRIl'
    'Cg5leHBlY3RlZF92YWx1ZRgCIAEoCVINZXhwZWN0ZWRWYWx1ZRJQCgxleHBlY3RlZF9rZXkYAy'
    'ABKA4yLS5pZGIuQWNjZXNzaWJpbGl0eUFjdGlvblJlcXVlc3QuU2VhcmNoYWJsZUtleVILZXhw'
    'ZWN0ZWRLZXkamQEKBlNjcm9sbBJOCglkaXJlY3Rpb24YASABKA4yMC5pZGIuQWNjZXNzaWJpbG'
    'l0eUFjdGlvblJlcXVlc3QuU2Nyb2xsLkRpcmVjdGlvblIJZGlyZWN0aW9uIj8KCURpcmVjdGlv'
    'bhIGCgJVUBAAEggKBERPV04QARIICgRMRUZUEAISCQoFUklHSFQQAxILCgdWSVNJQkxFEAQaIA'
    'oIU2V0VmFsdWUSFAoFdmFsdWUYASABKAlSBXZhbHVlIocBCg1TZWFyY2hhYmxlS2V5EgkKBUxB'
    'QkVMEAASDQoJVU5JUVVFX0lEEAESCQoFVkFMVUUQAhIJCgVUSVRMRRADEggKBFJPTEUQBBIUCh'
    'BST0xFX0RFU0NSSVBUSU9OEAUSCwoHU1VCUk9MRRAGEggKBEhFTFAQBxIPCgtQTEFDRUhPTERF'
    'UhAIQggKBnRhcmdldEIICgZhY3Rpb24=');

@$core.Deprecated('Use accessibilityActionResponseDescriptor instead')
const AccessibilityActionResponse$json = {
  '1': 'AccessibilityActionResponse',
};

/// Descriptor for `AccessibilityActionResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List accessibilityActionResponseDescriptor =
    $convert.base64Decode('ChtBY2Nlc3NpYmlsaXR5QWN0aW9uUmVzcG9uc2U=');

@$core.Deprecated('Use approveRequestDescriptor instead')
const ApproveRequest$json = {
  '1': 'ApproveRequest',
  '2': [
    {'1': 'bundle_id', '3': 1, '4': 1, '5': 9, '10': 'bundleId'},
    {
      '1': 'permissions',
      '3': 2,
      '4': 3,
      '5': 14,
      '6': '.idb.ApproveRequest.Permission',
      '10': 'permissions'
    },
    {'1': 'scheme', '3': 3, '4': 1, '5': 9, '10': 'scheme'},
  ],
  '4': [ApproveRequest_Permission$json],
};

@$core.Deprecated('Use approveRequestDescriptor instead')
const ApproveRequest_Permission$json = {
  '1': 'Permission',
  '2': [
    {'1': 'PHOTOS', '2': 0},
    {'1': 'CAMERA', '2': 1},
    {'1': 'CONTACTS', '2': 2},
    {'1': 'URL', '2': 3},
    {'1': 'LOCATION', '2': 4},
    {'1': 'NOTIFICATION', '2': 5},
    {'1': 'MICROPHONE', '2': 6},
  ],
};

/// Descriptor for `ApproveRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List approveRequestDescriptor = $convert.base64Decode(
    'Cg5BcHByb3ZlUmVxdWVzdBIbCglidW5kbGVfaWQYASABKAlSCGJ1bmRsZUlkEkAKC3Blcm1pc3'
    'Npb25zGAIgAygOMh4uaWRiLkFwcHJvdmVSZXF1ZXN0LlBlcm1pc3Npb25SC3Blcm1pc3Npb25z'
    'EhYKBnNjaGVtZRgDIAEoCVIGc2NoZW1lImsKClBlcm1pc3Npb24SCgoGUEhPVE9TEAASCgoGQ0'
    'FNRVJBEAESDAoIQ09OVEFDVFMQAhIHCgNVUkwQAxIMCghMT0NBVElPThAEEhAKDE5PVElGSUNB'
    'VElPThAFEg4KCk1JQ1JPUEhPTkUQBg==');

@$core.Deprecated('Use approveResponseDescriptor instead')
const ApproveResponse$json = {
  '1': 'ApproveResponse',
};

/// Descriptor for `ApproveResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List approveResponseDescriptor =
    $convert.base64Decode('Cg9BcHByb3ZlUmVzcG9uc2U=');

@$core.Deprecated('Use revokeRequestDescriptor instead')
const RevokeRequest$json = {
  '1': 'RevokeRequest',
  '2': [
    {'1': 'bundle_id', '3': 1, '4': 1, '5': 9, '10': 'bundleId'},
    {
      '1': 'permissions',
      '3': 2,
      '4': 3,
      '5': 14,
      '6': '.idb.RevokeRequest.Permission',
      '10': 'permissions'
    },
    {'1': 'scheme', '3': 3, '4': 1, '5': 9, '10': 'scheme'},
  ],
  '4': [RevokeRequest_Permission$json],
};

@$core.Deprecated('Use revokeRequestDescriptor instead')
const RevokeRequest_Permission$json = {
  '1': 'Permission',
  '2': [
    {'1': 'PHOTOS', '2': 0},
    {'1': 'CAMERA', '2': 1},
    {'1': 'CONTACTS', '2': 2},
    {'1': 'URL', '2': 3},
    {'1': 'LOCATION', '2': 4},
    {'1': 'NOTIFICATION', '2': 5},
    {'1': 'MICROPHONE', '2': 6},
  ],
};

/// Descriptor for `RevokeRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List revokeRequestDescriptor = $convert.base64Decode(
    'Cg1SZXZva2VSZXF1ZXN0EhsKCWJ1bmRsZV9pZBgBIAEoCVIIYnVuZGxlSWQSPwoLcGVybWlzc2'
    'lvbnMYAiADKA4yHS5pZGIuUmV2b2tlUmVxdWVzdC5QZXJtaXNzaW9uUgtwZXJtaXNzaW9ucxIW'
    'CgZzY2hlbWUYAyABKAlSBnNjaGVtZSJrCgpQZXJtaXNzaW9uEgoKBlBIT1RPUxAAEgoKBkNBTU'
    'VSQRABEgwKCENPTlRBQ1RTEAISBwoDVVJMEAMSDAoITE9DQVRJT04QBBIQCgxOT1RJRklDQVRJ'
    'T04QBRIOCgpNSUNST1BIT05FEAY=');

@$core.Deprecated('Use revokeResponseDescriptor instead')
const RevokeResponse$json = {
  '1': 'RevokeResponse',
};

/// Descriptor for `RevokeResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List revokeResponseDescriptor =
    $convert.base64Decode('Cg5SZXZva2VSZXNwb25zZQ==');

@$core.Deprecated('Use clearKeychainRequestDescriptor instead')
const ClearKeychainRequest$json = {
  '1': 'ClearKeychainRequest',
};

/// Descriptor for `ClearKeychainRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clearKeychainRequestDescriptor =
    $convert.base64Decode('ChRDbGVhcktleWNoYWluUmVxdWVzdA==');

@$core.Deprecated('Use clearKeychainResponseDescriptor instead')
const ClearKeychainResponse$json = {
  '1': 'ClearKeychainResponse',
};

/// Descriptor for `ClearKeychainResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clearKeychainResponseDescriptor =
    $convert.base64Decode('ChVDbGVhcktleWNoYWluUmVzcG9uc2U=');

@$core.Deprecated('Use setLocationRequestDescriptor instead')
const SetLocationRequest$json = {
  '1': 'SetLocationRequest',
  '2': [
    {
      '1': 'location',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.Location',
      '10': 'location'
    },
  ],
};

/// Descriptor for `SetLocationRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setLocationRequestDescriptor = $convert.base64Decode(
    'ChJTZXRMb2NhdGlvblJlcXVlc3QSKQoIbG9jYXRpb24YASABKAsyDS5pZGIuTG9jYXRpb25SCG'
    'xvY2F0aW9u');

@$core.Deprecated('Use locationDescriptor instead')
const Location$json = {
  '1': 'Location',
  '2': [
    {'1': 'latitude', '3': 1, '4': 1, '5': 1, '10': 'latitude'},
    {'1': 'longitude', '3': 2, '4': 1, '5': 1, '10': 'longitude'},
  ],
};

/// Descriptor for `Location`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List locationDescriptor = $convert.base64Decode(
    'CghMb2NhdGlvbhIaCghsYXRpdHVkZRgBIAEoAVIIbGF0aXR1ZGUSHAoJbG9uZ2l0dWRlGAIgAS'
    'gBUglsb25naXR1ZGU=');

@$core.Deprecated('Use setLocationResponseDescriptor instead')
const SetLocationResponse$json = {
  '1': 'SetLocationResponse',
};

/// Descriptor for `SetLocationResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setLocationResponseDescriptor =
    $convert.base64Decode('ChNTZXRMb2NhdGlvblJlc3BvbnNl');

@$core.Deprecated('Use uninstallRequestDescriptor instead')
const UninstallRequest$json = {
  '1': 'UninstallRequest',
  '2': [
    {'1': 'bundle_id', '3': 1, '4': 1, '5': 9, '10': 'bundleId'},
  ],
};

/// Descriptor for `UninstallRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uninstallRequestDescriptor = $convert.base64Decode(
    'ChBVbmluc3RhbGxSZXF1ZXN0EhsKCWJ1bmRsZV9pZBgBIAEoCVIIYnVuZGxlSWQ=');

@$core.Deprecated('Use uninstallResponseDescriptor instead')
const UninstallResponse$json = {
  '1': 'UninstallResponse',
};

/// Descriptor for `UninstallResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uninstallResponseDescriptor =
    $convert.base64Decode('ChFVbmluc3RhbGxSZXNwb25zZQ==');

@$core.Deprecated('Use terminateRequestDescriptor instead')
const TerminateRequest$json = {
  '1': 'TerminateRequest',
  '2': [
    {'1': 'bundle_id', '3': 1, '4': 1, '5': 9, '10': 'bundleId'},
  ],
};

/// Descriptor for `TerminateRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List terminateRequestDescriptor = $convert.base64Decode(
    'ChBUZXJtaW5hdGVSZXF1ZXN0EhsKCWJ1bmRsZV9pZBgBIAEoCVIIYnVuZGxlSWQ=');

@$core.Deprecated('Use terminateResponseDescriptor instead')
const TerminateResponse$json = {
  '1': 'TerminateResponse',
};

/// Descriptor for `TerminateResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List terminateResponseDescriptor =
    $convert.base64Decode('ChFUZXJtaW5hdGVSZXNwb25zZQ==');

@$core.Deprecated('Use openUrlRequestDescriptor instead')
const OpenUrlRequest$json = {
  '1': 'OpenUrlRequest',
  '2': [
    {'1': 'url', '3': 1, '4': 1, '5': 9, '10': 'url'},
  ],
};

/// Descriptor for `OpenUrlRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openUrlRequestDescriptor =
    $convert.base64Decode('Cg5PcGVuVXJsUmVxdWVzdBIQCgN1cmwYASABKAlSA3VybA==');

@$core.Deprecated('Use openUrlResponseDescriptor instead')
const OpenUrlResponse$json = {
  '1': 'OpenUrlResponse',
};

/// Descriptor for `OpenUrlResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List openUrlResponseDescriptor =
    $convert.base64Decode('Cg9PcGVuVXJsUmVzcG9uc2U=');

@$core.Deprecated('Use contactsUpdateRequestDescriptor instead')
const ContactsUpdateRequest$json = {
  '1': 'ContactsUpdateRequest',
  '2': [
    {
      '1': 'payload',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '10': 'payload'
    },
  ],
};

/// Descriptor for `ContactsUpdateRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List contactsUpdateRequestDescriptor = $convert.base64Decode(
    'ChVDb250YWN0c1VwZGF0ZVJlcXVlc3QSJgoHcGF5bG9hZBgBIAEoCzIMLmlkYi5QYXlsb2FkUg'
    'dwYXlsb2Fk');

@$core.Deprecated('Use contactsUpdateResponseDescriptor instead')
const ContactsUpdateResponse$json = {
  '1': 'ContactsUpdateResponse',
};

/// Descriptor for `ContactsUpdateResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List contactsUpdateResponseDescriptor =
    $convert.base64Decode('ChZDb250YWN0c1VwZGF0ZVJlc3BvbnNl');

@$core.Deprecated('Use contactsClearRequestDescriptor instead')
const ContactsClearRequest$json = {
  '1': 'ContactsClearRequest',
};

/// Descriptor for `ContactsClearRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List contactsClearRequestDescriptor =
    $convert.base64Decode('ChRDb250YWN0c0NsZWFyUmVxdWVzdA==');

@$core.Deprecated('Use contactsClearResponseDescriptor instead')
const ContactsClearResponse$json = {
  '1': 'ContactsClearResponse',
};

/// Descriptor for `ContactsClearResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List contactsClearResponseDescriptor =
    $convert.base64Decode('ChVDb250YWN0c0NsZWFyUmVzcG9uc2U=');

@$core.Deprecated('Use photosClearRequestDescriptor instead')
const PhotosClearRequest$json = {
  '1': 'PhotosClearRequest',
};

/// Descriptor for `PhotosClearRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List photosClearRequestDescriptor =
    $convert.base64Decode('ChJQaG90b3NDbGVhclJlcXVlc3Q=');

@$core.Deprecated('Use photosClearResponseDescriptor instead')
const PhotosClearResponse$json = {
  '1': 'PhotosClearResponse',
};

/// Descriptor for `PhotosClearResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List photosClearResponseDescriptor =
    $convert.base64Decode('ChNQaG90b3NDbGVhclJlc3BvbnNl');

@$core.Deprecated('Use targetDescriptionRequestDescriptor instead')
const TargetDescriptionRequest$json = {
  '1': 'TargetDescriptionRequest',
  '2': [
    {
      '1': 'fetch_diagnostics',
      '3': 1,
      '4': 1,
      '5': 8,
      '10': 'fetchDiagnostics'
    },
  ],
};

/// Descriptor for `TargetDescriptionRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List targetDescriptionRequestDescriptor =
    $convert.base64Decode(
        'ChhUYXJnZXREZXNjcmlwdGlvblJlcXVlc3QSKwoRZmV0Y2hfZGlhZ25vc3RpY3MYASABKAhSEG'
        'ZldGNoRGlhZ25vc3RpY3M=');

@$core.Deprecated('Use targetDescriptionResponseDescriptor instead')
const TargetDescriptionResponse$json = {
  '1': 'TargetDescriptionResponse',
  '2': [
    {
      '1': 'target_description',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.TargetDescription',
      '10': 'targetDescription'
    },
    {
      '1': 'companion',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.CompanionInfo',
      '10': 'companion'
    },
  ],
};

/// Descriptor for `TargetDescriptionResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List targetDescriptionResponseDescriptor = $convert.base64Decode(
    'ChlUYXJnZXREZXNjcmlwdGlvblJlc3BvbnNlEkUKEnRhcmdldF9kZXNjcmlwdGlvbhgBIAEoCz'
    'IWLmlkYi5UYXJnZXREZXNjcmlwdGlvblIRdGFyZ2V0RGVzY3JpcHRpb24SMAoJY29tcGFuaW9u'
    'GAIgASgLMhIuaWRiLkNvbXBhbmlvbkluZm9SCWNvbXBhbmlvbg==');

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent$json = {
  '1': 'HIDEvent',
  '2': [
    {
      '1': 'press',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.HIDEvent.HIDPress',
      '9': 0,
      '10': 'press'
    },
    {
      '1': 'swipe',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.HIDEvent.HIDSwipe',
      '9': 0,
      '10': 'swipe'
    },
    {
      '1': 'delay',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.HIDEvent.HIDDelay',
      '9': 0,
      '10': 'delay'
    },
    {
      '1': 'pinch',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.idb.HIDEvent.HIDPinch',
      '9': 0,
      '10': 'pinch'
    },
    {
      '1': 'orientation',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.idb.HIDEvent.HIDOrientation',
      '9': 0,
      '10': 'orientation'
    },
    {
      '1': 'shake',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.idb.HIDEvent.HIDShake',
      '9': 0,
      '10': 'shake'
    },
  ],
  '3': [
    HIDEvent_HIDTouch$json,
    HIDEvent_HIDButton$json,
    HIDEvent_HIDKey$json,
    HIDEvent_HIDPressAction$json,
    HIDEvent_HIDPress$json,
    HIDEvent_HIDSwipe$json,
    HIDEvent_HIDDelay$json,
    HIDEvent_HIDPinch$json,
    HIDEvent_HIDOrientation$json,
    HIDEvent_HIDShake$json
  ],
  '4': [
    HIDEvent_HIDDirection$json,
    HIDEvent_HIDButtonType$json,
    HIDEvent_HIDOrientationType$json
  ],
  '8': [
    {'1': 'event'},
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDTouch$json = {
  '1': 'HIDTouch',
  '2': [
    {'1': 'point', '3': 1, '4': 1, '5': 11, '6': '.idb.Point', '10': 'point'},
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDButton$json = {
  '1': 'HIDButton',
  '2': [
    {
      '1': 'button',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.HIDEvent.HIDButtonType',
      '10': 'button'
    },
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDKey$json = {
  '1': 'HIDKey',
  '2': [
    {'1': 'keycode', '3': 1, '4': 1, '5': 4, '10': 'keycode'},
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDPressAction$json = {
  '1': 'HIDPressAction',
  '2': [
    {
      '1': 'touch',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.HIDEvent.HIDTouch',
      '9': 0,
      '10': 'touch'
    },
    {
      '1': 'button',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.HIDEvent.HIDButton',
      '9': 0,
      '10': 'button'
    },
    {
      '1': 'key',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.HIDEvent.HIDKey',
      '9': 0,
      '10': 'key'
    },
  ],
  '8': [
    {'1': 'action'},
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDPress$json = {
  '1': 'HIDPress',
  '2': [
    {
      '1': 'action',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.HIDEvent.HIDPressAction',
      '10': 'action'
    },
    {
      '1': 'direction',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.idb.HIDEvent.HIDDirection',
      '10': 'direction'
    },
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDSwipe$json = {
  '1': 'HIDSwipe',
  '2': [
    {'1': 'start', '3': 1, '4': 1, '5': 11, '6': '.idb.Point', '10': 'start'},
    {'1': 'end', '3': 2, '4': 1, '5': 11, '6': '.idb.Point', '10': 'end'},
    {'1': 'delta', '3': 5, '4': 1, '5': 1, '10': 'delta'},
    {'1': 'duration', '3': 6, '4': 1, '5': 1, '10': 'duration'},
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDDelay$json = {
  '1': 'HIDDelay',
  '2': [
    {'1': 'duration', '3': 1, '4': 1, '5': 1, '10': 'duration'},
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDPinch$json = {
  '1': 'HIDPinch',
  '2': [
    {'1': 'center', '3': 1, '4': 1, '5': 11, '6': '.idb.Point', '10': 'center'},
    {'1': 'scale', '3': 2, '4': 1, '5': 1, '10': 'scale'},
    {'1': 'duration', '3': 3, '4': 1, '5': 1, '10': 'duration'},
    {'1': 'radius', '3': 4, '4': 1, '5': 1, '10': 'radius'},
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDOrientation$json = {
  '1': 'HIDOrientation',
  '2': [
    {
      '1': 'orientation',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.HIDEvent.HIDOrientationType',
      '10': 'orientation'
    },
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDShake$json = {
  '1': 'HIDShake',
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDDirection$json = {
  '1': 'HIDDirection',
  '2': [
    {'1': 'DOWN', '2': 0},
    {'1': 'UP', '2': 1},
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDButtonType$json = {
  '1': 'HIDButtonType',
  '2': [
    {'1': 'APPLE_PAY', '2': 0},
    {'1': 'HOME', '2': 1},
    {'1': 'LOCK', '2': 2},
    {'1': 'SIDE_BUTTON', '2': 3},
    {'1': 'SIRI', '2': 4},
  ],
};

@$core.Deprecated('Use hIDEventDescriptor instead')
const HIDEvent_HIDOrientationType$json = {
  '1': 'HIDOrientationType',
  '2': [
    {'1': 'PORTRAIT', '2': 0},
    {'1': 'PORTRAIT_UPSIDE_DOWN', '2': 1},
    {'1': 'LANDSCAPE_LEFT', '2': 2},
    {'1': 'LANDSCAPE_RIGHT', '2': 3},
  ],
};

/// Descriptor for `HIDEvent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List hIDEventDescriptor = $convert.base64Decode(
    'CghISURFdmVudBIuCgVwcmVzcxgBIAEoCzIWLmlkYi5ISURFdmVudC5ISURQcmVzc0gAUgVwcm'
    'VzcxIuCgVzd2lwZRgCIAEoCzIWLmlkYi5ISURFdmVudC5ISURTd2lwZUgAUgVzd2lwZRIuCgVk'
    'ZWxheRgDIAEoCzIWLmlkYi5ISURFdmVudC5ISUREZWxheUgAUgVkZWxheRIuCgVwaW5jaBgEIA'
    'EoCzIWLmlkYi5ISURFdmVudC5ISURQaW5jaEgAUgVwaW5jaBJACgtvcmllbnRhdGlvbhgFIAEo'
    'CzIcLmlkYi5ISURFdmVudC5ISURPcmllbnRhdGlvbkgAUgtvcmllbnRhdGlvbhIuCgVzaGFrZR'
    'gGIAEoCzIWLmlkYi5ISURFdmVudC5ISURTaGFrZUgAUgVzaGFrZRosCghISURUb3VjaBIgCgVw'
    'b2ludBgBIAEoCzIKLmlkYi5Qb2ludFIFcG9pbnQaQAoJSElEQnV0dG9uEjMKBmJ1dHRvbhgBIA'
    'EoDjIbLmlkYi5ISURFdmVudC5ISURCdXR0b25UeXBlUgZidXR0b24aIgoGSElES2V5EhgKB2tl'
    'eWNvZGUYASABKARSB2tleWNvZGUapwEKDkhJRFByZXNzQWN0aW9uEi4KBXRvdWNoGAEgASgLMh'
    'YuaWRiLkhJREV2ZW50LkhJRFRvdWNoSABSBXRvdWNoEjEKBmJ1dHRvbhgCIAEoCzIXLmlkYi5I'
    'SURFdmVudC5ISURCdXR0b25IAFIGYnV0dG9uEigKA2tleRgDIAEoCzIULmlkYi5ISURFdmVudC'
    '5ISURLZXlIAFIDa2V5QggKBmFjdGlvbhp6CghISURQcmVzcxI0CgZhY3Rpb24YASABKAsyHC5p'
    'ZGIuSElERXZlbnQuSElEUHJlc3NBY3Rpb25SBmFjdGlvbhI4CglkaXJlY3Rpb24YAiABKA4yGi'
    '5pZGIuSElERXZlbnQuSElERGlyZWN0aW9uUglkaXJlY3Rpb24afAoISElEU3dpcGUSIAoFc3Rh'
    'cnQYASABKAsyCi5pZGIuUG9pbnRSBXN0YXJ0EhwKA2VuZBgCIAEoCzIKLmlkYi5Qb2ludFIDZW'
    '5kEhQKBWRlbHRhGAUgASgBUgVkZWx0YRIaCghkdXJhdGlvbhgGIAEoAVIIZHVyYXRpb24aJgoI'
    'SElERGVsYXkSGgoIZHVyYXRpb24YASABKAFSCGR1cmF0aW9uGngKCEhJRFBpbmNoEiIKBmNlbn'
    'RlchgBIAEoCzIKLmlkYi5Qb2ludFIGY2VudGVyEhQKBXNjYWxlGAIgASgBUgVzY2FsZRIaCghk'
    'dXJhdGlvbhgDIAEoAVIIZHVyYXRpb24SFgoGcmFkaXVzGAQgASgBUgZyYWRpdXMaVAoOSElET3'
    'JpZW50YXRpb24SQgoLb3JpZW50YXRpb24YASABKA4yIC5pZGIuSElERXZlbnQuSElET3JpZW50'
    'YXRpb25UeXBlUgtvcmllbnRhdGlvbhoKCghISURTaGFrZSIgCgxISUREaXJlY3Rpb24SCAoERE'
    '9XThAAEgYKAlVQEAEiTQoNSElEQnV0dG9uVHlwZRINCglBUFBMRV9QQVkQABIICgRIT01FEAES'
    'CAoETE9DSxACEg8KC1NJREVfQlVUVE9OEAMSCAoEU0lSSRAEImUKEkhJRE9yaWVudGF0aW9uVH'
    'lwZRIMCghQT1JUUkFJVBAAEhgKFFBPUlRSQUlUX1VQU0lERV9ET1dOEAESEgoOTEFORFNDQVBF'
    'X0xFRlQQAhITCg9MQU5EU0NBUEVfUklHSFQQA0IHCgVldmVudA==');

@$core.Deprecated('Use hIDResponseDescriptor instead')
const HIDResponse$json = {
  '1': 'HIDResponse',
};

/// Descriptor for `HIDResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List hIDResponseDescriptor =
    $convert.base64Decode('CgtISURSZXNwb25zZQ==');

@$core.Deprecated('Use connectRequestDescriptor instead')
const ConnectRequest$json = {
  '1': 'ConnectRequest',
  '2': [
    {
      '1': 'metadata',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.idb.ConnectRequest.MetadataEntry',
      '10': 'metadata'
    },
    {'1': 'local_file_path', '3': 4, '4': 1, '5': 9, '10': 'localFilePath'},
  ],
  '3': [ConnectRequest_MetadataEntry$json],
};

@$core.Deprecated('Use connectRequestDescriptor instead')
const ConnectRequest_MetadataEntry$json = {
  '1': 'MetadataEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `ConnectRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List connectRequestDescriptor = $convert.base64Decode(
    'Cg5Db25uZWN0UmVxdWVzdBI9CghtZXRhZGF0YRgBIAMoCzIhLmlkYi5Db25uZWN0UmVxdWVzdC'
    '5NZXRhZGF0YUVudHJ5UghtZXRhZGF0YRImCg9sb2NhbF9maWxlX3BhdGgYBCABKAlSDWxvY2Fs'
    'RmlsZVBhdGgaOwoNTWV0YWRhdGFFbnRyeRIQCgNrZXkYASABKAlSA2tleRIUCgV2YWx1ZRgCIA'
    'EoCVIFdmFsdWU6AjgB');

@$core.Deprecated('Use connectResponseDescriptor instead')
const ConnectResponse$json = {
  '1': 'ConnectResponse',
  '2': [
    {
      '1': 'companion',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.CompanionInfo',
      '10': 'companion'
    },
  ],
};

/// Descriptor for `ConnectResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List connectResponseDescriptor = $convert.base64Decode(
    'Cg9Db25uZWN0UmVzcG9uc2USMAoJY29tcGFuaW9uGAEgASgLMhIuaWRiLkNvbXBhbmlvbkluZm'
    '9SCWNvbXBhbmlvbg==');

@$core.Deprecated('Use screenDimensionsDescriptor instead')
const ScreenDimensions$json = {
  '1': 'ScreenDimensions',
  '2': [
    {'1': 'width', '3': 1, '4': 1, '5': 4, '10': 'width'},
    {'1': 'height', '3': 2, '4': 1, '5': 4, '10': 'height'},
    {'1': 'density', '3': 3, '4': 1, '5': 1, '10': 'density'},
    {'1': 'width_points', '3': 4, '4': 1, '5': 4, '10': 'widthPoints'},
    {'1': 'height_points', '3': 5, '4': 1, '5': 4, '10': 'heightPoints'},
  ],
};

/// Descriptor for `ScreenDimensions`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List screenDimensionsDescriptor = $convert.base64Decode(
    'ChBTY3JlZW5EaW1lbnNpb25zEhQKBXdpZHRoGAEgASgEUgV3aWR0aBIWCgZoZWlnaHQYAiABKA'
    'RSBmhlaWdodBIYCgdkZW5zaXR5GAMgASgBUgdkZW5zaXR5EiEKDHdpZHRoX3BvaW50cxgEIAEo'
    'BFILd2lkdGhQb2ludHMSIwoNaGVpZ2h0X3BvaW50cxgFIAEoBFIMaGVpZ2h0UG9pbnRz');

@$core.Deprecated('Use targetDescriptionDescriptor instead')
const TargetDescription$json = {
  '1': 'TargetDescription',
  '2': [
    {'1': 'udid', '3': 1, '4': 1, '5': 9, '10': 'udid'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'screen_dimensions',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.ScreenDimensions',
      '10': 'screenDimensions'
    },
    {'1': 'state', '3': 4, '4': 1, '5': 9, '10': 'state'},
    {'1': 'target_type', '3': 5, '4': 1, '5': 9, '10': 'targetType'},
    {'1': 'os_version', '3': 6, '4': 1, '5': 9, '10': 'osVersion'},
    {'1': 'architecture', '3': 7, '4': 1, '5': 9, '10': 'architecture'},
    {'1': 'extended', '3': 9, '4': 1, '5': 12, '10': 'extended'},
    {'1': 'diagnostics', '3': 10, '4': 1, '5': 12, '10': 'diagnostics'},
  ],
};

/// Descriptor for `TargetDescription`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List targetDescriptionDescriptor = $convert.base64Decode(
    'ChFUYXJnZXREZXNjcmlwdGlvbhISCgR1ZGlkGAEgASgJUgR1ZGlkEhIKBG5hbWUYAiABKAlSBG'
    '5hbWUSQgoRc2NyZWVuX2RpbWVuc2lvbnMYAyABKAsyFS5pZGIuU2NyZWVuRGltZW5zaW9uc1IQ'
    'c2NyZWVuRGltZW5zaW9ucxIUCgVzdGF0ZRgEIAEoCVIFc3RhdGUSHwoLdGFyZ2V0X3R5cGUYBS'
    'ABKAlSCnRhcmdldFR5cGUSHQoKb3NfdmVyc2lvbhgGIAEoCVIJb3NWZXJzaW9uEiIKDGFyY2hp'
    'dGVjdHVyZRgHIAEoCVIMYXJjaGl0ZWN0dXJlEhoKCGV4dGVuZGVkGAkgASgMUghleHRlbmRlZB'
    'IgCgtkaWFnbm9zdGljcxgKIAEoDFILZGlhZ25vc3RpY3M=');

@$core.Deprecated('Use logRequestDescriptor instead')
const LogRequest$json = {
  '1': 'LogRequest',
  '2': [
    {'1': 'arguments', '3': 1, '4': 3, '5': 9, '10': 'arguments'},
    {
      '1': 'source',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.idb.LogRequest.Source',
      '10': 'source'
    },
  ],
  '4': [LogRequest_Source$json],
};

@$core.Deprecated('Use logRequestDescriptor instead')
const LogRequest_Source$json = {
  '1': 'Source',
  '2': [
    {'1': 'TARGET', '2': 0},
    {'1': 'COMPANION', '2': 1},
  ],
};

/// Descriptor for `LogRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List logRequestDescriptor = $convert.base64Decode(
    'CgpMb2dSZXF1ZXN0EhwKCWFyZ3VtZW50cxgBIAMoCVIJYXJndW1lbnRzEi4KBnNvdXJjZRgCIA'
    'EoDjIWLmlkYi5Mb2dSZXF1ZXN0LlNvdXJjZVIGc291cmNlIiMKBlNvdXJjZRIKCgZUQVJHRVQQ'
    'ABINCglDT01QQU5JT04QAQ==');

@$core.Deprecated('Use logResponseDescriptor instead')
const LogResponse$json = {
  '1': 'LogResponse',
  '2': [
    {'1': 'output', '3': 1, '4': 1, '5': 12, '10': 'output'},
  ],
};

/// Descriptor for `LogResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List logResponseDescriptor = $convert
    .base64Decode('CgtMb2dSZXNwb25zZRIWCgZvdXRwdXQYASABKAxSBm91dHB1dA==');

@$core.Deprecated('Use recordRequestDescriptor instead')
const RecordRequest$json = {
  '1': 'RecordRequest',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.RecordRequest.Start',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'stop',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.RecordRequest.Stop',
      '9': 0,
      '10': 'stop'
    },
  ],
  '3': [RecordRequest_Start$json, RecordRequest_Stop$json],
  '8': [
    {'1': 'control'},
  ],
};

@$core.Deprecated('Use recordRequestDescriptor instead')
const RecordRequest_Start$json = {
  '1': 'Start',
  '2': [
    {'1': 'file_path', '3': 1, '4': 1, '5': 9, '10': 'filePath'},
  ],
};

@$core.Deprecated('Use recordRequestDescriptor instead')
const RecordRequest_Stop$json = {
  '1': 'Stop',
};

/// Descriptor for `RecordRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List recordRequestDescriptor = $convert.base64Decode(
    'Cg1SZWNvcmRSZXF1ZXN0EjAKBXN0YXJ0GAEgASgLMhguaWRiLlJlY29yZFJlcXVlc3QuU3Rhcn'
    'RIAFIFc3RhcnQSLQoEc3RvcBgCIAEoCzIXLmlkYi5SZWNvcmRSZXF1ZXN0LlN0b3BIAFIEc3Rv'
    'cBokCgVTdGFydBIbCglmaWxlX3BhdGgYASABKAlSCGZpbGVQYXRoGgYKBFN0b3BCCQoHY29udH'
    'JvbA==');

@$core.Deprecated('Use recordResponseDescriptor instead')
const RecordResponse$json = {
  '1': 'RecordResponse',
  '2': [
    {'1': 'log_output', '3': 1, '4': 1, '5': 12, '9': 0, '10': 'logOutput'},
    {
      '1': 'payload',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '9': 0,
      '10': 'payload'
    },
  ],
  '8': [
    {'1': 'output'},
  ],
};

/// Descriptor for `RecordResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List recordResponseDescriptor = $convert.base64Decode(
    'Cg5SZWNvcmRSZXNwb25zZRIfCgpsb2dfb3V0cHV0GAEgASgMSABSCWxvZ091dHB1dBIoCgdwYX'
    'lsb2FkGAIgASgLMgwuaWRiLlBheWxvYWRIAFIHcGF5bG9hZEIICgZvdXRwdXQ=');

@$core.Deprecated('Use videoStreamRequestDescriptor instead')
const VideoStreamRequest$json = {
  '1': 'VideoStreamRequest',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.VideoStreamRequest.Start',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'stop',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.VideoStreamRequest.Stop',
      '9': 0,
      '10': 'stop'
    },
  ],
  '3': [VideoStreamRequest_Start$json, VideoStreamRequest_Stop$json],
  '4': [VideoStreamRequest_Format$json],
  '8': [
    {'1': 'control'},
  ],
};

@$core.Deprecated('Use videoStreamRequestDescriptor instead')
const VideoStreamRequest_Start$json = {
  '1': 'Start',
  '2': [
    {'1': 'file_path', '3': 1, '4': 1, '5': 9, '10': 'filePath'},
    {'1': 'fps', '3': 2, '4': 1, '5': 4, '10': 'fps'},
    {
      '1': 'format',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.idb.VideoStreamRequest.Format',
      '10': 'format'
    },
    {
      '1': 'compression_quality',
      '3': 4,
      '4': 1,
      '5': 1,
      '10': 'compressionQuality'
    },
    {'1': 'scale_factor', '3': 5, '4': 1, '5': 1, '10': 'scaleFactor'},
    {'1': 'avg_bitrate', '3': 6, '4': 1, '5': 1, '10': 'avgBitrate'},
    {'1': 'key_frame_rate', '3': 7, '4': 1, '5': 1, '10': 'keyFrameRate'},
  ],
};

@$core.Deprecated('Use videoStreamRequestDescriptor instead')
const VideoStreamRequest_Stop$json = {
  '1': 'Stop',
};

@$core.Deprecated('Use videoStreamRequestDescriptor instead')
const VideoStreamRequest_Format$json = {
  '1': 'Format',
  '2': [
    {'1': 'H264', '2': 0},
    {'1': 'RBGA', '2': 1},
    {'1': 'MJPEG', '2': 2},
    {'1': 'MINICAP', '2': 3},
    {'1': 'I420', '2': 4},
  ],
};

/// Descriptor for `VideoStreamRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List videoStreamRequestDescriptor = $convert.base64Decode(
    'ChJWaWRlb1N0cmVhbVJlcXVlc3QSNQoFc3RhcnQYASABKAsyHS5pZGIuVmlkZW9TdHJlYW1SZX'
    'F1ZXN0LlN0YXJ0SABSBXN0YXJ0EjIKBHN0b3AYAiABKAsyHC5pZGIuVmlkZW9TdHJlYW1SZXF1'
    'ZXN0LlN0b3BIAFIEc3RvcBqJAgoFU3RhcnQSGwoJZmlsZV9wYXRoGAEgASgJUghmaWxlUGF0aB'
    'IQCgNmcHMYAiABKARSA2ZwcxI2CgZmb3JtYXQYAyABKA4yHi5pZGIuVmlkZW9TdHJlYW1SZXF1'
    'ZXN0LkZvcm1hdFIGZm9ybWF0Ei8KE2NvbXByZXNzaW9uX3F1YWxpdHkYBCABKAFSEmNvbXByZX'
    'NzaW9uUXVhbGl0eRIhCgxzY2FsZV9mYWN0b3IYBSABKAFSC3NjYWxlRmFjdG9yEh8KC2F2Z19i'
    'aXRyYXRlGAYgASgBUgphdmdCaXRyYXRlEiQKDmtleV9mcmFtZV9yYXRlGAcgASgBUgxrZXlGcm'
    'FtZVJhdGUaBgoEU3RvcCI+CgZGb3JtYXQSCAoESDI2NBAAEggKBFJCR0EQARIJCgVNSlBFRxAC'
    'EgsKB01JTklDQVAQAxIICgRJNDIwEARCCQoHY29udHJvbA==');

@$core.Deprecated('Use videoStreamResponseDescriptor instead')
const VideoStreamResponse$json = {
  '1': 'VideoStreamResponse',
  '2': [
    {'1': 'log_output', '3': 1, '4': 1, '5': 12, '9': 0, '10': 'logOutput'},
    {
      '1': 'payload',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '9': 0,
      '10': 'payload'
    },
  ],
  '8': [
    {'1': 'output'},
  ],
};

/// Descriptor for `VideoStreamResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List videoStreamResponseDescriptor = $convert.base64Decode(
    'ChNWaWRlb1N0cmVhbVJlc3BvbnNlEh8KCmxvZ19vdXRwdXQYASABKAxIAFIJbG9nT3V0cHV0Ei'
    'gKB3BheWxvYWQYAiABKAsyDC5pZGIuUGF5bG9hZEgAUgdwYXlsb2FkQggKBm91dHB1dA==');

@$core.Deprecated('Use launchRequestDescriptor instead')
const LaunchRequest$json = {
  '1': 'LaunchRequest',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.LaunchRequest.Start',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'stop',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.LaunchRequest.Stop',
      '9': 0,
      '10': 'stop'
    },
  ],
  '3': [LaunchRequest_Start$json, LaunchRequest_Stop$json],
  '8': [
    {'1': 'control'},
  ],
};

@$core.Deprecated('Use launchRequestDescriptor instead')
const LaunchRequest_Start$json = {
  '1': 'Start',
  '2': [
    {'1': 'bundle_id', '3': 1, '4': 1, '5': 9, '10': 'bundleId'},
    {
      '1': 'env',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.idb.LaunchRequest.Start.EnvEntry',
      '10': 'env'
    },
    {'1': 'app_args', '3': 3, '4': 3, '5': 9, '10': 'appArgs'},
    {
      '1': 'foreground_if_running',
      '3': 4,
      '4': 1,
      '5': 8,
      '10': 'foregroundIfRunning'
    },
    {'1': 'wait_for', '3': 5, '4': 1, '5': 8, '10': 'waitFor'},
    {'1': 'wait_for_debugger', '3': 6, '4': 1, '5': 8, '10': 'waitForDebugger'},
    {'1': 'enable_repl', '3': 7, '4': 1, '5': 8, '10': 'enableRepl'},
  ],
  '3': [LaunchRequest_Start_EnvEntry$json],
};

@$core.Deprecated('Use launchRequestDescriptor instead')
const LaunchRequest_Start_EnvEntry$json = {
  '1': 'EnvEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use launchRequestDescriptor instead')
const LaunchRequest_Stop$json = {
  '1': 'Stop',
};

/// Descriptor for `LaunchRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List launchRequestDescriptor = $convert.base64Decode(
    'Cg1MYXVuY2hSZXF1ZXN0EjAKBXN0YXJ0GAEgASgLMhguaWRiLkxhdW5jaFJlcXVlc3QuU3Rhcn'
    'RIAFIFc3RhcnQSLQoEc3RvcBgCIAEoCzIXLmlkYi5MYXVuY2hSZXF1ZXN0LlN0b3BIAFIEc3Rv'
    'cBrIAgoFU3RhcnQSGwoJYnVuZGxlX2lkGAEgASgJUghidW5kbGVJZBIzCgNlbnYYAiADKAsyIS'
    '5pZGIuTGF1bmNoUmVxdWVzdC5TdGFydC5FbnZFbnRyeVIDZW52EhkKCGFwcF9hcmdzGAMgAygJ'
    'UgdhcHBBcmdzEjIKFWZvcmVncm91bmRfaWZfcnVubmluZxgEIAEoCFITZm9yZWdyb3VuZElmUn'
    'VubmluZxIZCgh3YWl0X2ZvchgFIAEoCFIHd2FpdEZvchIqChF3YWl0X2Zvcl9kZWJ1Z2dlchgG'
    'IAEoCFIPd2FpdEZvckRlYnVnZ2VyEh8KC2VuYWJsZV9yZXBsGAcgASgIUgplbmFibGVSZXBsGj'
    'YKCEVudkVudHJ5EhAKA2tleRgBIAEoCVIDa2V5EhQKBXZhbHVlGAIgASgJUgV2YWx1ZToCOAEa'
    'BgoEU3RvcEIJCgdjb250cm9s');

@$core.Deprecated('Use launchResponseDescriptor instead')
const LaunchResponse$json = {
  '1': 'LaunchResponse',
  '2': [
    {
      '1': 'output',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.ProcessOutput',
      '10': 'output'
    },
    {
      '1': 'debugger',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.idb.DebuggerInfo',
      '10': 'debugger'
    },
  ],
};

/// Descriptor for `LaunchResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List launchResponseDescriptor = $convert.base64Decode(
    'Cg5MYXVuY2hSZXNwb25zZRIqCgZvdXRwdXQYAyABKAsyEi5pZGIuUHJvY2Vzc091dHB1dFIGb3'
    'V0cHV0Ei0KCGRlYnVnZ2VyGAQgASgLMhEuaWRiLkRlYnVnZ2VySW5mb1IIZGVidWdnZXI=');

@$core.Deprecated('Use addMediaRequestDescriptor instead')
const AddMediaRequest$json = {
  '1': 'AddMediaRequest',
  '2': [
    {
      '1': 'payload',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '10': 'payload'
    },
  ],
};

/// Descriptor for `AddMediaRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List addMediaRequestDescriptor = $convert.base64Decode(
    'Cg9BZGRNZWRpYVJlcXVlc3QSJgoHcGF5bG9hZBgBIAEoCzIMLmlkYi5QYXlsb2FkUgdwYXlsb2'
    'Fk');

@$core.Deprecated('Use addMediaResponseDescriptor instead')
const AddMediaResponse$json = {
  '1': 'AddMediaResponse',
};

/// Descriptor for `AddMediaResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List addMediaResponseDescriptor =
    $convert.base64Decode('ChBBZGRNZWRpYVJlc3BvbnNl');

@$core.Deprecated('Use instrumentsRunRequestDescriptor instead')
const InstrumentsRunRequest$json = {
  '1': 'InstrumentsRunRequest',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.InstrumentsRunRequest.Start',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'stop',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.InstrumentsRunRequest.Stop',
      '9': 0,
      '10': 'stop'
    },
  ],
  '3': [
    InstrumentsRunRequest_InstrumentsTimings$json,
    InstrumentsRunRequest_Start$json,
    InstrumentsRunRequest_Stop$json
  ],
  '8': [
    {'1': 'control'},
  ],
};

@$core.Deprecated('Use instrumentsRunRequestDescriptor instead')
const InstrumentsRunRequest_InstrumentsTimings$json = {
  '1': 'InstrumentsTimings',
  '2': [
    {
      '1': 'terminate_timeout',
      '3': 1,
      '4': 1,
      '5': 1,
      '10': 'terminateTimeout'
    },
    {
      '1': 'launch_retry_timeout',
      '3': 2,
      '4': 1,
      '5': 1,
      '10': 'launchRetryTimeout'
    },
    {
      '1': 'launch_error_timeout',
      '3': 3,
      '4': 1,
      '5': 1,
      '10': 'launchErrorTimeout'
    },
    {
      '1': 'operation_duration',
      '3': 4,
      '4': 1,
      '5': 1,
      '10': 'operationDuration'
    },
  ],
};

@$core.Deprecated('Use instrumentsRunRequestDescriptor instead')
const InstrumentsRunRequest_Start$json = {
  '1': 'Start',
  '2': [
    {'1': 'template_name', '3': 2, '4': 1, '5': 9, '10': 'templateName'},
    {'1': 'app_bundle_id', '3': 3, '4': 1, '5': 9, '10': 'appBundleId'},
    {
      '1': 'environment',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.idb.InstrumentsRunRequest.Start.EnvironmentEntry',
      '10': 'environment'
    },
    {'1': 'arguments', '3': 5, '4': 3, '5': 9, '10': 'arguments'},
    {
      '1': 'timings',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.idb.InstrumentsRunRequest.InstrumentsTimings',
      '10': 'timings'
    },
    {'1': 'tool_arguments', '3': 7, '4': 3, '5': 9, '10': 'toolArguments'},
  ],
  '3': [InstrumentsRunRequest_Start_EnvironmentEntry$json],
};

@$core.Deprecated('Use instrumentsRunRequestDescriptor instead')
const InstrumentsRunRequest_Start_EnvironmentEntry$json = {
  '1': 'EnvironmentEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use instrumentsRunRequestDescriptor instead')
const InstrumentsRunRequest_Stop$json = {
  '1': 'Stop',
  '2': [
    {
      '1': 'post_process_arguments',
      '3': 1,
      '4': 3,
      '5': 9,
      '10': 'postProcessArguments'
    },
  ],
};

/// Descriptor for `InstrumentsRunRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List instrumentsRunRequestDescriptor = $convert.base64Decode(
    'ChVJbnN0cnVtZW50c1J1blJlcXVlc3QSOAoFc3RhcnQYASABKAsyIC5pZGIuSW5zdHJ1bWVudH'
    'NSdW5SZXF1ZXN0LlN0YXJ0SABSBXN0YXJ0EjUKBHN0b3AYAiABKAsyHy5pZGIuSW5zdHJ1bWVu'
    'dHNSdW5SZXF1ZXN0LlN0b3BIAFIEc3RvcBrUAQoSSW5zdHJ1bWVudHNUaW1pbmdzEisKEXRlcm'
    '1pbmF0ZV90aW1lb3V0GAEgASgBUhB0ZXJtaW5hdGVUaW1lb3V0EjAKFGxhdW5jaF9yZXRyeV90'
    'aW1lb3V0GAIgASgBUhJsYXVuY2hSZXRyeVRpbWVvdXQSMAoUbGF1bmNoX2Vycm9yX3RpbWVvdX'
    'QYAyABKAFSEmxhdW5jaEVycm9yVGltZW91dBItChJvcGVyYXRpb25fZHVyYXRpb24YBCABKAFS'
    'EW9wZXJhdGlvbkR1cmF0aW9uGvMCCgVTdGFydBIjCg10ZW1wbGF0ZV9uYW1lGAIgASgJUgx0ZW'
    '1wbGF0ZU5hbWUSIgoNYXBwX2J1bmRsZV9pZBgDIAEoCVILYXBwQnVuZGxlSWQSUwoLZW52aXJv'
    'bm1lbnQYBCADKAsyMS5pZGIuSW5zdHJ1bWVudHNSdW5SZXF1ZXN0LlN0YXJ0LkVudmlyb25tZW'
    '50RW50cnlSC2Vudmlyb25tZW50EhwKCWFyZ3VtZW50cxgFIAMoCVIJYXJndW1lbnRzEkcKB3Rp'
    'bWluZ3MYBiABKAsyLS5pZGIuSW5zdHJ1bWVudHNSdW5SZXF1ZXN0Lkluc3RydW1lbnRzVGltaW'
    '5nc1IHdGltaW5ncxIlCg50b29sX2FyZ3VtZW50cxgHIAMoCVINdG9vbEFyZ3VtZW50cxo+ChBF'
    'bnZpcm9ubWVudEVudHJ5EhAKA2tleRgBIAEoCVIDa2V5EhQKBXZhbHVlGAIgASgJUgV2YWx1ZT'
    'oCOAEaPAoEU3RvcBI0ChZwb3N0X3Byb2Nlc3NfYXJndW1lbnRzGAEgAygJUhRwb3N0UHJvY2Vz'
    'c0FyZ3VtZW50c0IJCgdjb250cm9s');

@$core.Deprecated('Use instrumentsRunResponseDescriptor instead')
const InstrumentsRunResponse$json = {
  '1': 'InstrumentsRunResponse',
  '2': [
    {'1': 'log_output', '3': 1, '4': 1, '5': 12, '9': 0, '10': 'logOutput'},
    {
      '1': 'payload',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '9': 0,
      '10': 'payload'
    },
    {
      '1': 'state',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.idb.InstrumentsRunResponse.State',
      '9': 0,
      '10': 'state'
    },
  ],
  '4': [InstrumentsRunResponse_State$json],
  '8': [
    {'1': 'output'},
  ],
};

@$core.Deprecated('Use instrumentsRunResponseDescriptor instead')
const InstrumentsRunResponse_State$json = {
  '1': 'State',
  '2': [
    {'1': 'UNKNOWN', '2': 0},
    {'1': 'RUNNING_INSTRUMENTS', '2': 1},
    {'1': 'POST_PROCESSING', '2': 2},
  ],
};

/// Descriptor for `InstrumentsRunResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List instrumentsRunResponseDescriptor = $convert.base64Decode(
    'ChZJbnN0cnVtZW50c1J1blJlc3BvbnNlEh8KCmxvZ19vdXRwdXQYASABKAxIAFIJbG9nT3V0cH'
    'V0EigKB3BheWxvYWQYAiABKAsyDC5pZGIuUGF5bG9hZEgAUgdwYXlsb2FkEjkKBXN0YXRlGAMg'
    'ASgOMiEuaWRiLkluc3RydW1lbnRzUnVuUmVzcG9uc2UuU3RhdGVIAFIFc3RhdGUiQgoFU3RhdG'
    'USCwoHVU5LTk9XThAAEhcKE1JVTk5JTkdfSU5TVFJVTUVOVFMQARITCg9QT1NUX1BST0NFU1NJ'
    'TkcQAkIICgZvdXRwdXQ=');

@$core.Deprecated('Use xctraceRecordRequestDescriptor instead')
const XctraceRecordRequest$json = {
  '1': 'XctraceRecordRequest',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.XctraceRecordRequest.Start',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'stop',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.XctraceRecordRequest.Stop',
      '9': 0,
      '10': 'stop'
    },
  ],
  '3': [
    XctraceRecordRequest_LauchProcess$json,
    XctraceRecordRequest_Target$json,
    XctraceRecordRequest_Start$json,
    XctraceRecordRequest_Stop$json
  ],
  '8': [
    {'1': 'control'},
  ],
};

@$core.Deprecated('Use xctraceRecordRequestDescriptor instead')
const XctraceRecordRequest_LauchProcess$json = {
  '1': 'LauchProcess',
  '2': [
    {'1': 'process_to_launch', '3': 1, '4': 1, '5': 9, '10': 'processToLaunch'},
    {'1': 'launch_args', '3': 2, '4': 3, '5': 9, '10': 'launchArgs'},
    {'1': 'target_stdin', '3': 3, '4': 1, '5': 9, '10': 'targetStdin'},
    {'1': 'target_stdout', '3': 4, '4': 1, '5': 9, '10': 'targetStdout'},
    {
      '1': 'process_env',
      '3': 5,
      '4': 3,
      '5': 11,
      '6': '.idb.XctraceRecordRequest.LauchProcess.ProcessEnvEntry',
      '10': 'processEnv'
    },
  ],
  '3': [XctraceRecordRequest_LauchProcess_ProcessEnvEntry$json],
};

@$core.Deprecated('Use xctraceRecordRequestDescriptor instead')
const XctraceRecordRequest_LauchProcess_ProcessEnvEntry$json = {
  '1': 'ProcessEnvEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use xctraceRecordRequestDescriptor instead')
const XctraceRecordRequest_Target$json = {
  '1': 'Target',
  '2': [
    {
      '1': 'all_processes',
      '3': 1,
      '4': 1,
      '5': 8,
      '9': 0,
      '10': 'allProcesses'
    },
    {
      '1': 'process_to_attach',
      '3': 2,
      '4': 1,
      '5': 9,
      '9': 0,
      '10': 'processToAttach'
    },
    {
      '1': 'launch_process',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.XctraceRecordRequest.LauchProcess',
      '9': 0,
      '10': 'launchProcess'
    },
  ],
  '8': [
    {'1': 'target'},
  ],
};

@$core.Deprecated('Use xctraceRecordRequestDescriptor instead')
const XctraceRecordRequest_Start$json = {
  '1': 'Start',
  '2': [
    {'1': 'template_name', '3': 1, '4': 1, '5': 9, '10': 'templateName'},
    {'1': 'time_limit', '3': 2, '4': 1, '5': 1, '10': 'timeLimit'},
    {'1': 'package', '3': 3, '4': 1, '5': 9, '10': 'package'},
    {
      '1': 'target',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.idb.XctraceRecordRequest.Target',
      '10': 'target'
    },
  ],
};

@$core.Deprecated('Use xctraceRecordRequestDescriptor instead')
const XctraceRecordRequest_Stop$json = {
  '1': 'Stop',
  '2': [
    {'1': 'timeout', '3': 1, '4': 1, '5': 1, '10': 'timeout'},
    {'1': 'args', '3': 2, '4': 3, '5': 9, '10': 'args'},
  ],
};

/// Descriptor for `XctraceRecordRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List xctraceRecordRequestDescriptor = $convert.base64Decode(
    'ChRYY3RyYWNlUmVjb3JkUmVxdWVzdBI3CgVzdGFydBgBIAEoCzIfLmlkYi5YY3RyYWNlUmVjb3'
    'JkUmVxdWVzdC5TdGFydEgAUgVzdGFydBI0CgRzdG9wGAIgASgLMh4uaWRiLlhjdHJhY2VSZWNv'
    'cmRSZXF1ZXN0LlN0b3BIAFIEc3RvcBq7AgoMTGF1Y2hQcm9jZXNzEioKEXByb2Nlc3NfdG9fbG'
    'F1bmNoGAEgASgJUg9wcm9jZXNzVG9MYXVuY2gSHwoLbGF1bmNoX2FyZ3MYAiADKAlSCmxhdW5j'
    'aEFyZ3MSIQoMdGFyZ2V0X3N0ZGluGAMgASgJUgt0YXJnZXRTdGRpbhIjCg10YXJnZXRfc3Rkb3'
    'V0GAQgASgJUgx0YXJnZXRTdGRvdXQSVwoLcHJvY2Vzc19lbnYYBSADKAsyNi5pZGIuWGN0cmFj'
    'ZVJlY29yZFJlcXVlc3QuTGF1Y2hQcm9jZXNzLlByb2Nlc3NFbnZFbnRyeVIKcHJvY2Vzc0Vudh'
    'o9Cg9Qcm9jZXNzRW52RW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAlSBXZh'
    'bHVlOgI4ARq4AQoGVGFyZ2V0EiUKDWFsbF9wcm9jZXNzZXMYASABKAhIAFIMYWxsUHJvY2Vzc2'
    'VzEiwKEXByb2Nlc3NfdG9fYXR0YWNoGAIgASgJSABSD3Byb2Nlc3NUb0F0dGFjaBJPCg5sYXVu'
    'Y2hfcHJvY2VzcxgDIAEoCzImLmlkYi5YY3RyYWNlUmVjb3JkUmVxdWVzdC5MYXVjaFByb2Nlc3'
    'NIAFINbGF1bmNoUHJvY2Vzc0IICgZ0YXJnZXQanwEKBVN0YXJ0EiMKDXRlbXBsYXRlX25hbWUY'
    'ASABKAlSDHRlbXBsYXRlTmFtZRIdCgp0aW1lX2xpbWl0GAIgASgBUgl0aW1lTGltaXQSGAoHcG'
    'Fja2FnZRgDIAEoCVIHcGFja2FnZRI4CgZ0YXJnZXQYBCABKAsyIC5pZGIuWGN0cmFjZVJlY29y'
    'ZFJlcXVlc3QuVGFyZ2V0UgZ0YXJnZXQaNAoEU3RvcBIYCgd0aW1lb3V0GAEgASgBUgd0aW1lb3'
    'V0EhIKBGFyZ3MYAiADKAlSBGFyZ3NCCQoHY29udHJvbA==');

@$core.Deprecated('Use xctraceRecordResponseDescriptor instead')
const XctraceRecordResponse$json = {
  '1': 'XctraceRecordResponse',
  '2': [
    {'1': 'log', '3': 1, '4': 1, '5': 12, '9': 0, '10': 'log'},
    {
      '1': 'payload',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '9': 0,
      '10': 'payload'
    },
    {
      '1': 'state',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.idb.XctraceRecordResponse.State',
      '9': 0,
      '10': 'state'
    },
  ],
  '4': [XctraceRecordResponse_State$json],
  '8': [
    {'1': 'output'},
  ],
};

@$core.Deprecated('Use xctraceRecordResponseDescriptor instead')
const XctraceRecordResponse_State$json = {
  '1': 'State',
  '2': [
    {'1': 'UNKNOWN', '2': 0},
    {'1': 'RUNNING', '2': 1},
    {'1': 'PROCESSING', '2': 2},
  ],
};

/// Descriptor for `XctraceRecordResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List xctraceRecordResponseDescriptor = $convert.base64Decode(
    'ChVYY3RyYWNlUmVjb3JkUmVzcG9uc2USEgoDbG9nGAEgASgMSABSA2xvZxIoCgdwYXlsb2FkGA'
    'IgASgLMgwuaWRiLlBheWxvYWRIAFIHcGF5bG9hZBI4CgVzdGF0ZRgDIAEoDjIgLmlkYi5YY3Ry'
    'YWNlUmVjb3JkUmVzcG9uc2UuU3RhdGVIAFIFc3RhdGUiMQoFU3RhdGUSCwoHVU5LTk9XThAAEg'
    'sKB1JVTk5JTkcQARIOCgpQUk9DRVNTSU5HEAJCCAoGb3V0cHV0');

@$core.Deprecated('Use debugServerRequestDescriptor instead')
const DebugServerRequest$json = {
  '1': 'DebugServerRequest',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.DebugServerRequest.Start',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'stop',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.DebugServerRequest.Stop',
      '9': 0,
      '10': 'stop'
    },
    {
      '1': 'status',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.DebugServerRequest.Status',
      '9': 0,
      '10': 'status'
    },
    {
      '1': 'pipe',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.idb.DebugServerRequest.Pipe',
      '9': 0,
      '10': 'pipe'
    },
  ],
  '3': [
    DebugServerRequest_Start$json,
    DebugServerRequest_Status$json,
    DebugServerRequest_Stop$json,
    DebugServerRequest_Pipe$json
  ],
  '8': [
    {'1': 'control'},
  ],
};

@$core.Deprecated('Use debugServerRequestDescriptor instead')
const DebugServerRequest_Start$json = {
  '1': 'Start',
  '2': [
    {'1': 'bundle_id', '3': 1, '4': 1, '5': 9, '10': 'bundleId'},
  ],
};

@$core.Deprecated('Use debugServerRequestDescriptor instead')
const DebugServerRequest_Status$json = {
  '1': 'Status',
};

@$core.Deprecated('Use debugServerRequestDescriptor instead')
const DebugServerRequest_Stop$json = {
  '1': 'Stop',
};

@$core.Deprecated('Use debugServerRequestDescriptor instead')
const DebugServerRequest_Pipe$json = {
  '1': 'Pipe',
  '2': [
    {'1': 'data', '3': 1, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `DebugServerRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List debugServerRequestDescriptor = $convert.base64Decode(
    'ChJEZWJ1Z1NlcnZlclJlcXVlc3QSNQoFc3RhcnQYASABKAsyHS5pZGIuRGVidWdTZXJ2ZXJSZX'
    'F1ZXN0LlN0YXJ0SABSBXN0YXJ0EjIKBHN0b3AYAiABKAsyHC5pZGIuRGVidWdTZXJ2ZXJSZXF1'
    'ZXN0LlN0b3BIAFIEc3RvcBI4CgZzdGF0dXMYAyABKAsyHi5pZGIuRGVidWdTZXJ2ZXJSZXF1ZX'
    'N0LlN0YXR1c0gAUgZzdGF0dXMSMgoEcGlwZRgEIAEoCzIcLmlkYi5EZWJ1Z1NlcnZlclJlcXVl'
    'c3QuUGlwZUgAUgRwaXBlGiQKBVN0YXJ0EhsKCWJ1bmRsZV9pZBgBIAEoCVIIYnVuZGxlSWQaCA'
    'oGU3RhdHVzGgYKBFN0b3AaGgoEUGlwZRISCgRkYXRhGAEgASgMUgRkYXRhQgkKB2NvbnRyb2w=');

@$core.Deprecated('Use debugServerResponseDescriptor instead')
const DebugServerResponse$json = {
  '1': 'DebugServerResponse',
  '2': [
    {
      '1': 'status',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.DebugServerResponse.Status',
      '9': 0,
      '10': 'status'
    },
    {
      '1': 'pipe',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.DebugServerResponse.Pipe',
      '9': 0,
      '10': 'pipe'
    },
  ],
  '3': [DebugServerResponse_Pipe$json, DebugServerResponse_Status$json],
  '8': [
    {'1': 'control'},
  ],
};

@$core.Deprecated('Use debugServerResponseDescriptor instead')
const DebugServerResponse_Pipe$json = {
  '1': 'Pipe',
  '2': [
    {'1': 'data', '3': 1, '4': 1, '5': 12, '10': 'data'},
  ],
};

@$core.Deprecated('Use debugServerResponseDescriptor instead')
const DebugServerResponse_Status$json = {
  '1': 'Status',
  '2': [
    {
      '1': 'lldb_bootstrap_commands',
      '3': 1,
      '4': 3,
      '5': 9,
      '10': 'lldbBootstrapCommands'
    },
  ],
};

/// Descriptor for `DebugServerResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List debugServerResponseDescriptor = $convert.base64Decode(
    'ChNEZWJ1Z1NlcnZlclJlc3BvbnNlEjkKBnN0YXR1cxgBIAEoCzIfLmlkYi5EZWJ1Z1NlcnZlcl'
    'Jlc3BvbnNlLlN0YXR1c0gAUgZzdGF0dXMSMwoEcGlwZRgCIAEoCzIdLmlkYi5EZWJ1Z1NlcnZl'
    'clJlc3BvbnNlLlBpcGVIAFIEcGlwZRoaCgRQaXBlEhIKBGRhdGEYASABKAxSBGRhdGEaQAoGU3'
    'RhdHVzEjYKF2xsZGJfYm9vdHN0cmFwX2NvbW1hbmRzGAEgAygJUhVsbGRiQm9vdHN0cmFwQ29t'
    'bWFuZHNCCQoHY29udHJvbA==');

@$core.Deprecated('Use crashShowRequestDescriptor instead')
const CrashShowRequest$json = {
  '1': 'CrashShowRequest',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
  ],
};

/// Descriptor for `CrashShowRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List crashShowRequestDescriptor = $convert
    .base64Decode('ChBDcmFzaFNob3dSZXF1ZXN0EhIKBG5hbWUYASABKAlSBG5hbWU=');

@$core.Deprecated('Use crashLogResponseDescriptor instead')
const CrashLogResponse$json = {
  '1': 'CrashLogResponse',
  '2': [
    {
      '1': 'list',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.idb.CrashLogInfo',
      '10': 'list'
    },
  ],
};

/// Descriptor for `CrashLogResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List crashLogResponseDescriptor = $convert.base64Decode(
    'ChBDcmFzaExvZ1Jlc3BvbnNlEiUKBGxpc3QYASADKAsyES5pZGIuQ3Jhc2hMb2dJbmZvUgRsaX'
    'N0');

@$core.Deprecated('Use crashLogInfoDescriptor instead')
const CrashLogInfo$json = {
  '1': 'CrashLogInfo',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'bundle_id', '3': 2, '4': 1, '5': 9, '10': 'bundleId'},
    {'1': 'process_name', '3': 3, '4': 1, '5': 9, '10': 'processName'},
    {
      '1': 'parent_process_name',
      '3': 4,
      '4': 1,
      '5': 9,
      '10': 'parentProcessName'
    },
    {
      '1': 'process_identifier',
      '3': 5,
      '4': 1,
      '5': 4,
      '10': 'processIdentifier'
    },
    {
      '1': 'parent_process_identifier',
      '3': 6,
      '4': 1,
      '5': 4,
      '10': 'parentProcessIdentifier'
    },
    {'1': 'timestamp', '3': 7, '4': 1, '5': 4, '10': 'timestamp'},
  ],
};

/// Descriptor for `CrashLogInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List crashLogInfoDescriptor = $convert.base64Decode(
    'CgxDcmFzaExvZ0luZm8SEgoEbmFtZRgBIAEoCVIEbmFtZRIbCglidW5kbGVfaWQYAiABKAlSCG'
    'J1bmRsZUlkEiEKDHByb2Nlc3NfbmFtZRgDIAEoCVILcHJvY2Vzc05hbWUSLgoTcGFyZW50X3By'
    'b2Nlc3NfbmFtZRgEIAEoCVIRcGFyZW50UHJvY2Vzc05hbWUSLQoScHJvY2Vzc19pZGVudGlmaW'
    'VyGAUgASgEUhFwcm9jZXNzSWRlbnRpZmllchI6ChlwYXJlbnRfcHJvY2Vzc19pZGVudGlmaWVy'
    'GAYgASgEUhdwYXJlbnRQcm9jZXNzSWRlbnRpZmllchIcCgl0aW1lc3RhbXAYByABKARSCXRpbW'
    'VzdGFtcA==');

@$core.Deprecated('Use crashShowResponseDescriptor instead')
const CrashShowResponse$json = {
  '1': 'CrashShowResponse',
  '2': [
    {
      '1': 'info',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.CrashLogInfo',
      '10': 'info'
    },
    {'1': 'contents', '3': 2, '4': 1, '5': 9, '10': 'contents'},
  ],
};

/// Descriptor for `CrashShowResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List crashShowResponseDescriptor = $convert.base64Decode(
    'ChFDcmFzaFNob3dSZXNwb25zZRIlCgRpbmZvGAEgASgLMhEuaWRiLkNyYXNoTG9nSW5mb1IEaW'
    '5mbxIaCghjb250ZW50cxgCIAEoCVIIY29udGVudHM=');

@$core.Deprecated('Use crashLogQueryDescriptor instead')
const CrashLogQuery$json = {
  '1': 'CrashLogQuery',
  '2': [
    {'1': 'since', '3': 1, '4': 1, '5': 4, '10': 'since'},
    {'1': 'before', '3': 2, '4': 1, '5': 4, '10': 'before'},
    {'1': 'bundle_id', '3': 3, '4': 1, '5': 9, '10': 'bundleId'},
    {'1': 'name', '3': 4, '4': 1, '5': 9, '10': 'name'},
  ],
};

/// Descriptor for `CrashLogQuery`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List crashLogQueryDescriptor = $convert.base64Decode(
    'Cg1DcmFzaExvZ1F1ZXJ5EhQKBXNpbmNlGAEgASgEUgVzaW5jZRIWCgZiZWZvcmUYAiABKARSBm'
    'JlZm9yZRIbCglidW5kbGVfaWQYAyABKAlSCGJ1bmRsZUlkEhIKBG5hbWUYBCABKAlSBG5hbWU=');

@$core.Deprecated('Use xctestListBundlesRequestDescriptor instead')
const XctestListBundlesRequest$json = {
  '1': 'XctestListBundlesRequest',
};

/// Descriptor for `XctestListBundlesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List xctestListBundlesRequestDescriptor =
    $convert.base64Decode('ChhYY3Rlc3RMaXN0QnVuZGxlc1JlcXVlc3Q=');

@$core.Deprecated('Use xctestListBundlesResponseDescriptor instead')
const XctestListBundlesResponse$json = {
  '1': 'XctestListBundlesResponse',
  '2': [
    {
      '1': 'bundles',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.idb.XctestListBundlesResponse.Bundles',
      '10': 'bundles'
    },
  ],
  '3': [XctestListBundlesResponse_Bundles$json],
};

@$core.Deprecated('Use xctestListBundlesResponseDescriptor instead')
const XctestListBundlesResponse_Bundles$json = {
  '1': 'Bundles',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'bundle_id', '3': 2, '4': 1, '5': 9, '10': 'bundleId'},
    {'1': 'architectures', '3': 3, '4': 3, '5': 9, '10': 'architectures'},
  ],
};

/// Descriptor for `XctestListBundlesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List xctestListBundlesResponseDescriptor = $convert.base64Decode(
    'ChlYY3Rlc3RMaXN0QnVuZGxlc1Jlc3BvbnNlEkAKB2J1bmRsZXMYASADKAsyJi5pZGIuWGN0ZX'
    'N0TGlzdEJ1bmRsZXNSZXNwb25zZS5CdW5kbGVzUgdidW5kbGVzGmAKB0J1bmRsZXMSEgoEbmFt'
    'ZRgBIAEoCVIEbmFtZRIbCglidW5kbGVfaWQYAiABKAlSCGJ1bmRsZUlkEiQKDWFyY2hpdGVjdH'
    'VyZXMYAyADKAlSDWFyY2hpdGVjdHVyZXM=');

@$core.Deprecated('Use xctestListTestsRequestDescriptor instead')
const XctestListTestsRequest$json = {
  '1': 'XctestListTestsRequest',
  '2': [
    {'1': 'bundle_name', '3': 1, '4': 1, '5': 9, '10': 'bundleName'},
    {'1': 'app_path', '3': 2, '4': 1, '5': 9, '10': 'appPath'},
  ],
};

/// Descriptor for `XctestListTestsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List xctestListTestsRequestDescriptor =
    $convert.base64Decode(
        'ChZYY3Rlc3RMaXN0VGVzdHNSZXF1ZXN0Eh8KC2J1bmRsZV9uYW1lGAEgASgJUgpidW5kbGVOYW'
        '1lEhkKCGFwcF9wYXRoGAIgASgJUgdhcHBQYXRo');

@$core.Deprecated('Use xctestListTestsResponseDescriptor instead')
const XctestListTestsResponse$json = {
  '1': 'XctestListTestsResponse',
  '2': [
    {'1': 'names', '3': 1, '4': 3, '5': 9, '10': 'names'},
  ],
};

/// Descriptor for `XctestListTestsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List xctestListTestsResponseDescriptor =
    $convert.base64Decode(
        'ChdYY3Rlc3RMaXN0VGVzdHNSZXNwb25zZRIUCgVuYW1lcxgBIAMoCVIFbmFtZXM=');

@$core.Deprecated('Use xctestRunRequestDescriptor instead')
const XctestRunRequest$json = {
  '1': 'XctestRunRequest',
  '2': [
    {
      '1': 'mode',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.XctestRunRequest.Mode',
      '10': 'mode'
    },
    {'1': 'test_bundle_id', '3': 2, '4': 1, '5': 9, '10': 'testBundleId'},
    {'1': 'tests_to_run', '3': 3, '4': 3, '5': 9, '10': 'testsToRun'},
    {'1': 'tests_to_skip', '3': 4, '4': 3, '5': 9, '10': 'testsToSkip'},
    {'1': 'arguments', '3': 5, '4': 3, '5': 9, '10': 'arguments'},
    {
      '1': 'environment',
      '3': 6,
      '4': 3,
      '5': 11,
      '6': '.idb.XctestRunRequest.EnvironmentEntry',
      '10': 'environment'
    },
    {'1': 'timeout', '3': 7, '4': 1, '5': 4, '10': 'timeout'},
    {
      '1': 'report_activities',
      '3': 8,
      '4': 1,
      '5': 8,
      '10': 'reportActivities'
    },
    {'1': 'collect_coverage', '3': 9, '4': 1, '5': 8, '10': 'collectCoverage'},
    {
      '1': 'report_attachments',
      '3': 10,
      '4': 1,
      '5': 8,
      '10': 'reportAttachments'
    },
    {'1': 'collect_logs', '3': 11, '4': 1, '5': 8, '10': 'collectLogs'},
    {
      '1': 'wait_for_debugger',
      '3': 12,
      '4': 1,
      '5': 8,
      '10': 'waitForDebugger'
    },
    {
      '1': 'code_coverage',
      '3': 13,
      '4': 1,
      '5': 11,
      '6': '.idb.XctestRunRequest.CodeCoverage',
      '10': 'codeCoverage'
    },
    {
      '1': 'collect_result_bundle',
      '3': 14,
      '4': 1,
      '5': 8,
      '10': 'collectResultBundle'
    },
  ],
  '3': [
    XctestRunRequest_Logic$json,
    XctestRunRequest_Application$json,
    XctestRunRequest_UI$json,
    XctestRunRequest_Mode$json,
    XctestRunRequest_CodeCoverage$json,
    XctestRunRequest_EnvironmentEntry$json
  ],
};

@$core.Deprecated('Use xctestRunRequestDescriptor instead')
const XctestRunRequest_Logic$json = {
  '1': 'Logic',
};

@$core.Deprecated('Use xctestRunRequestDescriptor instead')
const XctestRunRequest_Application$json = {
  '1': 'Application',
  '2': [
    {'1': 'app_bundle_id', '3': 1, '4': 1, '5': 9, '10': 'appBundleId'},
  ],
};

@$core.Deprecated('Use xctestRunRequestDescriptor instead')
const XctestRunRequest_UI$json = {
  '1': 'UI',
  '2': [
    {'1': 'app_bundle_id', '3': 1, '4': 1, '5': 9, '10': 'appBundleId'},
    {
      '1': 'test_host_app_bundle_id',
      '3': 2,
      '4': 1,
      '5': 9,
      '10': 'testHostAppBundleId'
    },
  ],
};

@$core.Deprecated('Use xctestRunRequestDescriptor instead')
const XctestRunRequest_Mode$json = {
  '1': 'Mode',
  '2': [
    {
      '1': 'logic',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.XctestRunRequest.Logic',
      '9': 0,
      '10': 'logic'
    },
    {
      '1': 'application',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.XctestRunRequest.Application',
      '9': 0,
      '10': 'application'
    },
    {
      '1': 'ui',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.XctestRunRequest.UI',
      '9': 0,
      '10': 'ui'
    },
  ],
  '8': [
    {'1': 'mode'},
  ],
};

@$core.Deprecated('Use xctestRunRequestDescriptor instead')
const XctestRunRequest_CodeCoverage$json = {
  '1': 'CodeCoverage',
  '2': [
    {'1': 'collect', '3': 1, '4': 1, '5': 8, '10': 'collect'},
    {
      '1': 'format',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.idb.XctestRunRequest.CodeCoverage.Format',
      '10': 'format'
    },
    {
      '1': 'enable_continuous_coverage_collection',
      '3': 3,
      '4': 1,
      '5': 8,
      '10': 'enableContinuousCoverageCollection'
    },
  ],
  '4': [XctestRunRequest_CodeCoverage_Format$json],
};

@$core.Deprecated('Use xctestRunRequestDescriptor instead')
const XctestRunRequest_CodeCoverage_Format$json = {
  '1': 'Format',
  '2': [
    {'1': 'EXPORTED', '2': 0},
    {'1': 'RAW', '2': 1},
  ],
};

@$core.Deprecated('Use xctestRunRequestDescriptor instead')
const XctestRunRequest_EnvironmentEntry$json = {
  '1': 'EnvironmentEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `XctestRunRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List xctestRunRequestDescriptor = $convert.base64Decode(
    'ChBYY3Rlc3RSdW5SZXF1ZXN0Ei4KBG1vZGUYASABKAsyGi5pZGIuWGN0ZXN0UnVuUmVxdWVzdC'
    '5Nb2RlUgRtb2RlEiQKDnRlc3RfYnVuZGxlX2lkGAIgASgJUgx0ZXN0QnVuZGxlSWQSIAoMdGVz'
    'dHNfdG9fcnVuGAMgAygJUgp0ZXN0c1RvUnVuEiIKDXRlc3RzX3RvX3NraXAYBCADKAlSC3Rlc3'
    'RzVG9Ta2lwEhwKCWFyZ3VtZW50cxgFIAMoCVIJYXJndW1lbnRzEkgKC2Vudmlyb25tZW50GAYg'
    'AygLMiYuaWRiLlhjdGVzdFJ1blJlcXVlc3QuRW52aXJvbm1lbnRFbnRyeVILZW52aXJvbm1lbn'
    'QSGAoHdGltZW91dBgHIAEoBFIHdGltZW91dBIrChFyZXBvcnRfYWN0aXZpdGllcxgIIAEoCFIQ'
    'cmVwb3J0QWN0aXZpdGllcxIpChBjb2xsZWN0X2NvdmVyYWdlGAkgASgIUg9jb2xsZWN0Q292ZX'
    'JhZ2USLQoScmVwb3J0X2F0dGFjaG1lbnRzGAogASgIUhFyZXBvcnRBdHRhY2htZW50cxIhCgxj'
    'b2xsZWN0X2xvZ3MYCyABKAhSC2NvbGxlY3RMb2dzEioKEXdhaXRfZm9yX2RlYnVnZ2VyGAwgAS'
    'gIUg93YWl0Rm9yRGVidWdnZXISRwoNY29kZV9jb3ZlcmFnZRgNIAEoCzIiLmlkYi5YY3Rlc3RS'
    'dW5SZXF1ZXN0LkNvZGVDb3ZlcmFnZVIMY29kZUNvdmVyYWdlEjIKFWNvbGxlY3RfcmVzdWx0X2'
    'J1bmRsZRgOIAEoCFITY29sbGVjdFJlc3VsdEJ1bmRsZRoHCgVMb2dpYxoxCgtBcHBsaWNhdGlv'
    'bhIiCg1hcHBfYnVuZGxlX2lkGAEgASgJUgthcHBCdW5kbGVJZBpeCgJVSRIiCg1hcHBfYnVuZG'
    'xlX2lkGAEgASgJUgthcHBCdW5kbGVJZBI0Chd0ZXN0X2hvc3RfYXBwX2J1bmRsZV9pZBgCIAEo'
    'CVITdGVzdEhvc3RBcHBCdW5kbGVJZBq2AQoETW9kZRIzCgVsb2dpYxgBIAEoCzIbLmlkYi5YY3'
    'Rlc3RSdW5SZXF1ZXN0LkxvZ2ljSABSBWxvZ2ljEkUKC2FwcGxpY2F0aW9uGAIgASgLMiEuaWRi'
    'LlhjdGVzdFJ1blJlcXVlc3QuQXBwbGljYXRpb25IAFILYXBwbGljYXRpb24SKgoCdWkYAyABKA'
    'syGC5pZGIuWGN0ZXN0UnVuUmVxdWVzdC5VSUgAUgJ1aUIGCgRtb2RlGt8BCgxDb2RlQ292ZXJh'
    'Z2USGAoHY29sbGVjdBgBIAEoCFIHY29sbGVjdBJBCgZmb3JtYXQYAiABKA4yKS5pZGIuWGN0ZX'
    'N0UnVuUmVxdWVzdC5Db2RlQ292ZXJhZ2UuRm9ybWF0UgZmb3JtYXQSUQolZW5hYmxlX2NvbnRp'
    'bnVvdXNfY292ZXJhZ2VfY29sbGVjdGlvbhgDIAEoCFIiZW5hYmxlQ29udGludW91c0NvdmVyYW'
    'dlQ29sbGVjdGlvbiIfCgZGb3JtYXQSDAoIRVhQT1JURUQQABIHCgNSQVcQARo+ChBFbnZpcm9u'
    'bWVudEVudHJ5EhAKA2tleRgBIAEoCVIDa2V5EhQKBXZhbHVlGAIgASgJUgV2YWx1ZToCOAE=');

@$core.Deprecated('Use xctestRunResponseDescriptor instead')
const XctestRunResponse$json = {
  '1': 'XctestRunResponse',
  '2': [
    {
      '1': 'status',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.XctestRunResponse.Status',
      '10': 'status'
    },
    {
      '1': 'results',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.idb.XctestRunResponse.TestRunInfo',
      '10': 'results'
    },
    {'1': 'log_output', '3': 3, '4': 3, '5': 9, '10': 'logOutput'},
    {
      '1': 'result_bundle',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '10': 'resultBundle'
    },
    {'1': 'coverage_json', '3': 5, '4': 1, '5': 9, '10': 'coverageJson'},
    {
      '1': 'log_directory',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '10': 'logDirectory'
    },
    {
      '1': 'debugger',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.idb.DebuggerInfo',
      '10': 'debugger'
    },
    {
      '1': 'code_coverage_data',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '10': 'codeCoverageData'
    },
  ],
  '3': [XctestRunResponse_TestRunInfo$json],
  '4': [XctestRunResponse_Status$json],
};

@$core.Deprecated('Use xctestRunResponseDescriptor instead')
const XctestRunResponse_TestRunInfo$json = {
  '1': 'TestRunInfo',
  '2': [
    {
      '1': 'status',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.XctestRunResponse.TestRunInfo.Status',
      '10': 'status'
    },
    {'1': 'bundle_name', '3': 2, '4': 1, '5': 9, '10': 'bundleName'},
    {'1': 'class_name', '3': 3, '4': 1, '5': 9, '10': 'className'},
    {'1': 'method_name', '3': 4, '4': 1, '5': 9, '10': 'methodName'},
    {'1': 'duration', '3': 5, '4': 1, '5': 1, '10': 'duration'},
    {
      '1': 'failure_info',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.idb.XctestRunResponse.TestRunInfo.TestRunFailureInfo',
      '10': 'failureInfo'
    },
    {'1': 'logs', '3': 7, '4': 3, '5': 9, '10': 'logs'},
    {
      '1': 'activityLogs',
      '3': 8,
      '4': 3,
      '5': 11,
      '6': '.idb.XctestRunResponse.TestRunInfo.TestActivity',
      '10': 'activityLogs'
    },
    {
      '1': 'other_failures',
      '3': 9,
      '4': 3,
      '5': 11,
      '6': '.idb.XctestRunResponse.TestRunInfo.TestRunFailureInfo',
      '10': 'otherFailures'
    },
  ],
  '3': [
    XctestRunResponse_TestRunInfo_TestRunFailureInfo$json,
    XctestRunResponse_TestRunInfo_TestAttachment$json,
    XctestRunResponse_TestRunInfo_TestActivity$json
  ],
  '4': [XctestRunResponse_TestRunInfo_Status$json],
};

@$core.Deprecated('Use xctestRunResponseDescriptor instead')
const XctestRunResponse_TestRunInfo_TestRunFailureInfo$json = {
  '1': 'TestRunFailureInfo',
  '2': [
    {'1': 'failure_message', '3': 1, '4': 1, '5': 9, '10': 'failureMessage'},
    {'1': 'file', '3': 2, '4': 1, '5': 9, '10': 'file'},
    {'1': 'line', '3': 3, '4': 1, '5': 4, '10': 'line'},
  ],
};

@$core.Deprecated('Use xctestRunResponseDescriptor instead')
const XctestRunResponse_TestRunInfo_TestAttachment$json = {
  '1': 'TestAttachment',
  '2': [
    {'1': 'payload', '3': 1, '4': 1, '5': 12, '10': 'payload'},
    {'1': 'timestamp', '3': 2, '4': 1, '5': 1, '10': 'timestamp'},
    {'1': 'name', '3': 3, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'uniform_type_identifier',
      '3': 4,
      '4': 1,
      '5': 9,
      '10': 'uniformTypeIdentifier'
    },
    {'1': 'user_info_json', '3': 5, '4': 1, '5': 12, '10': 'userInfoJson'},
  ],
};

@$core.Deprecated('Use xctestRunResponseDescriptor instead')
const XctestRunResponse_TestRunInfo_TestActivity$json = {
  '1': 'TestActivity',
  '2': [
    {'1': 'title', '3': 1, '4': 1, '5': 9, '10': 'title'},
    {'1': 'duration', '3': 2, '4': 1, '5': 1, '10': 'duration'},
    {'1': 'uuid', '3': 3, '4': 1, '5': 9, '10': 'uuid'},
    {'1': 'activity_type', '3': 4, '4': 1, '5': 9, '10': 'activityType'},
    {'1': 'start', '3': 5, '4': 1, '5': 1, '10': 'start'},
    {'1': 'finish', '3': 6, '4': 1, '5': 1, '10': 'finish'},
    {'1': 'name', '3': 7, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'attachments',
      '3': 8,
      '4': 3,
      '5': 11,
      '6': '.idb.XctestRunResponse.TestRunInfo.TestAttachment',
      '10': 'attachments'
    },
    {
      '1': 'sub_activities',
      '3': 9,
      '4': 3,
      '5': 11,
      '6': '.idb.XctestRunResponse.TestRunInfo.TestActivity',
      '10': 'subActivities'
    },
  ],
};

@$core.Deprecated('Use xctestRunResponseDescriptor instead')
const XctestRunResponse_TestRunInfo_Status$json = {
  '1': 'Status',
  '2': [
    {'1': 'PASSED', '2': 0},
    {'1': 'FAILED', '2': 1},
    {'1': 'CRASHED', '2': 2},
  ],
};

@$core.Deprecated('Use xctestRunResponseDescriptor instead')
const XctestRunResponse_Status$json = {
  '1': 'Status',
  '2': [
    {'1': 'RUNNING', '2': 0},
    {'1': 'TERMINATED_NORMALLY', '2': 1},
    {'1': 'TERMINATED_ABNORMALLY', '2': 2},
  ],
};

/// Descriptor for `XctestRunResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List xctestRunResponseDescriptor = $convert.base64Decode(
    'ChFYY3Rlc3RSdW5SZXNwb25zZRI1CgZzdGF0dXMYASABKA4yHS5pZGIuWGN0ZXN0UnVuUmVzcG'
    '9uc2UuU3RhdHVzUgZzdGF0dXMSPAoHcmVzdWx0cxgCIAMoCzIiLmlkYi5YY3Rlc3RSdW5SZXNw'
    'b25zZS5UZXN0UnVuSW5mb1IHcmVzdWx0cxIdCgpsb2dfb3V0cHV0GAMgAygJUglsb2dPdXRwdX'
    'QSMQoNcmVzdWx0X2J1bmRsZRgEIAEoCzIMLmlkYi5QYXlsb2FkUgxyZXN1bHRCdW5kbGUSIwoN'
    'Y292ZXJhZ2VfanNvbhgFIAEoCVIMY292ZXJhZ2VKc29uEjEKDWxvZ19kaXJlY3RvcnkYBiABKA'
    'syDC5pZGIuUGF5bG9hZFIMbG9nRGlyZWN0b3J5Ei0KCGRlYnVnZ2VyGAcgASgLMhEuaWRiLkRl'
    'YnVnZ2VySW5mb1IIZGVidWdnZXISOgoSY29kZV9jb3ZlcmFnZV9kYXRhGAggASgLMgwuaWRiLl'
    'BheWxvYWRSEGNvZGVDb3ZlcmFnZURhdGEarAkKC1Rlc3RSdW5JbmZvEkEKBnN0YXR1cxgBIAEo'
    'DjIpLmlkYi5YY3Rlc3RSdW5SZXNwb25zZS5UZXN0UnVuSW5mby5TdGF0dXNSBnN0YXR1cxIfCg'
    'tidW5kbGVfbmFtZRgCIAEoCVIKYnVuZGxlTmFtZRIdCgpjbGFzc19uYW1lGAMgASgJUgljbGFz'
    'c05hbWUSHwoLbWV0aG9kX25hbWUYBCABKAlSCm1ldGhvZE5hbWUSGgoIZHVyYXRpb24YBSABKA'
    'FSCGR1cmF0aW9uElgKDGZhaWx1cmVfaW5mbxgGIAEoCzI1LmlkYi5YY3Rlc3RSdW5SZXNwb25z'
    'ZS5UZXN0UnVuSW5mby5UZXN0UnVuRmFpbHVyZUluZm9SC2ZhaWx1cmVJbmZvEhIKBGxvZ3MYBy'
    'ADKAlSBGxvZ3MSUwoMYWN0aXZpdHlMb2dzGAggAygLMi8uaWRiLlhjdGVzdFJ1blJlc3BvbnNl'
    'LlRlc3RSdW5JbmZvLlRlc3RBY3Rpdml0eVIMYWN0aXZpdHlMb2dzElwKDm90aGVyX2ZhaWx1cm'
    'VzGAkgAygLMjUuaWRiLlhjdGVzdFJ1blJlc3BvbnNlLlRlc3RSdW5JbmZvLlRlc3RSdW5GYWls'
    'dXJlSW5mb1INb3RoZXJGYWlsdXJlcxplChJUZXN0UnVuRmFpbHVyZUluZm8SJwoPZmFpbHVyZV'
    '9tZXNzYWdlGAEgASgJUg5mYWlsdXJlTWVzc2FnZRISCgRmaWxlGAIgASgJUgRmaWxlEhIKBGxp'
    'bmUYAyABKARSBGxpbmUaugEKDlRlc3RBdHRhY2htZW50EhgKB3BheWxvYWQYASABKAxSB3BheW'
    'xvYWQSHAoJdGltZXN0YW1wGAIgASgBUgl0aW1lc3RhbXASEgoEbmFtZRgDIAEoCVIEbmFtZRI2'
    'Chd1bmlmb3JtX3R5cGVfaWRlbnRpZmllchgEIAEoCVIVdW5pZm9ybVR5cGVJZGVudGlmaWVyEi'
    'QKDnVzZXJfaW5mb19qc29uGAUgASgMUgx1c2VySW5mb0pzb24a6AIKDFRlc3RBY3Rpdml0eRIU'
    'CgV0aXRsZRgBIAEoCVIFdGl0bGUSGgoIZHVyYXRpb24YAiABKAFSCGR1cmF0aW9uEhIKBHV1aW'
    'QYAyABKAlSBHV1aWQSIwoNYWN0aXZpdHlfdHlwZRgEIAEoCVIMYWN0aXZpdHlUeXBlEhQKBXN0'
    'YXJ0GAUgASgBUgVzdGFydBIWCgZmaW5pc2gYBiABKAFSBmZpbmlzaBISCgRuYW1lGAcgASgJUg'
    'RuYW1lElMKC2F0dGFjaG1lbnRzGAggAygLMjEuaWRiLlhjdGVzdFJ1blJlc3BvbnNlLlRlc3RS'
    'dW5JbmZvLlRlc3RBdHRhY2htZW50UgthdHRhY2htZW50cxJWCg5zdWJfYWN0aXZpdGllcxgJIA'
    'MoCzIvLmlkYi5YY3Rlc3RSdW5SZXNwb25zZS5UZXN0UnVuSW5mby5UZXN0QWN0aXZpdHlSDXN1'
    'YkFjdGl2aXRpZXMiLQoGU3RhdHVzEgoKBlBBU1NFRBAAEgoKBkZBSUxFRBABEgsKB0NSQVNIRU'
    'QQAiJJCgZTdGF0dXMSCwoHUlVOTklORxAAEhcKE1RFUk1JTkFURURfTk9STUFMTFkQARIZChVU'
    'RVJNSU5BVEVEX0FCTk9STUFMTFkQAg==');

@$core.Deprecated('Use replRequestDescriptor instead')
const ReplRequest$json = {
  '1': 'ReplRequest',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.ReplRequest.Start',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'execute',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.ReplRequest.Execute',
      '9': 0,
      '10': 'execute'
    },
    {
      '1': 'stop',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.ReplRequest.Stop',
      '9': 0,
      '10': 'stop'
    },
  ],
  '3': [
    ReplRequest_Start$json,
    ReplRequest_Execute$json,
    ReplRequest_Stop$json
  ],
  '8': [
    {'1': 'control'},
  ],
};

@$core.Deprecated('Use replRequestDescriptor instead')
const ReplRequest_Start$json = {
  '1': 'Start',
  '2': [
    {'1': 'test_bundle_path', '3': 1, '4': 1, '5': 9, '10': 'testBundlePath'},
    {
      '1': 'context',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.idb.ReplRequest.Start.Context',
      '10': 'context'
    },
    {'1': 'app_bundle_id', '3': 3, '4': 1, '5': 9, '10': 'appBundleId'},
    {'1': 'reuse_session', '3': 4, '4': 1, '5': 8, '10': 'reuseSession'},
    {'1': 'probe_file_path', '3': 5, '4': 1, '5': 9, '10': 'probeFilePath'},
  ],
  '4': [ReplRequest_Start_Context$json],
};

@$core.Deprecated('Use replRequestDescriptor instead')
const ReplRequest_Start_Context$json = {
  '1': 'Context',
  '2': [
    {'1': 'SIMULATOR', '2': 0},
    {'1': 'TEST', '2': 1},
    {'1': 'APP', '2': 2},
  ],
};

@$core.Deprecated('Use replRequestDescriptor instead')
const ReplRequest_Execute$json = {
  '1': 'Execute',
  '2': [
    {'1': 'dylib', '3': 1, '4': 1, '5': 12, '10': 'dylib'},
    {'1': 'symbol', '3': 2, '4': 1, '5': 9, '10': 'symbol'},
  ],
};

@$core.Deprecated('Use replRequestDescriptor instead')
const ReplRequest_Stop$json = {
  '1': 'Stop',
};

/// Descriptor for `ReplRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List replRequestDescriptor = $convert.base64Decode(
    'CgtSZXBsUmVxdWVzdBIuCgVzdGFydBgBIAEoCzIWLmlkYi5SZXBsUmVxdWVzdC5TdGFydEgAUg'
    'VzdGFydBI0CgdleGVjdXRlGAIgASgLMhguaWRiLlJlcGxSZXF1ZXN0LkV4ZWN1dGVIAFIHZXhl'
    'Y3V0ZRIrCgRzdG9wGAMgASgLMhUuaWRiLlJlcGxSZXF1ZXN0LlN0b3BIAFIEc3RvcBqJAgoFU3'
    'RhcnQSKAoQdGVzdF9idW5kbGVfcGF0aBgBIAEoCVIOdGVzdEJ1bmRsZVBhdGgSOAoHY29udGV4'
    'dBgCIAEoDjIeLmlkYi5SZXBsUmVxdWVzdC5TdGFydC5Db250ZXh0Ugdjb250ZXh0EiIKDWFwcF'
    '9idW5kbGVfaWQYAyABKAlSC2FwcEJ1bmRsZUlkEiMKDXJldXNlX3Nlc3Npb24YBCABKAhSDHJl'
    'dXNlU2Vzc2lvbhImCg9wcm9iZV9maWxlX3BhdGgYBSABKAlSDXByb2JlRmlsZVBhdGgiKwoHQ2'
    '9udGV4dBINCglTSU1VTEFUT1IQABIICgRURVNUEAESBwoDQVBQEAIaNwoHRXhlY3V0ZRIUCgVk'
    'eWxpYhgBIAEoDFIFZHlsaWISFgoGc3ltYm9sGAIgASgJUgZzeW1ib2waBgoEU3RvcEIJCgdjb2'
    '50cm9s');

@$core.Deprecated('Use replResponseDescriptor instead')
const ReplResponse$json = {
  '1': 'ReplResponse',
  '2': [
    {
      '1': 'ready',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.ReplResponse.Ready',
      '9': 0,
      '10': 'ready'
    },
    {
      '1': 'result',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.ReplResponse.Result',
      '9': 0,
      '10': 'result'
    },
    {
      '1': 'stopped',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.ReplResponse.Stopped',
      '9': 0,
      '10': 'stopped'
    },
  ],
  '3': [
    ReplResponse_Ready$json,
    ReplResponse_Result$json,
    ReplResponse_Stopped$json
  ],
  '8': [
    {'1': 'event'},
  ],
};

@$core.Deprecated('Use replResponseDescriptor instead')
const ReplResponse_Ready$json = {
  '1': 'Ready',
  '2': [
    {'1': 'device_type', '3': 1, '4': 1, '5': 9, '10': 'deviceType'},
    {
      '1': 'generated_interfaces',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.idb.ReplResponse.Ready.GeneratedInterface',
      '10': 'generatedInterfaces'
    },
    {'1': 'os_version', '3': 4, '4': 1, '5': 9, '10': 'osVersion'},
    {'1': 'next_run_index', '3': 5, '4': 1, '5': 13, '10': 'nextRunIndex'},
    {
      '1': 'shared_filesystem',
      '3': 6,
      '4': 1,
      '5': 8,
      '10': 'sharedFilesystem'
    },
    {'1': 'session_id', '3': 7, '4': 1, '5': 9, '10': 'sessionId'},
  ],
  '3': [ReplResponse_Ready_GeneratedInterface$json],
};

@$core.Deprecated('Use replResponseDescriptor instead')
const ReplResponse_Ready_GeneratedInterface$json = {
  '1': 'GeneratedInterface',
  '2': [
    {'1': 'module_name', '3': 1, '4': 1, '5': 9, '10': 'moduleName'},
    {'1': 'contents', '3': 2, '4': 1, '5': 9, '10': 'contents'},
  ],
};

@$core.Deprecated('Use replResponseDescriptor instead')
const ReplResponse_Result$json = {
  '1': 'Result',
  '2': [
    {'1': 'success', '3': 1, '4': 1, '5': 8, '10': 'success'},
    {'1': 'output', '3': 2, '4': 1, '5': 9, '10': 'output'},
    {'1': 'next_run_index', '3': 3, '4': 1, '5': 5, '10': 'nextRunIndex'},
    {
      '1': 'artifacts',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.idb.ReplResponse.Result.Artifact',
      '10': 'artifacts'
    },
  ],
  '3': [ReplResponse_Result_Artifact$json],
};

@$core.Deprecated('Use replResponseDescriptor instead')
const ReplResponse_Result_Artifact$json = {
  '1': 'Artifact',
  '2': [
    {'1': 'host_path', '3': 1, '4': 1, '5': 9, '10': 'hostPath'},
    {'1': 'container_path', '3': 2, '4': 1, '5': 9, '10': 'containerPath'},
  ],
};

@$core.Deprecated('Use replResponseDescriptor instead')
const ReplResponse_Stopped$json = {
  '1': 'Stopped',
  '2': [
    {'1': 'desc', '3': 1, '4': 1, '5': 9, '10': 'desc'},
  ],
};

/// Descriptor for `ReplResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List replResponseDescriptor = $convert.base64Decode(
    'CgxSZXBsUmVzcG9uc2USLwoFcmVhZHkYASABKAsyFy5pZGIuUmVwbFJlc3BvbnNlLlJlYWR5SA'
    'BSBXJlYWR5EjIKBnJlc3VsdBgCIAEoCzIYLmlkYi5SZXBsUmVzcG9uc2UuUmVzdWx0SABSBnJl'
    'c3VsdBI1CgdzdG9wcGVkGAMgASgLMhkuaWRiLlJlcGxSZXNwb25zZS5TdG9wcGVkSABSB3N0b3'
    'BwZWQa6wIKBVJlYWR5Eh8KC2RldmljZV90eXBlGAEgASgJUgpkZXZpY2VUeXBlEl0KFGdlbmVy'
    'YXRlZF9pbnRlcmZhY2VzGAIgAygLMiouaWRiLlJlcGxSZXNwb25zZS5SZWFkeS5HZW5lcmF0ZW'
    'RJbnRlcmZhY2VSE2dlbmVyYXRlZEludGVyZmFjZXMSHQoKb3NfdmVyc2lvbhgEIAEoCVIJb3NW'
    'ZXJzaW9uEiQKDm5leHRfcnVuX2luZGV4GAUgASgNUgxuZXh0UnVuSW5kZXgSKwoRc2hhcmVkX2'
    'ZpbGVzeXN0ZW0YBiABKAhSEHNoYXJlZEZpbGVzeXN0ZW0SHQoKc2Vzc2lvbl9pZBgHIAEoCVIJ'
    'c2Vzc2lvbklkGlEKEkdlbmVyYXRlZEludGVyZmFjZRIfCgttb2R1bGVfbmFtZRgBIAEoCVIKbW'
    '9kdWxlTmFtZRIaCghjb250ZW50cxgCIAEoCVIIY29udGVudHMa8QEKBlJlc3VsdBIYCgdzdWNj'
    'ZXNzGAEgASgIUgdzdWNjZXNzEhYKBm91dHB1dBgCIAEoCVIGb3V0cHV0EiQKDm5leHRfcnVuX2'
    'luZGV4GAMgASgFUgxuZXh0UnVuSW5kZXgSPwoJYXJ0aWZhY3RzGAQgAygLMiEuaWRiLlJlcGxS'
    'ZXNwb25zZS5SZXN1bHQuQXJ0aWZhY3RSCWFydGlmYWN0cxpOCghBcnRpZmFjdBIbCglob3N0X3'
    'BhdGgYASABKAlSCGhvc3RQYXRoEiUKDmNvbnRhaW5lcl9wYXRoGAIgASgJUg1jb250YWluZXJQ'
    'YXRoGh0KB1N0b3BwZWQSEgoEZGVzYxgBIAEoCVIEZGVzY0IHCgVldmVudA==');

@$core.Deprecated('Use fileContainerDescriptor instead')
const FileContainer$json = {
  '1': 'FileContainer',
  '2': [
    {
      '1': 'kind',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.idb.FileContainer.Kind',
      '10': 'kind'
    },
    {'1': 'bundle_id', '3': 2, '4': 1, '5': 9, '10': 'bundleId'},
  ],
  '4': [FileContainer_Kind$json],
};

@$core.Deprecated('Use fileContainerDescriptor instead')
const FileContainer_Kind$json = {
  '1': 'Kind',
  '2': [
    {'1': 'NONE', '2': 0},
    {'1': 'APPLICATION', '2': 1},
    {'1': 'ROOT', '2': 2},
    {'1': 'MEDIA', '2': 3},
    {'1': 'CRASHES', '2': 4},
    {'1': 'PROVISIONING_PROFILES', '2': 5},
    {'1': 'MDM_PROFILES', '2': 6},
    {'1': 'SPRINGBOARD_ICONS', '2': 7},
    {'1': 'WALLPAPER', '2': 8},
    {'1': 'DISK_IMAGES', '2': 9},
    {'1': 'GROUP_CONTAINER', '2': 10},
    {'1': 'APPLICATION_CONTAINER', '2': 11},
    {'1': 'AUXILLARY', '2': 12},
    {'1': 'XCTEST', '2': 13},
    {'1': 'DYLIB', '2': 14},
    {'1': 'DSYM', '2': 15},
    {'1': 'FRAMEWORK', '2': 16},
    {'1': 'SYMBOLS', '2': 17},
  ],
};

/// Descriptor for `FileContainer`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fileContainerDescriptor = $convert.base64Decode(
    'Cg1GaWxlQ29udGFpbmVyEisKBGtpbmQYASABKA4yFy5pZGIuRmlsZUNvbnRhaW5lci5LaW5kUg'
    'RraW5kEhsKCWJ1bmRsZV9pZBgCIAEoCVIIYnVuZGxlSWQiowIKBEtpbmQSCAoETk9ORRAAEg8K'
    'C0FQUExJQ0FUSU9OEAESCAoEUk9PVBACEgkKBU1FRElBEAMSCwoHQ1JBU0hFUxAEEhkKFVBST1'
    'ZJU0lPTklOR19QUk9GSUxFUxAFEhAKDE1ETV9QUk9GSUxFUxAGEhUKEVNQUklOR0JPQVJEX0lD'
    'T05TEAcSDQoJV0FMTFBBUEVSEAgSDwoLRElTS19JTUFHRVMQCRITCg9HUk9VUF9DT05UQUlORV'
    'IQChIZChVBUFBMSUNBVElPTl9DT05UQUlORVIQCxINCglBVVhJTExBUlkQDBIKCgZYQ1RFU1QQ'
    'DRIJCgVEWUxJQhAOEggKBERTWU0QDxINCglGUkFNRVdPUksQEBILCgdTWU1CT0xTEBE=');

@$core.Deprecated('Use fileInfoDescriptor instead')
const FileInfo$json = {
  '1': 'FileInfo',
  '2': [
    {'1': 'path', '3': 1, '4': 1, '5': 9, '10': 'path'},
  ],
};

/// Descriptor for `FileInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fileInfoDescriptor =
    $convert.base64Decode('CghGaWxlSW5mbxISCgRwYXRoGAEgASgJUgRwYXRo');

@$core.Deprecated('Use fileListingDescriptor instead')
const FileListing$json = {
  '1': 'FileListing',
  '2': [
    {
      '1': 'parent',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.FileInfo',
      '10': 'parent'
    },
    {
      '1': 'files',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.idb.FileInfo',
      '10': 'files'
    },
  ],
};

/// Descriptor for `FileListing`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fileListingDescriptor = $convert.base64Decode(
    'CgtGaWxlTGlzdGluZxIlCgZwYXJlbnQYASABKAsyDS5pZGIuRmlsZUluZm9SBnBhcmVudBIjCg'
    'VmaWxlcxgCIAMoCzINLmlkYi5GaWxlSW5mb1IFZmlsZXM=');

@$core.Deprecated('Use lsResponseDescriptor instead')
const LsResponse$json = {
  '1': 'LsResponse',
  '2': [
    {
      '1': 'files',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.idb.FileInfo',
      '10': 'files'
    },
    {
      '1': 'listings',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.idb.FileListing',
      '10': 'listings'
    },
  ],
};

/// Descriptor for `LsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List lsResponseDescriptor = $convert.base64Decode(
    'CgpMc1Jlc3BvbnNlEiMKBWZpbGVzGAEgAygLMg0uaWRiLkZpbGVJbmZvUgVmaWxlcxIsCghsaX'
    'N0aW5ncxgCIAMoCzIQLmlkYi5GaWxlTGlzdGluZ1IIbGlzdGluZ3M=');

@$core.Deprecated('Use lsRequestDescriptor instead')
const LsRequest$json = {
  '1': 'LsRequest',
  '2': [
    {'1': 'path', '3': 2, '4': 1, '5': 9, '10': 'path'},
    {
      '1': 'container',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.FileContainer',
      '10': 'container'
    },
    {'1': 'paths', '3': 4, '4': 3, '5': 9, '10': 'paths'},
  ],
};

/// Descriptor for `LsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List lsRequestDescriptor = $convert.base64Decode(
    'CglMc1JlcXVlc3QSEgoEcGF0aBgCIAEoCVIEcGF0aBIwCgljb250YWluZXIYAyABKAsyEi5pZG'
    'IuRmlsZUNvbnRhaW5lclIJY29udGFpbmVyEhQKBXBhdGhzGAQgAygJUgVwYXRocw==');

@$core.Deprecated('Use mkdirRequestDescriptor instead')
const MkdirRequest$json = {
  '1': 'MkdirRequest',
  '2': [
    {'1': 'path', '3': 2, '4': 1, '5': 9, '10': 'path'},
    {
      '1': 'container',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.FileContainer',
      '10': 'container'
    },
  ],
};

/// Descriptor for `MkdirRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List mkdirRequestDescriptor = $convert.base64Decode(
    'CgxNa2RpclJlcXVlc3QSEgoEcGF0aBgCIAEoCVIEcGF0aBIwCgljb250YWluZXIYAyABKAsyEi'
    '5pZGIuRmlsZUNvbnRhaW5lclIJY29udGFpbmVy');

@$core.Deprecated('Use mkdirResponseDescriptor instead')
const MkdirResponse$json = {
  '1': 'MkdirResponse',
};

/// Descriptor for `MkdirResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List mkdirResponseDescriptor =
    $convert.base64Decode('Cg1Na2RpclJlc3BvbnNl');

@$core.Deprecated('Use mvRequestDescriptor instead')
const MvRequest$json = {
  '1': 'MvRequest',
  '2': [
    {'1': 'src_paths', '3': 2, '4': 3, '5': 9, '10': 'srcPaths'},
    {'1': 'dst_path', '3': 3, '4': 1, '5': 9, '10': 'dstPath'},
    {
      '1': 'container',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.idb.FileContainer',
      '10': 'container'
    },
  ],
};

/// Descriptor for `MvRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List mvRequestDescriptor = $convert.base64Decode(
    'CglNdlJlcXVlc3QSGwoJc3JjX3BhdGhzGAIgAygJUghzcmNQYXRocxIZCghkc3RfcGF0aBgDIA'
    'EoCVIHZHN0UGF0aBIwCgljb250YWluZXIYBCABKAsyEi5pZGIuRmlsZUNvbnRhaW5lclIJY29u'
    'dGFpbmVy');

@$core.Deprecated('Use mvResponseDescriptor instead')
const MvResponse$json = {
  '1': 'MvResponse',
};

/// Descriptor for `MvResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List mvResponseDescriptor =
    $convert.base64Decode('CgpNdlJlc3BvbnNl');

@$core.Deprecated('Use rmRequestDescriptor instead')
const RmRequest$json = {
  '1': 'RmRequest',
  '2': [
    {'1': 'paths', '3': 2, '4': 3, '5': 9, '10': 'paths'},
    {
      '1': 'container',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.FileContainer',
      '10': 'container'
    },
  ],
};

/// Descriptor for `RmRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List rmRequestDescriptor = $convert.base64Decode(
    'CglSbVJlcXVlc3QSFAoFcGF0aHMYAiADKAlSBXBhdGhzEjAKCWNvbnRhaW5lchgDIAEoCzISLm'
    'lkYi5GaWxlQ29udGFpbmVyUgljb250YWluZXI=');

@$core.Deprecated('Use rmResponseDescriptor instead')
const RmResponse$json = {
  '1': 'RmResponse',
};

/// Descriptor for `RmResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List rmResponseDescriptor =
    $convert.base64Decode('CgpSbVJlc3BvbnNl');

@$core.Deprecated('Use pushRequestDescriptor instead')
const PushRequest$json = {
  '1': 'PushRequest',
  '2': [
    {
      '1': 'payload',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '9': 0,
      '10': 'payload'
    },
    {
      '1': 'inner',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.PushRequest.Inner',
      '9': 0,
      '10': 'inner'
    },
  ],
  '3': [PushRequest_Inner$json],
  '8': [
    {'1': 'value'},
  ],
};

@$core.Deprecated('Use pushRequestDescriptor instead')
const PushRequest_Inner$json = {
  '1': 'Inner',
  '2': [
    {'1': 'dst_path', '3': 2, '4': 1, '5': 9, '10': 'dstPath'},
    {
      '1': 'container',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.FileContainer',
      '10': 'container'
    },
  ],
};

/// Descriptor for `PushRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pushRequestDescriptor = $convert.base64Decode(
    'CgtQdXNoUmVxdWVzdBIoCgdwYXlsb2FkGAEgASgLMgwuaWRiLlBheWxvYWRIAFIHcGF5bG9hZB'
    'IuCgVpbm5lchgCIAEoCzIWLmlkYi5QdXNoUmVxdWVzdC5Jbm5lckgAUgVpbm5lchpUCgVJbm5l'
    'chIZCghkc3RfcGF0aBgCIAEoCVIHZHN0UGF0aBIwCgljb250YWluZXIYAyABKAsyEi5pZGIuRm'
    'lsZUNvbnRhaW5lclIJY29udGFpbmVyQgcKBXZhbHVl');

@$core.Deprecated('Use pushResponseDescriptor instead')
const PushResponse$json = {
  '1': 'PushResponse',
};

/// Descriptor for `PushResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pushResponseDescriptor =
    $convert.base64Decode('CgxQdXNoUmVzcG9uc2U=');

@$core.Deprecated('Use pullRequestDescriptor instead')
const PullRequest$json = {
  '1': 'PullRequest',
  '2': [
    {'1': 'src_path', '3': 2, '4': 1, '5': 9, '10': 'srcPath'},
    {'1': 'dst_path', '3': 3, '4': 1, '5': 9, '10': 'dstPath'},
    {
      '1': 'container',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.idb.FileContainer',
      '10': 'container'
    },
  ],
};

/// Descriptor for `PullRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pullRequestDescriptor = $convert.base64Decode(
    'CgtQdWxsUmVxdWVzdBIZCghzcmNfcGF0aBgCIAEoCVIHc3JjUGF0aBIZCghkc3RfcGF0aBgDIA'
    'EoCVIHZHN0UGF0aBIwCgljb250YWluZXIYBCABKAsyEi5pZGIuRmlsZUNvbnRhaW5lclIJY29u'
    'dGFpbmVy');

@$core.Deprecated('Use pullResponseDescriptor instead')
const PullResponse$json = {
  '1': 'PullResponse',
  '2': [
    {
      '1': 'payload',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.Payload',
      '10': 'payload'
    },
  ],
};

/// Descriptor for `PullResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pullResponseDescriptor = $convert.base64Decode(
    'CgxQdWxsUmVzcG9uc2USJgoHcGF5bG9hZBgBIAEoCzIMLmlkYi5QYXlsb2FkUgdwYXlsb2Fk');

@$core.Deprecated('Use tailRequestDescriptor instead')
const TailRequest$json = {
  '1': 'TailRequest',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.TailRequest.Start',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'stop',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.TailRequest.Stop',
      '9': 0,
      '10': 'stop'
    },
  ],
  '3': [TailRequest_Start$json, TailRequest_Stop$json],
  '8': [
    {'1': 'control'},
  ],
};

@$core.Deprecated('Use tailRequestDescriptor instead')
const TailRequest_Start$json = {
  '1': 'Start',
  '2': [
    {
      '1': 'container',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.FileContainer',
      '10': 'container'
    },
    {'1': 'path', '3': 2, '4': 1, '5': 9, '10': 'path'},
  ],
};

@$core.Deprecated('Use tailRequestDescriptor instead')
const TailRequest_Stop$json = {
  '1': 'Stop',
};

/// Descriptor for `TailRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailRequestDescriptor = $convert.base64Decode(
    'CgtUYWlsUmVxdWVzdBIuCgVzdGFydBgBIAEoCzIWLmlkYi5UYWlsUmVxdWVzdC5TdGFydEgAUg'
    'VzdGFydBIrCgRzdG9wGAIgASgLMhUuaWRiLlRhaWxSZXF1ZXN0LlN0b3BIAFIEc3RvcBpNCgVT'
    'dGFydBIwCgljb250YWluZXIYASABKAsyEi5pZGIuRmlsZUNvbnRhaW5lclIJY29udGFpbmVyEh'
    'IKBHBhdGgYAiABKAlSBHBhdGgaBgoEU3RvcEIJCgdjb250cm9s');

@$core.Deprecated('Use tailResponseDescriptor instead')
const TailResponse$json = {
  '1': 'TailResponse',
  '2': [
    {'1': 'data', '3': 1, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `TailResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tailResponseDescriptor =
    $convert.base64Decode('CgxUYWlsUmVzcG9uc2USEgoEZGF0YRgBIAEoDFIEZGF0YQ==');

@$core.Deprecated('Use debuggerInfoDescriptor instead')
const DebuggerInfo$json = {
  '1': 'DebuggerInfo',
  '2': [
    {'1': 'pid', '3': 1, '4': 1, '5': 4, '10': 'pid'},
    {'1': 'host', '3': 2, '4': 1, '5': 9, '10': 'host'},
    {'1': 'port', '3': 3, '4': 1, '5': 4, '10': 'port'},
  ],
};

/// Descriptor for `DebuggerInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List debuggerInfoDescriptor = $convert.base64Decode(
    'CgxEZWJ1Z2dlckluZm8SEAoDcGlkGAEgASgEUgNwaWQSEgoEaG9zdBgCIAEoCVIEaG9zdBISCg'
    'Rwb3J0GAMgASgEUgRwb3J0');

@$core.Deprecated('Use sendNotificationRequestDescriptor instead')
const SendNotificationRequest$json = {
  '1': 'SendNotificationRequest',
  '2': [
    {'1': 'bundle_id', '3': 1, '4': 1, '5': 9, '10': 'bundleId'},
    {'1': 'json_payload', '3': 2, '4': 1, '5': 9, '10': 'jsonPayload'},
  ],
};

/// Descriptor for `SendNotificationRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sendNotificationRequestDescriptor =
    $convert.base64Decode(
        'ChdTZW5kTm90aWZpY2F0aW9uUmVxdWVzdBIbCglidW5kbGVfaWQYASABKAlSCGJ1bmRsZUlkEi'
        'EKDGpzb25fcGF5bG9hZBgCIAEoCVILanNvblBheWxvYWQ=');

@$core.Deprecated('Use sendNotificationResponseDescriptor instead')
const SendNotificationResponse$json = {
  '1': 'SendNotificationResponse',
};

/// Descriptor for `SendNotificationResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sendNotificationResponseDescriptor =
    $convert.base64Decode('ChhTZW5kTm90aWZpY2F0aW9uUmVzcG9uc2U=');

@$core.Deprecated('Use dapRequestDescriptor instead')
const DapRequest$json = {
  '1': 'DapRequest',
  '2': [
    {
      '1': 'start',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.DapRequest.Start',
      '9': 0,
      '10': 'start'
    },
    {
      '1': 'pipe',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.DapRequest.Pipe',
      '9': 0,
      '10': 'pipe'
    },
    {
      '1': 'stop',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.DapRequest.Stop',
      '9': 0,
      '10': 'stop'
    },
  ],
  '3': [DapRequest_Start$json, DapRequest_Pipe$json, DapRequest_Stop$json],
  '8': [
    {'1': 'control'},
  ],
};

@$core.Deprecated('Use dapRequestDescriptor instead')
const DapRequest_Start$json = {
  '1': 'Start',
  '2': [
    {'1': 'debugger_pkg_id', '3': 1, '4': 1, '5': 9, '10': 'debuggerPkgId'},
  ],
};

@$core.Deprecated('Use dapRequestDescriptor instead')
const DapRequest_Pipe$json = {
  '1': 'Pipe',
  '2': [
    {'1': 'data', '3': 1, '4': 1, '5': 12, '10': 'data'},
  ],
};

@$core.Deprecated('Use dapRequestDescriptor instead')
const DapRequest_Stop$json = {
  '1': 'Stop',
};

/// Descriptor for `DapRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List dapRequestDescriptor = $convert.base64Decode(
    'CgpEYXBSZXF1ZXN0Ei0KBXN0YXJ0GAEgASgLMhUuaWRiLkRhcFJlcXVlc3QuU3RhcnRIAFIFc3'
    'RhcnQSKgoEcGlwZRgCIAEoCzIULmlkYi5EYXBSZXF1ZXN0LlBpcGVIAFIEcGlwZRIqCgRzdG9w'
    'GAMgASgLMhQuaWRiLkRhcFJlcXVlc3QuU3RvcEgAUgRzdG9wGi8KBVN0YXJ0EiYKD2RlYnVnZ2'
    'VyX3BrZ19pZBgBIAEoCVINZGVidWdnZXJQa2dJZBoaCgRQaXBlEhIKBGRhdGEYASABKAxSBGRh'
    'dGEaBgoEU3RvcEIJCgdjb250cm9s');

@$core.Deprecated('Use dapResponseDescriptor instead')
const DapResponse$json = {
  '1': 'DapResponse',
  '2': [
    {
      '1': 'started',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.idb.DapResponse.Event',
      '9': 0,
      '10': 'started'
    },
    {
      '1': 'stdout',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.idb.DapResponse.Pipe',
      '9': 0,
      '10': 'stdout'
    },
    {
      '1': 'stopped',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.idb.DapResponse.Event',
      '9': 0,
      '10': 'stopped'
    },
  ],
  '3': [DapResponse_Event$json, DapResponse_Pipe$json],
  '8': [
    {'1': 'event'},
  ],
};

@$core.Deprecated('Use dapResponseDescriptor instead')
const DapResponse_Event$json = {
  '1': 'Event',
  '2': [
    {'1': 'desc', '3': 1, '4': 1, '5': 9, '10': 'desc'},
  ],
};

@$core.Deprecated('Use dapResponseDescriptor instead')
const DapResponse_Pipe$json = {
  '1': 'Pipe',
  '2': [
    {'1': 'data', '3': 1, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `DapResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List dapResponseDescriptor = $convert.base64Decode(
    'CgtEYXBSZXNwb25zZRIyCgdzdGFydGVkGAEgASgLMhYuaWRiLkRhcFJlc3BvbnNlLkV2ZW50SA'
    'BSB3N0YXJ0ZWQSLwoGc3Rkb3V0GAIgASgLMhUuaWRiLkRhcFJlc3BvbnNlLlBpcGVIAFIGc3Rk'
    'b3V0EjIKB3N0b3BwZWQYAyABKAsyFi5pZGIuRGFwUmVzcG9uc2UuRXZlbnRIAFIHc3RvcHBlZB'
    'obCgVFdmVudBISCgRkZXNjGAEgASgJUgRkZXNjGhoKBFBpcGUSEgoEZGF0YRgBIAEoDFIEZGF0'
    'YUIHCgVldmVudA==');

@$core.Deprecated('Use simulateMemoryWarningRequestDescriptor instead')
const SimulateMemoryWarningRequest$json = {
  '1': 'SimulateMemoryWarningRequest',
};

/// Descriptor for `SimulateMemoryWarningRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List simulateMemoryWarningRequestDescriptor =
    $convert.base64Decode('ChxTaW11bGF0ZU1lbW9yeVdhcm5pbmdSZXF1ZXN0');

@$core.Deprecated('Use simulateMemoryWarningResponseDescriptor instead')
const SimulateMemoryWarningResponse$json = {
  '1': 'SimulateMemoryWarningResponse',
};

/// Descriptor for `SimulateMemoryWarningResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List simulateMemoryWarningResponseDescriptor =
    $convert.base64Decode('Ch1TaW11bGF0ZU1lbW9yeVdhcm5pbmdSZXNwb25zZQ==');
