// This is a generated file - do not edit.
//
// Generated from idb.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class Setting extends $pb.ProtobufEnum {
  static const Setting LOCALE = Setting._(0, _omitEnumNames ? '' : 'LOCALE');
  static const Setting ANY = Setting._(1, _omitEnumNames ? '' : 'ANY');

  static const $core.List<Setting> values = <Setting>[
    LOCALE,
    ANY,
  ];

  static final $core.List<Setting?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static Setting? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const Setting._(super.value, super.name);
}

class Payload_Compression extends $pb.ProtobufEnum {
  static const Payload_Compression GZIP =
      Payload_Compression._(0, _omitEnumNames ? '' : 'GZIP');
  static const Payload_Compression ZSTD =
      Payload_Compression._(1, _omitEnumNames ? '' : 'ZSTD');

  static const $core.List<Payload_Compression> values = <Payload_Compression>[
    GZIP,
    ZSTD,
  ];

  static final $core.List<Payload_Compression?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static Payload_Compression? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const Payload_Compression._(super.value, super.name);
}

class ProcessOutput_Interface extends $pb.ProtobufEnum {
  static const ProcessOutput_Interface STDOUT =
      ProcessOutput_Interface._(0, _omitEnumNames ? '' : 'STDOUT');
  static const ProcessOutput_Interface STDERR =
      ProcessOutput_Interface._(1, _omitEnumNames ? '' : 'STDERR');

  static const $core.List<ProcessOutput_Interface> values =
      <ProcessOutput_Interface>[
    STDOUT,
    STDERR,
  ];

  static final $core.List<ProcessOutput_Interface?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static ProcessOutput_Interface? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ProcessOutput_Interface._(super.value, super.name);
}

class InstalledAppInfo_AppProcessState extends $pb.ProtobufEnum {
  static const InstalledAppInfo_AppProcessState UNKNOWN =
      InstalledAppInfo_AppProcessState._(0, _omitEnumNames ? '' : 'UNKNOWN');
  static const InstalledAppInfo_AppProcessState NOT_RUNNING =
      InstalledAppInfo_AppProcessState._(
          1, _omitEnumNames ? '' : 'NOT_RUNNING');
  static const InstalledAppInfo_AppProcessState RUNNING =
      InstalledAppInfo_AppProcessState._(2, _omitEnumNames ? '' : 'RUNNING');

  static const $core.List<InstalledAppInfo_AppProcessState> values =
      <InstalledAppInfo_AppProcessState>[
    UNKNOWN,
    NOT_RUNNING,
    RUNNING,
  ];

  static final $core.List<InstalledAppInfo_AppProcessState?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static InstalledAppInfo_AppProcessState? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const InstalledAppInfo_AppProcessState._(super.value, super.name);
}

class InstallRequest_Destination extends $pb.ProtobufEnum {
  static const InstallRequest_Destination APP =
      InstallRequest_Destination._(0, _omitEnumNames ? '' : 'APP');
  static const InstallRequest_Destination XCTEST =
      InstallRequest_Destination._(1, _omitEnumNames ? '' : 'XCTEST');
  static const InstallRequest_Destination DYLIB =
      InstallRequest_Destination._(2, _omitEnumNames ? '' : 'DYLIB');
  static const InstallRequest_Destination DSYM =
      InstallRequest_Destination._(3, _omitEnumNames ? '' : 'DSYM');
  static const InstallRequest_Destination FRAMEWORK =
      InstallRequest_Destination._(4, _omitEnumNames ? '' : 'FRAMEWORK');

  static const $core.List<InstallRequest_Destination> values =
      <InstallRequest_Destination>[
    APP,
    XCTEST,
    DYLIB,
    DSYM,
    FRAMEWORK,
  ];

  static final $core.List<InstallRequest_Destination?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static InstallRequest_Destination? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const InstallRequest_Destination._(super.value, super.name);
}

class InstallRequest_LinkDsymToBundle_BundleType extends $pb.ProtobufEnum {
  static const InstallRequest_LinkDsymToBundle_BundleType APP =
      InstallRequest_LinkDsymToBundle_BundleType._(
          0, _omitEnumNames ? '' : 'APP');
  static const InstallRequest_LinkDsymToBundle_BundleType XCTEST =
      InstallRequest_LinkDsymToBundle_BundleType._(
          1, _omitEnumNames ? '' : 'XCTEST');

  static const $core.List<InstallRequest_LinkDsymToBundle_BundleType> values =
      <InstallRequest_LinkDsymToBundle_BundleType>[
    APP,
    XCTEST,
  ];

  static final $core.List<InstallRequest_LinkDsymToBundle_BundleType?>
      _byValue = $pb.ProtobufEnum.$_initByValueList(values, 1);
  static InstallRequest_LinkDsymToBundle_BundleType? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const InstallRequest_LinkDsymToBundle_BundleType._(super.value, super.name);
}

class ScreenshotRequest_Format extends $pb.ProtobufEnum {
  static const ScreenshotRequest_Format PNG =
      ScreenshotRequest_Format._(0, _omitEnumNames ? '' : 'PNG');
  static const ScreenshotRequest_Format JPEG =
      ScreenshotRequest_Format._(1, _omitEnumNames ? '' : 'JPEG');
  static const ScreenshotRequest_Format TIFF =
      ScreenshotRequest_Format._(2, _omitEnumNames ? '' : 'TIFF');

  static const $core.List<ScreenshotRequest_Format> values =
      <ScreenshotRequest_Format>[
    PNG,
    JPEG,
    TIFF,
  ];

  static final $core.List<ScreenshotRequest_Format?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static ScreenshotRequest_Format? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ScreenshotRequest_Format._(super.value, super.name);
}

/// The unit that `crop` and `fit` are expressed in. POINTS is the coordinate
/// space that tap, swipe and describe already use; it is resolved to pixels
/// on the companion, which is the only side that knows the screen scale.
class ScreenshotRequest_Unit extends $pb.ProtobufEnum {
  static const ScreenshotRequest_Unit PIXELS =
      ScreenshotRequest_Unit._(0, _omitEnumNames ? '' : 'PIXELS');
  static const ScreenshotRequest_Unit POINTS =
      ScreenshotRequest_Unit._(1, _omitEnumNames ? '' : 'POINTS');

  static const $core.List<ScreenshotRequest_Unit> values =
      <ScreenshotRequest_Unit>[
    PIXELS,
    POINTS,
  ];

  static final $core.List<ScreenshotRequest_Unit?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static ScreenshotRequest_Unit? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ScreenshotRequest_Unit._(super.value, super.name);
}

class AccessibilityInfoRequest_Format extends $pb.ProtobufEnum {
  static const AccessibilityInfoRequest_Format LEGACY =
      AccessibilityInfoRequest_Format._(0, _omitEnumNames ? '' : 'LEGACY');
  static const AccessibilityInfoRequest_Format NESTED =
      AccessibilityInfoRequest_Format._(1, _omitEnumNames ? '' : 'NESTED');

  /// A consolidated document: the element tree plus the read's provenance
  /// (which backend served it, what was asked, screen bounds, truncation,
  /// any blocking modal). An older server does not recognize this value and
  /// falls back to LEGACY — a caller can detect that by the response shape.
  static const AccessibilityInfoRequest_Format COMPLETE =
      AccessibilityInfoRequest_Format._(2, _omitEnumNames ? '' : 'COMPLETE');

  static const $core.List<AccessibilityInfoRequest_Format> values =
      <AccessibilityInfoRequest_Format>[
    LEGACY,
    NESTED,
    COMPLETE,
  ];

  static final $core.List<AccessibilityInfoRequest_Format?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static AccessibilityInfoRequest_Format? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const AccessibilityInfoRequest_Format._(super.value, super.name);
}

/// Which backend serves the read. UNSPECIFIED preserves the historical
/// behaviour, so an older client — or one that does not ask — is unaffected;
/// an older server ignores this field entirely and serves the read as if it
/// were unset.
class AccessibilityInfoRequest_Backend extends $pb.ProtobufEnum {
  static const AccessibilityInfoRequest_Backend BACKEND_UNSPECIFIED =
      AccessibilityInfoRequest_Backend._(
          0, _omitEnumNames ? '' : 'BACKEND_UNSPECIFIED');
  static const AccessibilityInfoRequest_Backend AX =
      AccessibilityInfoRequest_Backend._(1, _omitEnumNames ? '' : 'AX');
  static const AccessibilityInfoRequest_Backend AXBRIDGE =
      AccessibilityInfoRequest_Backend._(2, _omitEnumNames ? '' : 'AXBRIDGE');
  static const AccessibilityInfoRequest_Backend AXBRIDGE_PERSISTENT =
      AccessibilityInfoRequest_Backend._(
          3, _omitEnumNames ? '' : 'AXBRIDGE_PERSISTENT');

  static const $core.List<AccessibilityInfoRequest_Backend> values =
      <AccessibilityInfoRequest_Backend>[
    BACKEND_UNSPECIFIED,
    AX,
    AXBRIDGE,
    AXBRIDGE_PERSISTENT,
  ];

  static final $core.List<AccessibilityInfoRequest_Backend?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static AccessibilityInfoRequest_Backend? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const AccessibilityInfoRequest_Backend._(super.value, super.name);
}

class AccessibilityActionRequest_SearchableKey extends $pb.ProtobufEnum {
  static const AccessibilityActionRequest_SearchableKey LABEL =
      AccessibilityActionRequest_SearchableKey._(
          0, _omitEnumNames ? '' : 'LABEL');
  static const AccessibilityActionRequest_SearchableKey UNIQUE_ID =
      AccessibilityActionRequest_SearchableKey._(
          1, _omitEnumNames ? '' : 'UNIQUE_ID');
  static const AccessibilityActionRequest_SearchableKey VALUE =
      AccessibilityActionRequest_SearchableKey._(
          2, _omitEnumNames ? '' : 'VALUE');
  static const AccessibilityActionRequest_SearchableKey TITLE =
      AccessibilityActionRequest_SearchableKey._(
          3, _omitEnumNames ? '' : 'TITLE');
  static const AccessibilityActionRequest_SearchableKey ROLE =
      AccessibilityActionRequest_SearchableKey._(
          4, _omitEnumNames ? '' : 'ROLE');
  static const AccessibilityActionRequest_SearchableKey ROLE_DESCRIPTION =
      AccessibilityActionRequest_SearchableKey._(
          5, _omitEnumNames ? '' : 'ROLE_DESCRIPTION');
  static const AccessibilityActionRequest_SearchableKey SUBROLE =
      AccessibilityActionRequest_SearchableKey._(
          6, _omitEnumNames ? '' : 'SUBROLE');
  static const AccessibilityActionRequest_SearchableKey HELP =
      AccessibilityActionRequest_SearchableKey._(
          7, _omitEnumNames ? '' : 'HELP');
  static const AccessibilityActionRequest_SearchableKey PLACEHOLDER =
      AccessibilityActionRequest_SearchableKey._(
          8, _omitEnumNames ? '' : 'PLACEHOLDER');

  static const $core.List<AccessibilityActionRequest_SearchableKey> values =
      <AccessibilityActionRequest_SearchableKey>[
    LABEL,
    UNIQUE_ID,
    VALUE,
    TITLE,
    ROLE,
    ROLE_DESCRIPTION,
    SUBROLE,
    HELP,
    PLACEHOLDER,
  ];

  static final $core.List<AccessibilityActionRequest_SearchableKey?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 8);
  static AccessibilityActionRequest_SearchableKey? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const AccessibilityActionRequest_SearchableKey._(super.value, super.name);
}

class AccessibilityActionRequest_Scroll_Direction extends $pb.ProtobufEnum {
  static const AccessibilityActionRequest_Scroll_Direction UP =
      AccessibilityActionRequest_Scroll_Direction._(
          0, _omitEnumNames ? '' : 'UP');
  static const AccessibilityActionRequest_Scroll_Direction DOWN =
      AccessibilityActionRequest_Scroll_Direction._(
          1, _omitEnumNames ? '' : 'DOWN');
  static const AccessibilityActionRequest_Scroll_Direction LEFT =
      AccessibilityActionRequest_Scroll_Direction._(
          2, _omitEnumNames ? '' : 'LEFT');
  static const AccessibilityActionRequest_Scroll_Direction RIGHT =
      AccessibilityActionRequest_Scroll_Direction._(
          3, _omitEnumNames ? '' : 'RIGHT');
  static const AccessibilityActionRequest_Scroll_Direction VISIBLE =
      AccessibilityActionRequest_Scroll_Direction._(
          4, _omitEnumNames ? '' : 'VISIBLE');

  static const $core.List<AccessibilityActionRequest_Scroll_Direction> values =
      <AccessibilityActionRequest_Scroll_Direction>[
    UP,
    DOWN,
    LEFT,
    RIGHT,
    VISIBLE,
  ];

  static final $core.List<AccessibilityActionRequest_Scroll_Direction?>
      _byValue = $pb.ProtobufEnum.$_initByValueList(values, 4);
  static AccessibilityActionRequest_Scroll_Direction? valueOf(
          $core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const AccessibilityActionRequest_Scroll_Direction._(super.value, super.name);
}

class ApproveRequest_Permission extends $pb.ProtobufEnum {
  static const ApproveRequest_Permission PHOTOS =
      ApproveRequest_Permission._(0, _omitEnumNames ? '' : 'PHOTOS');
  static const ApproveRequest_Permission CAMERA =
      ApproveRequest_Permission._(1, _omitEnumNames ? '' : 'CAMERA');
  static const ApproveRequest_Permission CONTACTS =
      ApproveRequest_Permission._(2, _omitEnumNames ? '' : 'CONTACTS');
  static const ApproveRequest_Permission URL =
      ApproveRequest_Permission._(3, _omitEnumNames ? '' : 'URL');
  static const ApproveRequest_Permission LOCATION =
      ApproveRequest_Permission._(4, _omitEnumNames ? '' : 'LOCATION');
  static const ApproveRequest_Permission NOTIFICATION =
      ApproveRequest_Permission._(5, _omitEnumNames ? '' : 'NOTIFICATION');
  static const ApproveRequest_Permission MICROPHONE =
      ApproveRequest_Permission._(6, _omitEnumNames ? '' : 'MICROPHONE');

  static const $core.List<ApproveRequest_Permission> values =
      <ApproveRequest_Permission>[
    PHOTOS,
    CAMERA,
    CONTACTS,
    URL,
    LOCATION,
    NOTIFICATION,
    MICROPHONE,
  ];

  static final $core.List<ApproveRequest_Permission?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 6);
  static ApproveRequest_Permission? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ApproveRequest_Permission._(super.value, super.name);
}

class RevokeRequest_Permission extends $pb.ProtobufEnum {
  static const RevokeRequest_Permission PHOTOS =
      RevokeRequest_Permission._(0, _omitEnumNames ? '' : 'PHOTOS');
  static const RevokeRequest_Permission CAMERA =
      RevokeRequest_Permission._(1, _omitEnumNames ? '' : 'CAMERA');
  static const RevokeRequest_Permission CONTACTS =
      RevokeRequest_Permission._(2, _omitEnumNames ? '' : 'CONTACTS');
  static const RevokeRequest_Permission URL =
      RevokeRequest_Permission._(3, _omitEnumNames ? '' : 'URL');
  static const RevokeRequest_Permission LOCATION =
      RevokeRequest_Permission._(4, _omitEnumNames ? '' : 'LOCATION');
  static const RevokeRequest_Permission NOTIFICATION =
      RevokeRequest_Permission._(5, _omitEnumNames ? '' : 'NOTIFICATION');
  static const RevokeRequest_Permission MICROPHONE =
      RevokeRequest_Permission._(6, _omitEnumNames ? '' : 'MICROPHONE');

  static const $core.List<RevokeRequest_Permission> values =
      <RevokeRequest_Permission>[
    PHOTOS,
    CAMERA,
    CONTACTS,
    URL,
    LOCATION,
    NOTIFICATION,
    MICROPHONE,
  ];

  static final $core.List<RevokeRequest_Permission?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 6);
  static RevokeRequest_Permission? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const RevokeRequest_Permission._(super.value, super.name);
}

class HIDEvent_HIDDirection extends $pb.ProtobufEnum {
  static const HIDEvent_HIDDirection DOWN =
      HIDEvent_HIDDirection._(0, _omitEnumNames ? '' : 'DOWN');
  static const HIDEvent_HIDDirection UP =
      HIDEvent_HIDDirection._(1, _omitEnumNames ? '' : 'UP');

  static const $core.List<HIDEvent_HIDDirection> values =
      <HIDEvent_HIDDirection>[
    DOWN,
    UP,
  ];

  static final $core.List<HIDEvent_HIDDirection?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static HIDEvent_HIDDirection? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const HIDEvent_HIDDirection._(super.value, super.name);
}

class HIDEvent_HIDButtonType extends $pb.ProtobufEnum {
  static const HIDEvent_HIDButtonType APPLE_PAY =
      HIDEvent_HIDButtonType._(0, _omitEnumNames ? '' : 'APPLE_PAY');
  static const HIDEvent_HIDButtonType HOME =
      HIDEvent_HIDButtonType._(1, _omitEnumNames ? '' : 'HOME');
  static const HIDEvent_HIDButtonType LOCK =
      HIDEvent_HIDButtonType._(2, _omitEnumNames ? '' : 'LOCK');
  static const HIDEvent_HIDButtonType SIDE_BUTTON =
      HIDEvent_HIDButtonType._(3, _omitEnumNames ? '' : 'SIDE_BUTTON');
  static const HIDEvent_HIDButtonType SIRI =
      HIDEvent_HIDButtonType._(4, _omitEnumNames ? '' : 'SIRI');

  static const $core.List<HIDEvent_HIDButtonType> values =
      <HIDEvent_HIDButtonType>[
    APPLE_PAY,
    HOME,
    LOCK,
    SIDE_BUTTON,
    SIRI,
  ];

  static final $core.List<HIDEvent_HIDButtonType?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static HIDEvent_HIDButtonType? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const HIDEvent_HIDButtonType._(super.value, super.name);
}

class HIDEvent_HIDOrientationType extends $pb.ProtobufEnum {
  static const HIDEvent_HIDOrientationType PORTRAIT =
      HIDEvent_HIDOrientationType._(0, _omitEnumNames ? '' : 'PORTRAIT');
  static const HIDEvent_HIDOrientationType PORTRAIT_UPSIDE_DOWN =
      HIDEvent_HIDOrientationType._(
          1, _omitEnumNames ? '' : 'PORTRAIT_UPSIDE_DOWN');
  static const HIDEvent_HIDOrientationType LANDSCAPE_LEFT =
      HIDEvent_HIDOrientationType._(2, _omitEnumNames ? '' : 'LANDSCAPE_LEFT');
  static const HIDEvent_HIDOrientationType LANDSCAPE_RIGHT =
      HIDEvent_HIDOrientationType._(3, _omitEnumNames ? '' : 'LANDSCAPE_RIGHT');

  static const $core.List<HIDEvent_HIDOrientationType> values =
      <HIDEvent_HIDOrientationType>[
    PORTRAIT,
    PORTRAIT_UPSIDE_DOWN,
    LANDSCAPE_LEFT,
    LANDSCAPE_RIGHT,
  ];

  static final $core.List<HIDEvent_HIDOrientationType?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static HIDEvent_HIDOrientationType? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const HIDEvent_HIDOrientationType._(super.value, super.name);
}

class LogRequest_Source extends $pb.ProtobufEnum {
  static const LogRequest_Source TARGET =
      LogRequest_Source._(0, _omitEnumNames ? '' : 'TARGET');
  static const LogRequest_Source COMPANION =
      LogRequest_Source._(1, _omitEnumNames ? '' : 'COMPANION');

  static const $core.List<LogRequest_Source> values = <LogRequest_Source>[
    TARGET,
    COMPANION,
  ];

  static final $core.List<LogRequest_Source?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static LogRequest_Source? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const LogRequest_Source._(super.value, super.name);
}

class VideoStreamRequest_Format extends $pb.ProtobufEnum {
  static const VideoStreamRequest_Format H264 =
      VideoStreamRequest_Format._(0, _omitEnumNames ? '' : 'H264');
  static const VideoStreamRequest_Format RBGA =
      VideoStreamRequest_Format._(1, _omitEnumNames ? '' : 'RBGA');
  static const VideoStreamRequest_Format MJPEG =
      VideoStreamRequest_Format._(2, _omitEnumNames ? '' : 'MJPEG');
  static const VideoStreamRequest_Format MINICAP =
      VideoStreamRequest_Format._(3, _omitEnumNames ? '' : 'MINICAP');
  static const VideoStreamRequest_Format I420 =
      VideoStreamRequest_Format._(4, _omitEnumNames ? '' : 'I420');

  static const $core.List<VideoStreamRequest_Format> values =
      <VideoStreamRequest_Format>[
    H264,
    RBGA,
    MJPEG,
    MINICAP,
    I420,
  ];

  static final $core.List<VideoStreamRequest_Format?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static VideoStreamRequest_Format? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const VideoStreamRequest_Format._(super.value, super.name);
}

class InstrumentsRunResponse_State extends $pb.ProtobufEnum {
  static const InstrumentsRunResponse_State UNKNOWN =
      InstrumentsRunResponse_State._(0, _omitEnumNames ? '' : 'UNKNOWN');
  static const InstrumentsRunResponse_State RUNNING_INSTRUMENTS =
      InstrumentsRunResponse_State._(
          1, _omitEnumNames ? '' : 'RUNNING_INSTRUMENTS');
  static const InstrumentsRunResponse_State POST_PROCESSING =
      InstrumentsRunResponse_State._(
          2, _omitEnumNames ? '' : 'POST_PROCESSING');

  static const $core.List<InstrumentsRunResponse_State> values =
      <InstrumentsRunResponse_State>[
    UNKNOWN,
    RUNNING_INSTRUMENTS,
    POST_PROCESSING,
  ];

  static final $core.List<InstrumentsRunResponse_State?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static InstrumentsRunResponse_State? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const InstrumentsRunResponse_State._(super.value, super.name);
}

class XctraceRecordResponse_State extends $pb.ProtobufEnum {
  static const XctraceRecordResponse_State UNKNOWN =
      XctraceRecordResponse_State._(0, _omitEnumNames ? '' : 'UNKNOWN');
  static const XctraceRecordResponse_State RUNNING =
      XctraceRecordResponse_State._(1, _omitEnumNames ? '' : 'RUNNING');
  static const XctraceRecordResponse_State PROCESSING =
      XctraceRecordResponse_State._(2, _omitEnumNames ? '' : 'PROCESSING');

  static const $core.List<XctraceRecordResponse_State> values =
      <XctraceRecordResponse_State>[
    UNKNOWN,
    RUNNING,
    PROCESSING,
  ];

  static final $core.List<XctraceRecordResponse_State?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static XctraceRecordResponse_State? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const XctraceRecordResponse_State._(super.value, super.name);
}

class XctestRunRequest_CodeCoverage_Format extends $pb.ProtobufEnum {
  static const XctestRunRequest_CodeCoverage_Format EXPORTED =
      XctestRunRequest_CodeCoverage_Format._(
          0, _omitEnumNames ? '' : 'EXPORTED');
  static const XctestRunRequest_CodeCoverage_Format RAW =
      XctestRunRequest_CodeCoverage_Format._(1, _omitEnumNames ? '' : 'RAW');

  static const $core.List<XctestRunRequest_CodeCoverage_Format> values =
      <XctestRunRequest_CodeCoverage_Format>[
    EXPORTED,
    RAW,
  ];

  static final $core.List<XctestRunRequest_CodeCoverage_Format?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static XctestRunRequest_CodeCoverage_Format? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const XctestRunRequest_CodeCoverage_Format._(super.value, super.name);
}

class XctestRunResponse_Status extends $pb.ProtobufEnum {
  static const XctestRunResponse_Status RUNNING =
      XctestRunResponse_Status._(0, _omitEnumNames ? '' : 'RUNNING');
  static const XctestRunResponse_Status TERMINATED_NORMALLY =
      XctestRunResponse_Status._(
          1, _omitEnumNames ? '' : 'TERMINATED_NORMALLY');
  static const XctestRunResponse_Status TERMINATED_ABNORMALLY =
      XctestRunResponse_Status._(
          2, _omitEnumNames ? '' : 'TERMINATED_ABNORMALLY');

  static const $core.List<XctestRunResponse_Status> values =
      <XctestRunResponse_Status>[
    RUNNING,
    TERMINATED_NORMALLY,
    TERMINATED_ABNORMALLY,
  ];

  static final $core.List<XctestRunResponse_Status?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static XctestRunResponse_Status? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const XctestRunResponse_Status._(super.value, super.name);
}

class XctestRunResponse_TestRunInfo_Status extends $pb.ProtobufEnum {
  static const XctestRunResponse_TestRunInfo_Status PASSED =
      XctestRunResponse_TestRunInfo_Status._(0, _omitEnumNames ? '' : 'PASSED');
  static const XctestRunResponse_TestRunInfo_Status FAILED =
      XctestRunResponse_TestRunInfo_Status._(1, _omitEnumNames ? '' : 'FAILED');
  static const XctestRunResponse_TestRunInfo_Status CRASHED =
      XctestRunResponse_TestRunInfo_Status._(
          2, _omitEnumNames ? '' : 'CRASHED');

  static const $core.List<XctestRunResponse_TestRunInfo_Status> values =
      <XctestRunResponse_TestRunInfo_Status>[
    PASSED,
    FAILED,
    CRASHED,
  ];

  static final $core.List<XctestRunResponse_TestRunInfo_Status?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static XctestRunResponse_TestRunInfo_Status? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const XctestRunResponse_TestRunInfo_Status._(super.value, super.name);
}

class ReplRequest_Start_Context extends $pb.ProtobufEnum {
  static const ReplRequest_Start_Context SIMULATOR =
      ReplRequest_Start_Context._(0, _omitEnumNames ? '' : 'SIMULATOR');
  static const ReplRequest_Start_Context TEST =
      ReplRequest_Start_Context._(1, _omitEnumNames ? '' : 'TEST');
  static const ReplRequest_Start_Context APP =
      ReplRequest_Start_Context._(2, _omitEnumNames ? '' : 'APP');

  static const $core.List<ReplRequest_Start_Context> values =
      <ReplRequest_Start_Context>[
    SIMULATOR,
    TEST,
    APP,
  ];

  static final $core.List<ReplRequest_Start_Context?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static ReplRequest_Start_Context? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ReplRequest_Start_Context._(super.value, super.name);
}

class FileContainer_Kind extends $pb.ProtobufEnum {
  static const FileContainer_Kind NONE =
      FileContainer_Kind._(0, _omitEnumNames ? '' : 'NONE');
  static const FileContainer_Kind APPLICATION =
      FileContainer_Kind._(1, _omitEnumNames ? '' : 'APPLICATION');
  static const FileContainer_Kind ROOT =
      FileContainer_Kind._(2, _omitEnumNames ? '' : 'ROOT');
  static const FileContainer_Kind MEDIA =
      FileContainer_Kind._(3, _omitEnumNames ? '' : 'MEDIA');
  static const FileContainer_Kind CRASHES =
      FileContainer_Kind._(4, _omitEnumNames ? '' : 'CRASHES');
  static const FileContainer_Kind PROVISIONING_PROFILES =
      FileContainer_Kind._(5, _omitEnumNames ? '' : 'PROVISIONING_PROFILES');
  static const FileContainer_Kind MDM_PROFILES =
      FileContainer_Kind._(6, _omitEnumNames ? '' : 'MDM_PROFILES');
  static const FileContainer_Kind SPRINGBOARD_ICONS =
      FileContainer_Kind._(7, _omitEnumNames ? '' : 'SPRINGBOARD_ICONS');
  static const FileContainer_Kind WALLPAPER =
      FileContainer_Kind._(8, _omitEnumNames ? '' : 'WALLPAPER');
  static const FileContainer_Kind DISK_IMAGES =
      FileContainer_Kind._(9, _omitEnumNames ? '' : 'DISK_IMAGES');
  static const FileContainer_Kind GROUP_CONTAINER =
      FileContainer_Kind._(10, _omitEnumNames ? '' : 'GROUP_CONTAINER');
  static const FileContainer_Kind APPLICATION_CONTAINER =
      FileContainer_Kind._(11, _omitEnumNames ? '' : 'APPLICATION_CONTAINER');
  static const FileContainer_Kind AUXILLARY =
      FileContainer_Kind._(12, _omitEnumNames ? '' : 'AUXILLARY');
  static const FileContainer_Kind XCTEST =
      FileContainer_Kind._(13, _omitEnumNames ? '' : 'XCTEST');
  static const FileContainer_Kind DYLIB =
      FileContainer_Kind._(14, _omitEnumNames ? '' : 'DYLIB');
  static const FileContainer_Kind DSYM =
      FileContainer_Kind._(15, _omitEnumNames ? '' : 'DSYM');
  static const FileContainer_Kind FRAMEWORK =
      FileContainer_Kind._(16, _omitEnumNames ? '' : 'FRAMEWORK');
  static const FileContainer_Kind SYMBOLS =
      FileContainer_Kind._(17, _omitEnumNames ? '' : 'SYMBOLS');

  static const $core.List<FileContainer_Kind> values = <FileContainer_Kind>[
    NONE,
    APPLICATION,
    ROOT,
    MEDIA,
    CRASHES,
    PROVISIONING_PROFILES,
    MDM_PROFILES,
    SPRINGBOARD_ICONS,
    WALLPAPER,
    DISK_IMAGES,
    GROUP_CONTAINER,
    APPLICATION_CONTAINER,
    AUXILLARY,
    XCTEST,
    DYLIB,
    DSYM,
    FRAMEWORK,
    SYMBOLS,
  ];

  static final $core.List<FileContainer_Kind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 17);
  static FileContainer_Kind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const FileContainer_Kind._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
