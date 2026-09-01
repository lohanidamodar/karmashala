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

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'idb.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'idb.pbenum.dart';

enum Payload_Source { filePath, data, url, compression, notSet }

class Payload extends $pb.GeneratedMessage {
  factory Payload({
    $core.String? filePath,
    $core.List<$core.int>? data,
    $core.String? url,
    Payload_Compression? compression,
  }) {
    final result = create();
    if (filePath != null) result.filePath = filePath;
    if (data != null) result.data = data;
    if (url != null) result.url = url;
    if (compression != null) result.compression = compression;
    return result;
  }

  Payload._();

  factory Payload.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Payload.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, Payload_Source> _Payload_SourceByTag = {
    1: Payload_Source.filePath,
    2: Payload_Source.data,
    3: Payload_Source.url,
    4: Payload_Source.compression,
    0: Payload_Source.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Payload',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3, 4])
    ..aOS(1, _omitFieldNames ? '' : 'filePath')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..aOS(3, _omitFieldNames ? '' : 'url')
    ..aE<Payload_Compression>(4, _omitFieldNames ? '' : 'compression',
        enumValues: Payload_Compression.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Payload clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Payload copyWith(void Function(Payload) updates) =>
      super.copyWith((message) => updates(message as Payload)) as Payload;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Payload create() => Payload._();
  @$core.override
  Payload createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Payload getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Payload>(create);
  static Payload? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  Payload_Source whichSource() => _Payload_SourceByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  void clearSource() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.String get filePath => $_getSZ(0);
  @$pb.TagNumber(1)
  set filePath($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasFilePath() => $_has(0);
  @$pb.TagNumber(1)
  void clearFilePath() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get data => $_getN(1);
  @$pb.TagNumber(2)
  set data($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasData() => $_has(1);
  @$pb.TagNumber(2)
  void clearData() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get url => $_getSZ(2);
  @$pb.TagNumber(3)
  set url($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasUrl() => $_has(2);
  @$pb.TagNumber(3)
  void clearUrl() => $_clearField(3);

  @$pb.TagNumber(4)
  Payload_Compression get compression => $_getN(3);
  @$pb.TagNumber(4)
  set compression(Payload_Compression value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasCompression() => $_has(3);
  @$pb.TagNumber(4)
  void clearCompression() => $_clearField(4);
}

class ProcessOutput extends $pb.GeneratedMessage {
  factory ProcessOutput({
    ProcessOutput_Interface? interface,
    $core.List<$core.int>? data,
  }) {
    final result = create();
    if (interface != null) result.interface = interface;
    if (data != null) result.data = data;
    return result;
  }

  ProcessOutput._();

  factory ProcessOutput.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ProcessOutput.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ProcessOutput',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<ProcessOutput_Interface>(1, _omitFieldNames ? '' : 'interface',
        enumValues: ProcessOutput_Interface.values)
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ProcessOutput clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ProcessOutput copyWith(void Function(ProcessOutput) updates) =>
      super.copyWith((message) => updates(message as ProcessOutput))
          as ProcessOutput;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ProcessOutput create() => ProcessOutput._();
  @$core.override
  ProcessOutput createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ProcessOutput getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ProcessOutput>(create);
  static ProcessOutput? _defaultInstance;

  @$pb.TagNumber(1)
  ProcessOutput_Interface get interface => $_getN(0);
  @$pb.TagNumber(1)
  set interface(ProcessOutput_Interface value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasInterface() => $_has(0);
  @$pb.TagNumber(1)
  void clearInterface() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get data => $_getN(1);
  @$pb.TagNumber(2)
  set data($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasData() => $_has(1);
  @$pb.TagNumber(2)
  void clearData() => $_clearField(2);
}

class CompanionInfo extends $pb.GeneratedMessage {
  factory CompanionInfo({
    $core.String? udid,
    $core.bool? isLocal,
    $core.List<$core.int>? metadata,
  }) {
    final result = create();
    if (udid != null) result.udid = udid;
    if (isLocal != null) result.isLocal = isLocal;
    if (metadata != null) result.metadata = metadata;
    return result;
  }

  CompanionInfo._();

  factory CompanionInfo.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CompanionInfo.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CompanionInfo',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'udid')
    ..aOB(4, _omitFieldNames ? '' : 'isLocal')
    ..a<$core.List<$core.int>>(
        6, _omitFieldNames ? '' : 'metadata', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CompanionInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CompanionInfo copyWith(void Function(CompanionInfo) updates) =>
      super.copyWith((message) => updates(message as CompanionInfo))
          as CompanionInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CompanionInfo create() => CompanionInfo._();
  @$core.override
  CompanionInfo createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CompanionInfo getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CompanionInfo>(create);
  static CompanionInfo? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get udid => $_getSZ(0);
  @$pb.TagNumber(1)
  set udid($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUdid() => $_has(0);
  @$pb.TagNumber(1)
  void clearUdid() => $_clearField(1);

  @$pb.TagNumber(4)
  $core.bool get isLocal => $_getBF(1);
  @$pb.TagNumber(4)
  set isLocal($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(4)
  $core.bool hasIsLocal() => $_has(1);
  @$pb.TagNumber(4)
  void clearIsLocal() => $_clearField(4);

  @$pb.TagNumber(6)
  $core.List<$core.int> get metadata => $_getN(2);
  @$pb.TagNumber(6)
  set metadata($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(6)
  $core.bool hasMetadata() => $_has(2);
  @$pb.TagNumber(6)
  void clearMetadata() => $_clearField(6);
}

class SettingRequest_HardwareKeyboard extends $pb.GeneratedMessage {
  factory SettingRequest_HardwareKeyboard({
    $core.bool? enabled,
  }) {
    final result = create();
    if (enabled != null) result.enabled = enabled;
    return result;
  }

  SettingRequest_HardwareKeyboard._();

  factory SettingRequest_HardwareKeyboard.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SettingRequest_HardwareKeyboard.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SettingRequest.HardwareKeyboard',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'enabled')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SettingRequest_HardwareKeyboard clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SettingRequest_HardwareKeyboard copyWith(
          void Function(SettingRequest_HardwareKeyboard) updates) =>
      super.copyWith(
              (message) => updates(message as SettingRequest_HardwareKeyboard))
          as SettingRequest_HardwareKeyboard;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SettingRequest_HardwareKeyboard create() =>
      SettingRequest_HardwareKeyboard._();
  @$core.override
  SettingRequest_HardwareKeyboard createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SettingRequest_HardwareKeyboard getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SettingRequest_HardwareKeyboard>(
          create);
  static SettingRequest_HardwareKeyboard? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get enabled => $_getBF(0);
  @$pb.TagNumber(1)
  set enabled($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasEnabled() => $_has(0);
  @$pb.TagNumber(1)
  void clearEnabled() => $_clearField(1);
}

class SettingRequest_StringSetting extends $pb.GeneratedMessage {
  factory SettingRequest_StringSetting({
    Setting? setting,
    $core.String? value,
    $core.String? name,
    $core.String? domain,
    $core.String? valueType,
  }) {
    final result = create();
    if (setting != null) result.setting = setting;
    if (value != null) result.value = value;
    if (name != null) result.name = name;
    if (domain != null) result.domain = domain;
    if (valueType != null) result.valueType = valueType;
    return result;
  }

  SettingRequest_StringSetting._();

  factory SettingRequest_StringSetting.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SettingRequest_StringSetting.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SettingRequest.StringSetting',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<Setting>(1, _omitFieldNames ? '' : 'setting',
        enumValues: Setting.values)
    ..aOS(2, _omitFieldNames ? '' : 'value')
    ..aOS(3, _omitFieldNames ? '' : 'name')
    ..aOS(4, _omitFieldNames ? '' : 'domain')
    ..aOS(5, _omitFieldNames ? '' : 'valueType')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SettingRequest_StringSetting clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SettingRequest_StringSetting copyWith(
          void Function(SettingRequest_StringSetting) updates) =>
      super.copyWith(
              (message) => updates(message as SettingRequest_StringSetting))
          as SettingRequest_StringSetting;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SettingRequest_StringSetting create() =>
      SettingRequest_StringSetting._();
  @$core.override
  SettingRequest_StringSetting createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SettingRequest_StringSetting getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SettingRequest_StringSetting>(create);
  static SettingRequest_StringSetting? _defaultInstance;

  @$pb.TagNumber(1)
  Setting get setting => $_getN(0);
  @$pb.TagNumber(1)
  set setting(Setting value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasSetting() => $_has(0);
  @$pb.TagNumber(1)
  void clearSetting() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get value => $_getSZ(1);
  @$pb.TagNumber(2)
  set value($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearValue() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get name => $_getSZ(2);
  @$pb.TagNumber(3)
  set name($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasName() => $_has(2);
  @$pb.TagNumber(3)
  void clearName() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get domain => $_getSZ(3);
  @$pb.TagNumber(4)
  set domain($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasDomain() => $_has(3);
  @$pb.TagNumber(4)
  void clearDomain() => $_clearField(4);

  ///
  ///  Currently supported value_types and corresponding values are:
  ///   string <string_value>
  ///   data <hex_digits>
  ///   int[eger] <integer_value>
  ///   float  <floating-point_value>
  ///   bool[ean] (true | false | yes | no)
  ///   date <date_rep>
  ///   array <value1> <value2> ...
  ///   array-add <value1> <value2> ...
  ///   dict <key1> <value1> <key2> <value2> ...
  ///   dict-add <key1> <value1> ...
  ///
  ///  Check defaults set help for more details.
  @$pb.TagNumber(5)
  $core.String get valueType => $_getSZ(4);
  @$pb.TagNumber(5)
  set valueType($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasValueType() => $_has(4);
  @$pb.TagNumber(5)
  void clearValueType() => $_clearField(5);
}

enum SettingRequest_Setting { hardwareKeyboard, stringSetting, notSet }

class SettingRequest extends $pb.GeneratedMessage {
  factory SettingRequest({
    SettingRequest_HardwareKeyboard? hardwareKeyboard,
    SettingRequest_StringSetting? stringSetting,
  }) {
    final result = create();
    if (hardwareKeyboard != null) result.hardwareKeyboard = hardwareKeyboard;
    if (stringSetting != null) result.stringSetting = stringSetting;
    return result;
  }

  SettingRequest._();

  factory SettingRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SettingRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, SettingRequest_Setting>
      _SettingRequest_SettingByTag = {
    1: SettingRequest_Setting.hardwareKeyboard,
    2: SettingRequest_Setting.stringSetting,
    0: SettingRequest_Setting.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SettingRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOM<SettingRequest_HardwareKeyboard>(
        1, _omitFieldNames ? '' : 'hardwareKeyboard',
        protoName: 'hardwareKeyboard',
        subBuilder: SettingRequest_HardwareKeyboard.create)
    ..aOM<SettingRequest_StringSetting>(
        2, _omitFieldNames ? '' : 'stringSetting',
        protoName: 'stringSetting',
        subBuilder: SettingRequest_StringSetting.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SettingRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SettingRequest copyWith(void Function(SettingRequest) updates) =>
      super.copyWith((message) => updates(message as SettingRequest))
          as SettingRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SettingRequest create() => SettingRequest._();
  @$core.override
  SettingRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SettingRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SettingRequest>(create);
  static SettingRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  SettingRequest_Setting whichSetting() =>
      _SettingRequest_SettingByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearSetting() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  SettingRequest_HardwareKeyboard get hardwareKeyboard => $_getN(0);
  @$pb.TagNumber(1)
  set hardwareKeyboard(SettingRequest_HardwareKeyboard value) =>
      $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasHardwareKeyboard() => $_has(0);
  @$pb.TagNumber(1)
  void clearHardwareKeyboard() => $_clearField(1);
  @$pb.TagNumber(1)
  SettingRequest_HardwareKeyboard ensureHardwareKeyboard() => $_ensure(0);

  @$pb.TagNumber(2)
  SettingRequest_StringSetting get stringSetting => $_getN(1);
  @$pb.TagNumber(2)
  set stringSetting(SettingRequest_StringSetting value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStringSetting() => $_has(1);
  @$pb.TagNumber(2)
  void clearStringSetting() => $_clearField(2);
  @$pb.TagNumber(2)
  SettingRequest_StringSetting ensureStringSetting() => $_ensure(1);
}

class SettingResponse extends $pb.GeneratedMessage {
  factory SettingResponse() => create();

  SettingResponse._();

  factory SettingResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SettingResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SettingResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SettingResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SettingResponse copyWith(void Function(SettingResponse) updates) =>
      super.copyWith((message) => updates(message as SettingResponse))
          as SettingResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SettingResponse create() => SettingResponse._();
  @$core.override
  SettingResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SettingResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SettingResponse>(create);
  static SettingResponse? _defaultInstance;
}

class GetSettingRequest extends $pb.GeneratedMessage {
  factory GetSettingRequest({
    Setting? setting,
    $core.String? name,
    $core.String? domain,
  }) {
    final result = create();
    if (setting != null) result.setting = setting;
    if (name != null) result.name = name;
    if (domain != null) result.domain = domain;
    return result;
  }

  GetSettingRequest._();

  factory GetSettingRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GetSettingRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetSettingRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<Setting>(1, _omitFieldNames ? '' : 'setting',
        enumValues: Setting.values)
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aOS(3, _omitFieldNames ? '' : 'domain')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetSettingRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetSettingRequest copyWith(void Function(GetSettingRequest) updates) =>
      super.copyWith((message) => updates(message as GetSettingRequest))
          as GetSettingRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetSettingRequest create() => GetSettingRequest._();
  @$core.override
  GetSettingRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetSettingRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetSettingRequest>(create);
  static GetSettingRequest? _defaultInstance;

  @$pb.TagNumber(1)
  Setting get setting => $_getN(0);
  @$pb.TagNumber(1)
  set setting(Setting value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasSetting() => $_has(0);
  @$pb.TagNumber(1)
  void clearSetting() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get domain => $_getSZ(2);
  @$pb.TagNumber(3)
  set domain($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDomain() => $_has(2);
  @$pb.TagNumber(3)
  void clearDomain() => $_clearField(3);
}

class GetSettingResponse extends $pb.GeneratedMessage {
  factory GetSettingResponse({
    $core.String? value,
  }) {
    final result = create();
    if (value != null) result.value = value;
    return result;
  }

  GetSettingResponse._();

  factory GetSettingResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GetSettingResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetSettingResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'value')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetSettingResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetSettingResponse copyWith(void Function(GetSettingResponse) updates) =>
      super.copyWith((message) => updates(message as GetSettingResponse))
          as GetSettingResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetSettingResponse create() => GetSettingResponse._();
  @$core.override
  GetSettingResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetSettingResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetSettingResponse>(create);
  static GetSettingResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get value => $_getSZ(0);
  @$pb.TagNumber(1)
  set value($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearValue() => $_clearField(1);
}

class ListSettingRequest extends $pb.GeneratedMessage {
  factory ListSettingRequest({
    Setting? setting,
  }) {
    final result = create();
    if (setting != null) result.setting = setting;
    return result;
  }

  ListSettingRequest._();

  factory ListSettingRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ListSettingRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListSettingRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<Setting>(1, _omitFieldNames ? '' : 'setting',
        enumValues: Setting.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListSettingRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListSettingRequest copyWith(void Function(ListSettingRequest) updates) =>
      super.copyWith((message) => updates(message as ListSettingRequest))
          as ListSettingRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ListSettingRequest create() => ListSettingRequest._();
  @$core.override
  ListSettingRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ListSettingRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListSettingRequest>(create);
  static ListSettingRequest? _defaultInstance;

  @$pb.TagNumber(1)
  Setting get setting => $_getN(0);
  @$pb.TagNumber(1)
  set setting(Setting value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasSetting() => $_has(0);
  @$pb.TagNumber(1)
  void clearSetting() => $_clearField(1);
}

class ListSettingResponse extends $pb.GeneratedMessage {
  factory ListSettingResponse({
    $core.Iterable<$core.String>? values,
  }) {
    final result = create();
    if (values != null) result.values.addAll(values);
    return result;
  }

  ListSettingResponse._();

  factory ListSettingResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ListSettingResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListSettingResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPS(1, _omitFieldNames ? '' : 'values')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListSettingResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListSettingResponse copyWith(void Function(ListSettingResponse) updates) =>
      super.copyWith((message) => updates(message as ListSettingResponse))
          as ListSettingResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ListSettingResponse create() => ListSettingResponse._();
  @$core.override
  ListSettingResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ListSettingResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListSettingResponse>(create);
  static ListSettingResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get values => $_getList(0);
}

class ListAppsRequest extends $pb.GeneratedMessage {
  factory ListAppsRequest({
    $core.bool? suppressProcessState,
  }) {
    final result = create();
    if (suppressProcessState != null)
      result.suppressProcessState = suppressProcessState;
    return result;
  }

  ListAppsRequest._();

  factory ListAppsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ListAppsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListAppsRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'suppressProcessState')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListAppsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListAppsRequest copyWith(void Function(ListAppsRequest) updates) =>
      super.copyWith((message) => updates(message as ListAppsRequest))
          as ListAppsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ListAppsRequest create() => ListAppsRequest._();
  @$core.override
  ListAppsRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ListAppsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListAppsRequest>(create);
  static ListAppsRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get suppressProcessState => $_getBF(0);
  @$pb.TagNumber(1)
  set suppressProcessState($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSuppressProcessState() => $_has(0);
  @$pb.TagNumber(1)
  void clearSuppressProcessState() => $_clearField(1);
}

class ListAppsResponse extends $pb.GeneratedMessage {
  factory ListAppsResponse({
    $core.Iterable<InstalledAppInfo>? apps,
  }) {
    final result = create();
    if (apps != null) result.apps.addAll(apps);
    return result;
  }

  ListAppsResponse._();

  factory ListAppsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ListAppsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListAppsResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPM<InstalledAppInfo>(1, _omitFieldNames ? '' : 'apps',
        subBuilder: InstalledAppInfo.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListAppsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListAppsResponse copyWith(void Function(ListAppsResponse) updates) =>
      super.copyWith((message) => updates(message as ListAppsResponse))
          as ListAppsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ListAppsResponse create() => ListAppsResponse._();
  @$core.override
  ListAppsResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ListAppsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListAppsResponse>(create);
  static ListAppsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<InstalledAppInfo> get apps => $_getList(0);
}

class InstalledAppInfo extends $pb.GeneratedMessage {
  factory InstalledAppInfo({
    $core.String? bundleId,
    $core.String? name,
    $core.Iterable<$core.String>? architectures,
    $core.String? installType,
    InstalledAppInfo_AppProcessState? processState,
    $core.bool? debuggable,
    $fixnum.Int64? processIdentifier,
  }) {
    final result = create();
    if (bundleId != null) result.bundleId = bundleId;
    if (name != null) result.name = name;
    if (architectures != null) result.architectures.addAll(architectures);
    if (installType != null) result.installType = installType;
    if (processState != null) result.processState = processState;
    if (debuggable != null) result.debuggable = debuggable;
    if (processIdentifier != null) result.processIdentifier = processIdentifier;
    return result;
  }

  InstalledAppInfo._();

  factory InstalledAppInfo.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory InstalledAppInfo.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InstalledAppInfo',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'bundleId')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..pPS(3, _omitFieldNames ? '' : 'architectures')
    ..aOS(4, _omitFieldNames ? '' : 'installType')
    ..aE<InstalledAppInfo_AppProcessState>(
        5, _omitFieldNames ? '' : 'processState',
        enumValues: InstalledAppInfo_AppProcessState.values)
    ..aOB(6, _omitFieldNames ? '' : 'debuggable')
    ..a<$fixnum.Int64>(
        7, _omitFieldNames ? '' : 'processIdentifier', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstalledAppInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstalledAppInfo copyWith(void Function(InstalledAppInfo) updates) =>
      super.copyWith((message) => updates(message as InstalledAppInfo))
          as InstalledAppInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static InstalledAppInfo create() => InstalledAppInfo._();
  @$core.override
  InstalledAppInfo createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static InstalledAppInfo getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<InstalledAppInfo>(create);
  static InstalledAppInfo? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get bundleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set bundleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBundleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBundleId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get architectures => $_getList(2);

  @$pb.TagNumber(4)
  $core.String get installType => $_getSZ(3);
  @$pb.TagNumber(4)
  set installType($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasInstallType() => $_has(3);
  @$pb.TagNumber(4)
  void clearInstallType() => $_clearField(4);

  @$pb.TagNumber(5)
  InstalledAppInfo_AppProcessState get processState => $_getN(4);
  @$pb.TagNumber(5)
  set processState(InstalledAppInfo_AppProcessState value) =>
      $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasProcessState() => $_has(4);
  @$pb.TagNumber(5)
  void clearProcessState() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.bool get debuggable => $_getBF(5);
  @$pb.TagNumber(6)
  set debuggable($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasDebuggable() => $_has(5);
  @$pb.TagNumber(6)
  void clearDebuggable() => $_clearField(6);

  @$pb.TagNumber(7)
  $fixnum.Int64 get processIdentifier => $_getI64(6);
  @$pb.TagNumber(7)
  set processIdentifier($fixnum.Int64 value) => $_setInt64(6, value);
  @$pb.TagNumber(7)
  $core.bool hasProcessIdentifier() => $_has(6);
  @$pb.TagNumber(7)
  void clearProcessIdentifier() => $_clearField(7);
}

class InstallRequest_LinkDsymToBundle extends $pb.GeneratedMessage {
  factory InstallRequest_LinkDsymToBundle({
    InstallRequest_LinkDsymToBundle_BundleType? bundleType,
    $core.String? bundleId,
  }) {
    final result = create();
    if (bundleType != null) result.bundleType = bundleType;
    if (bundleId != null) result.bundleId = bundleId;
    return result;
  }

  InstallRequest_LinkDsymToBundle._();

  factory InstallRequest_LinkDsymToBundle.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory InstallRequest_LinkDsymToBundle.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InstallRequest.LinkDsymToBundle',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<InstallRequest_LinkDsymToBundle_BundleType>(
        1, _omitFieldNames ? '' : 'bundleType',
        enumValues: InstallRequest_LinkDsymToBundle_BundleType.values)
    ..aOS(2, _omitFieldNames ? '' : 'bundleId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstallRequest_LinkDsymToBundle clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstallRequest_LinkDsymToBundle copyWith(
          void Function(InstallRequest_LinkDsymToBundle) updates) =>
      super.copyWith(
              (message) => updates(message as InstallRequest_LinkDsymToBundle))
          as InstallRequest_LinkDsymToBundle;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static InstallRequest_LinkDsymToBundle create() =>
      InstallRequest_LinkDsymToBundle._();
  @$core.override
  InstallRequest_LinkDsymToBundle createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static InstallRequest_LinkDsymToBundle getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<InstallRequest_LinkDsymToBundle>(
          create);
  static InstallRequest_LinkDsymToBundle? _defaultInstance;

  @$pb.TagNumber(1)
  InstallRequest_LinkDsymToBundle_BundleType get bundleType => $_getN(0);
  @$pb.TagNumber(1)
  set bundleType(InstallRequest_LinkDsymToBundle_BundleType value) =>
      $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasBundleType() => $_has(0);
  @$pb.TagNumber(1)
  void clearBundleType() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get bundleId => $_getSZ(1);
  @$pb.TagNumber(2)
  set bundleId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBundleId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBundleId() => $_clearField(2);
}

enum InstallRequest_Value {
  destination,
  payload,
  nameHint,
  makeDebuggable,
  bundleId,
  linkDsymToBundle,
  overrideModificationTime,
  skipSigningBundles,
  notSet
}

class InstallRequest extends $pb.GeneratedMessage {
  factory InstallRequest({
    InstallRequest_Destination? destination,
    Payload? payload,
    $core.String? nameHint,
    $core.bool? makeDebuggable,
    $core.String? bundleId,
    InstallRequest_LinkDsymToBundle? linkDsymToBundle,
    $core.bool? overrideModificationTime,
    $core.bool? skipSigningBundles,
  }) {
    final result = create();
    if (destination != null) result.destination = destination;
    if (payload != null) result.payload = payload;
    if (nameHint != null) result.nameHint = nameHint;
    if (makeDebuggable != null) result.makeDebuggable = makeDebuggable;
    if (bundleId != null) result.bundleId = bundleId;
    if (linkDsymToBundle != null) result.linkDsymToBundle = linkDsymToBundle;
    if (overrideModificationTime != null)
      result.overrideModificationTime = overrideModificationTime;
    if (skipSigningBundles != null)
      result.skipSigningBundles = skipSigningBundles;
    return result;
  }

  InstallRequest._();

  factory InstallRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory InstallRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, InstallRequest_Value>
      _InstallRequest_ValueByTag = {
    1: InstallRequest_Value.destination,
    2: InstallRequest_Value.payload,
    3: InstallRequest_Value.nameHint,
    4: InstallRequest_Value.makeDebuggable,
    5: InstallRequest_Value.bundleId,
    6: InstallRequest_Value.linkDsymToBundle,
    7: InstallRequest_Value.overrideModificationTime,
    8: InstallRequest_Value.skipSigningBundles,
    0: InstallRequest_Value.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InstallRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3, 4, 5, 6, 7, 8])
    ..aE<InstallRequest_Destination>(1, _omitFieldNames ? '' : 'destination',
        enumValues: InstallRequest_Destination.values)
    ..aOM<Payload>(2, _omitFieldNames ? '' : 'payload',
        subBuilder: Payload.create)
    ..aOS(3, _omitFieldNames ? '' : 'nameHint')
    ..aOB(4, _omitFieldNames ? '' : 'makeDebuggable')
    ..aOS(5, _omitFieldNames ? '' : 'bundleId')
    ..aOM<InstallRequest_LinkDsymToBundle>(
        6, _omitFieldNames ? '' : 'linkDsymToBundle',
        subBuilder: InstallRequest_LinkDsymToBundle.create)
    ..aOB(7, _omitFieldNames ? '' : 'overrideModificationTime')
    ..aOB(8, _omitFieldNames ? '' : 'skipSigningBundles')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstallRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstallRequest copyWith(void Function(InstallRequest) updates) =>
      super.copyWith((message) => updates(message as InstallRequest))
          as InstallRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static InstallRequest create() => InstallRequest._();
  @$core.override
  InstallRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static InstallRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<InstallRequest>(create);
  static InstallRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  InstallRequest_Value whichValue() =>
      _InstallRequest_ValueByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  void clearValue() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  InstallRequest_Destination get destination => $_getN(0);
  @$pb.TagNumber(1)
  set destination(InstallRequest_Destination value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasDestination() => $_has(0);
  @$pb.TagNumber(1)
  void clearDestination() => $_clearField(1);

  @$pb.TagNumber(2)
  Payload get payload => $_getN(1);
  @$pb.TagNumber(2)
  set payload(Payload value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPayload() => $_has(1);
  @$pb.TagNumber(2)
  void clearPayload() => $_clearField(2);
  @$pb.TagNumber(2)
  Payload ensurePayload() => $_ensure(1);

  @$pb.TagNumber(3)
  $core.String get nameHint => $_getSZ(2);
  @$pb.TagNumber(3)
  set nameHint($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNameHint() => $_has(2);
  @$pb.TagNumber(3)
  void clearNameHint() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get makeDebuggable => $_getBF(3);
  @$pb.TagNumber(4)
  set makeDebuggable($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMakeDebuggable() => $_has(3);
  @$pb.TagNumber(4)
  void clearMakeDebuggable() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get bundleId => $_getSZ(4);
  @$pb.TagNumber(5)
  set bundleId($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasBundleId() => $_has(4);
  @$pb.TagNumber(5)
  void clearBundleId() => $_clearField(5);

  /// Link dSYM to app bundle_id
  @$pb.TagNumber(6)
  InstallRequest_LinkDsymToBundle get linkDsymToBundle => $_getN(5);
  @$pb.TagNumber(6)
  set linkDsymToBundle(InstallRequest_LinkDsymToBundle value) =>
      $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasLinkDsymToBundle() => $_has(5);
  @$pb.TagNumber(6)
  void clearLinkDsymToBundle() => $_clearField(6);
  @$pb.TagNumber(6)
  InstallRequest_LinkDsymToBundle ensureLinkDsymToBundle() => $_ensure(5);

  @$pb.TagNumber(7)
  $core.bool get overrideModificationTime => $_getBF(6);
  @$pb.TagNumber(7)
  set overrideModificationTime($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasOverrideModificationTime() => $_has(6);
  @$pb.TagNumber(7)
  void clearOverrideModificationTime() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.bool get skipSigningBundles => $_getBF(7);
  @$pb.TagNumber(8)
  set skipSigningBundles($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasSkipSigningBundles() => $_has(7);
  @$pb.TagNumber(8)
  void clearSkipSigningBundles() => $_clearField(8);
}

class InstallResponse extends $pb.GeneratedMessage {
  factory InstallResponse({
    $core.String? name,
    $core.String? uuid,
    $core.double? progress,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (uuid != null) result.uuid = uuid;
    if (progress != null) result.progress = progress;
    return result;
  }

  InstallResponse._();

  factory InstallResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory InstallResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InstallResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'uuid')
    ..aD(3, _omitFieldNames ? '' : 'progress')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstallResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstallResponse copyWith(void Function(InstallResponse) updates) =>
      super.copyWith((message) => updates(message as InstallResponse))
          as InstallResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static InstallResponse create() => InstallResponse._();
  @$core.override
  InstallResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static InstallResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<InstallResponse>(create);
  static InstallResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get uuid => $_getSZ(1);
  @$pb.TagNumber(2)
  set uuid($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUuid() => $_has(1);
  @$pb.TagNumber(2)
  void clearUuid() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get progress => $_getN(2);
  @$pb.TagNumber(3)
  set progress($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasProgress() => $_has(2);
  @$pb.TagNumber(3)
  void clearProgress() => $_clearField(3);
}

/// Top-left origin, matching the tap/swipe coordinate space. A rect that
/// partially overhangs the screen is clamped; the response reports the
/// dimensions actually captured.
class ScreenshotRequest_Rect extends $pb.GeneratedMessage {
  factory ScreenshotRequest_Rect({
    $core.double? x,
    $core.double? y,
    $core.double? width,
    $core.double? height,
  }) {
    final result = create();
    if (x != null) result.x = x;
    if (y != null) result.y = y;
    if (width != null) result.width = width;
    if (height != null) result.height = height;
    return result;
  }

  ScreenshotRequest_Rect._();

  factory ScreenshotRequest_Rect.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ScreenshotRequest_Rect.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ScreenshotRequest.Rect',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aD(1, _omitFieldNames ? '' : 'x')
    ..aD(2, _omitFieldNames ? '' : 'y')
    ..aD(3, _omitFieldNames ? '' : 'width')
    ..aD(4, _omitFieldNames ? '' : 'height')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenshotRequest_Rect clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenshotRequest_Rect copyWith(
          void Function(ScreenshotRequest_Rect) updates) =>
      super.copyWith((message) => updates(message as ScreenshotRequest_Rect))
          as ScreenshotRequest_Rect;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ScreenshotRequest_Rect create() => ScreenshotRequest_Rect._();
  @$core.override
  ScreenshotRequest_Rect createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ScreenshotRequest_Rect getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ScreenshotRequest_Rect>(create);
  static ScreenshotRequest_Rect? _defaultInstance;

  @$pb.TagNumber(1)
  $core.double get x => $_getN(0);
  @$pb.TagNumber(1)
  set x($core.double value) => $_setDouble(0, value);
  @$pb.TagNumber(1)
  $core.bool hasX() => $_has(0);
  @$pb.TagNumber(1)
  void clearX() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.double get y => $_getN(1);
  @$pb.TagNumber(2)
  set y($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasY() => $_has(1);
  @$pb.TagNumber(2)
  void clearY() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get width => $_getN(2);
  @$pb.TagNumber(3)
  set width($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasWidth() => $_has(2);
  @$pb.TagNumber(3)
  void clearWidth() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.double get height => $_getN(3);
  @$pb.TagNumber(4)
  set height($core.double value) => $_setDouble(3, value);
  @$pb.TagNumber(4)
  $core.bool hasHeight() => $_has(3);
  @$pb.TagNumber(4)
  void clearHeight() => $_clearField(4);
}

/// Bounding box the image is scaled to fit inside. One factor is applied to
/// both axes and the image is never upscaled, so the aspect ratio is
/// preserved to within the rounding of each side to a whole pixel -- a few
/// percent on a very small image. 0 means "unbounded" on that axis; when both
/// are set, the more restrictive bound wins.
class ScreenshotRequest_Fit extends $pb.GeneratedMessage {
  factory ScreenshotRequest_Fit({
    $core.int? maxWidth,
    $core.int? maxHeight,
  }) {
    final result = create();
    if (maxWidth != null) result.maxWidth = maxWidth;
    if (maxHeight != null) result.maxHeight = maxHeight;
    return result;
  }

  ScreenshotRequest_Fit._();

  factory ScreenshotRequest_Fit.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ScreenshotRequest_Fit.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ScreenshotRequest.Fit',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'maxWidth', fieldType: $pb.PbFieldType.OU3)
    ..aI(2, _omitFieldNames ? '' : 'maxHeight', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenshotRequest_Fit clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenshotRequest_Fit copyWith(
          void Function(ScreenshotRequest_Fit) updates) =>
      super.copyWith((message) => updates(message as ScreenshotRequest_Fit))
          as ScreenshotRequest_Fit;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ScreenshotRequest_Fit create() => ScreenshotRequest_Fit._();
  @$core.override
  ScreenshotRequest_Fit createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ScreenshotRequest_Fit getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ScreenshotRequest_Fit>(create);
  static ScreenshotRequest_Fit? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get maxWidth => $_getIZ(0);
  @$pb.TagNumber(1)
  set maxWidth($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMaxWidth() => $_has(0);
  @$pb.TagNumber(1)
  void clearMaxWidth() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get maxHeight => $_getIZ(1);
  @$pb.TagNumber(2)
  set maxHeight($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMaxHeight() => $_has(1);
  @$pb.TagNumber(2)
  void clearMaxHeight() => $_clearField(2);
}

enum ScreenshotRequest_Scale { scaleFactor, fit, notSet }

class ScreenshotRequest extends $pb.GeneratedMessage {
  factory ScreenshotRequest({
    ScreenshotRequest_Format? format,
    $core.double? compressionQuality,
    ScreenshotRequest_Rect? crop,
    $core.double? scaleFactor,
    ScreenshotRequest_Fit? fit,
    ScreenshotRequest_Unit? unit,
  }) {
    final result = create();
    if (format != null) result.format = format;
    if (compressionQuality != null)
      result.compressionQuality = compressionQuality;
    if (crop != null) result.crop = crop;
    if (scaleFactor != null) result.scaleFactor = scaleFactor;
    if (fit != null) result.fit = fit;
    if (unit != null) result.unit = unit;
    return result;
  }

  ScreenshotRequest._();

  factory ScreenshotRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ScreenshotRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ScreenshotRequest_Scale>
      _ScreenshotRequest_ScaleByTag = {
    4: ScreenshotRequest_Scale.scaleFactor,
    5: ScreenshotRequest_Scale.fit,
    0: ScreenshotRequest_Scale.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ScreenshotRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [4, 5])
    ..aE<ScreenshotRequest_Format>(1, _omitFieldNames ? '' : 'format',
        enumValues: ScreenshotRequest_Format.values)
    ..aD(2, _omitFieldNames ? '' : 'compressionQuality')
    ..aOM<ScreenshotRequest_Rect>(3, _omitFieldNames ? '' : 'crop',
        subBuilder: ScreenshotRequest_Rect.create)
    ..aD(4, _omitFieldNames ? '' : 'scaleFactor')
    ..aOM<ScreenshotRequest_Fit>(5, _omitFieldNames ? '' : 'fit',
        subBuilder: ScreenshotRequest_Fit.create)
    ..aE<ScreenshotRequest_Unit>(6, _omitFieldNames ? '' : 'unit',
        enumValues: ScreenshotRequest_Unit.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenshotRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenshotRequest copyWith(void Function(ScreenshotRequest) updates) =>
      super.copyWith((message) => updates(message as ScreenshotRequest))
          as ScreenshotRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ScreenshotRequest create() => ScreenshotRequest._();
  @$core.override
  ScreenshotRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ScreenshotRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ScreenshotRequest>(create);
  static ScreenshotRequest? _defaultInstance;

  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  ScreenshotRequest_Scale whichScale() =>
      _ScreenshotRequest_ScaleByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  void clearScale() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  ScreenshotRequest_Format get format => $_getN(0);
  @$pb.TagNumber(1)
  set format(ScreenshotRequest_Format value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasFormat() => $_has(0);
  @$pb.TagNumber(1)
  void clearFormat() => $_clearField(1);

  /// Lossy formats only; 0 means "server default" (0.8), as in
  /// VideoStreamRequest. Setting this on PNG or TIFF is an INVALID_ARGUMENT
  /// error rather than a no-op.
  @$pb.TagNumber(2)
  $core.double get compressionQuality => $_getN(1);
  @$pb.TagNumber(2)
  set compressionQuality($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCompressionQuality() => $_has(1);
  @$pb.TagNumber(2)
  void clearCompressionQuality() => $_clearField(2);

  /// Unset captures the full screen.
  @$pb.TagNumber(3)
  ScreenshotRequest_Rect get crop => $_getN(2);
  @$pb.TagNumber(3)
  set crop(ScreenshotRequest_Rect value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasCrop() => $_has(2);
  @$pb.TagNumber(3)
  void clearCrop() => $_clearField(3);
  @$pb.TagNumber(3)
  ScreenshotRequest_Rect ensureCrop() => $_ensure(2);

  /// In (0, 1].
  @$pb.TagNumber(4)
  $core.double get scaleFactor => $_getN(3);
  @$pb.TagNumber(4)
  set scaleFactor($core.double value) => $_setDouble(3, value);
  @$pb.TagNumber(4)
  $core.bool hasScaleFactor() => $_has(3);
  @$pb.TagNumber(4)
  void clearScaleFactor() => $_clearField(4);

  @$pb.TagNumber(5)
  ScreenshotRequest_Fit get fit => $_getN(4);
  @$pb.TagNumber(5)
  set fit(ScreenshotRequest_Fit value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasFit() => $_has(4);
  @$pb.TagNumber(5)
  void clearFit() => $_clearField(5);
  @$pb.TagNumber(5)
  ScreenshotRequest_Fit ensureFit() => $_ensure(4);

  @$pb.TagNumber(6)
  ScreenshotRequest_Unit get unit => $_getN(5);
  @$pb.TagNumber(6)
  set unit(ScreenshotRequest_Unit value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasUnit() => $_has(5);
  @$pb.TagNumber(6)
  void clearUnit() => $_clearField(6);
}

/// Pixels. A measurement is never legitimately 0, so 0 on either axis is the
/// companion saying it did not report one rather than an image of no height.
class ScreenshotResponse_Size extends $pb.GeneratedMessage {
  factory ScreenshotResponse_Size({
    $core.int? width,
    $core.int? height,
  }) {
    final result = create();
    if (width != null) result.width = width;
    if (height != null) result.height = height;
    return result;
  }

  ScreenshotResponse_Size._();

  factory ScreenshotResponse_Size.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ScreenshotResponse_Size.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ScreenshotResponse.Size',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'width', fieldType: $pb.PbFieldType.OU3)
    ..aI(2, _omitFieldNames ? '' : 'height', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenshotResponse_Size clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenshotResponse_Size copyWith(
          void Function(ScreenshotResponse_Size) updates) =>
      super.copyWith((message) => updates(message as ScreenshotResponse_Size))
          as ScreenshotResponse_Size;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ScreenshotResponse_Size create() => ScreenshotResponse_Size._();
  @$core.override
  ScreenshotResponse_Size createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ScreenshotResponse_Size getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ScreenshotResponse_Size>(create);
  static ScreenshotResponse_Size? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get width => $_getIZ(0);
  @$pb.TagNumber(1)
  set width($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasWidth() => $_has(0);
  @$pb.TagNumber(1)
  void clearWidth() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get height => $_getIZ(1);
  @$pb.TagNumber(2)
  set height($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasHeight() => $_has(1);
  @$pb.TagNumber(2)
  void clearHeight() => $_clearField(2);
}

class ScreenshotResponse extends $pb.GeneratedMessage {
  factory ScreenshotResponse({
    $core.List<$core.int>? imageData,
    $core.String? imageFormat,
    ScreenshotResponse_Size? destination,
    ScreenshotResponse_Size? source,
    $core.double? screenScale,
  }) {
    final result = create();
    if (imageData != null) result.imageData = imageData;
    if (imageFormat != null) result.imageFormat = imageFormat;
    if (destination != null) result.destination = destination;
    if (source != null) result.source = source;
    if (screenScale != null) result.screenScale = screenScale;
    return result;
  }

  ScreenshotResponse._();

  factory ScreenshotResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ScreenshotResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ScreenshotResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'imageData', $pb.PbFieldType.OY)
    ..aOS(2, _omitFieldNames ? '' : 'imageFormat')
    ..aOM<ScreenshotResponse_Size>(3, _omitFieldNames ? '' : 'destination',
        subBuilder: ScreenshotResponse_Size.create)
    ..aOM<ScreenshotResponse_Size>(4, _omitFieldNames ? '' : 'source',
        subBuilder: ScreenshotResponse_Size.create)
    ..aD(5, _omitFieldNames ? '' : 'screenScale')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenshotResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenshotResponse copyWith(void Function(ScreenshotResponse) updates) =>
      super.copyWith((message) => updates(message as ScreenshotResponse))
          as ScreenshotResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ScreenshotResponse create() => ScreenshotResponse._();
  @$core.override
  ScreenshotResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ScreenshotResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ScreenshotResponse>(create);
  static ScreenshotResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get imageData => $_getN(0);
  @$pb.TagNumber(1)
  set imageData($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasImageData() => $_has(0);
  @$pb.TagNumber(1)
  void clearImageData() => $_clearField(1);

  /// One of "png", "jpeg" or "tiff". Declared since this message was written
  /// but never populated before the request gained fields. A companion that
  /// leaves this empty predates that change and has silently ignored every
  /// field of ScreenshotRequest.
  @$pb.TagNumber(2)
  $core.String get imageFormat => $_getSZ(1);
  @$pb.TagNumber(2)
  set imageFormat($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasImageFormat() => $_has(1);
  @$pb.TagNumber(2)
  void clearImageFormat() => $_clearField(2);

  /// Dimensions of image_data, after crop and scale.
  @$pb.TagNumber(3)
  ScreenshotResponse_Size get destination => $_getN(2);
  @$pb.TagNumber(3)
  set destination(ScreenshotResponse_Size value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasDestination() => $_has(2);
  @$pb.TagNumber(3)
  void clearDestination() => $_clearField(3);
  @$pb.TagNumber(3)
  ScreenshotResponse_Size ensureDestination() => $_ensure(2);

  /// Dimensions of the native capture, before crop and scale.
  @$pb.TagNumber(4)
  ScreenshotResponse_Size get source => $_getN(3);
  @$pb.TagNumber(4)
  set source(ScreenshotResponse_Size value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasSource() => $_has(3);
  @$pb.TagNumber(4)
  void clearSource() => $_clearField(4);
  @$pb.TagNumber(4)
  ScreenshotResponse_Size ensureSource() => $_ensure(3);

  /// Pixels per point, so a client can convert between the two units itself.
  /// 0 when the target does not report a screen scale, which is also when a
  /// request in POINTS is rejected.
  @$pb.TagNumber(5)
  $core.double get screenScale => $_getN(4);
  @$pb.TagNumber(5)
  set screenScale($core.double value) => $_setDouble(4, value);
  @$pb.TagNumber(5)
  $core.bool hasScreenScale() => $_has(4);
  @$pb.TagNumber(5)
  void clearScreenScale() => $_clearField(5);
}

class FocusRequest extends $pb.GeneratedMessage {
  factory FocusRequest() => create();

  FocusRequest._();

  factory FocusRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FocusRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FocusRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FocusRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FocusRequest copyWith(void Function(FocusRequest) updates) =>
      super.copyWith((message) => updates(message as FocusRequest))
          as FocusRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FocusRequest create() => FocusRequest._();
  @$core.override
  FocusRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FocusRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FocusRequest>(create);
  static FocusRequest? _defaultInstance;
}

class FocusResponse extends $pb.GeneratedMessage {
  factory FocusResponse() => create();

  FocusResponse._();

  factory FocusResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FocusResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FocusResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FocusResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FocusResponse copyWith(void Function(FocusResponse) updates) =>
      super.copyWith((message) => updates(message as FocusResponse))
          as FocusResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FocusResponse create() => FocusResponse._();
  @$core.override
  FocusResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FocusResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FocusResponse>(create);
  static FocusResponse? _defaultInstance;
}

class Point extends $pb.GeneratedMessage {
  factory Point({
    $core.double? x,
    $core.double? y,
  }) {
    final result = create();
    if (x != null) result.x = x;
    if (y != null) result.y = y;
    return result;
  }

  Point._();

  factory Point.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Point.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Point',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aD(1, _omitFieldNames ? '' : 'x')
    ..aD(2, _omitFieldNames ? '' : 'y')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Point clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Point copyWith(void Function(Point) updates) =>
      super.copyWith((message) => updates(message as Point)) as Point;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Point create() => Point._();
  @$core.override
  Point createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Point getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Point>(create);
  static Point? _defaultInstance;

  @$pb.TagNumber(1)
  $core.double get x => $_getN(0);
  @$pb.TagNumber(1)
  set x($core.double value) => $_setDouble(0, value);
  @$pb.TagNumber(1)
  $core.bool hasX() => $_has(0);
  @$pb.TagNumber(1)
  void clearX() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.double get y => $_getN(1);
  @$pb.TagNumber(2)
  set y($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasY() => $_has(1);
  @$pb.TagNumber(2)
  void clearY() => $_clearField(2);
}

class AccessibilityInfoRequest extends $pb.GeneratedMessage {
  factory AccessibilityInfoRequest({
    Point? point,
    AccessibilityInfoRequest_Format? format,
    $core.String? marker,
    AccessibilityActionRequest_SearchableKey? matchKey,
    $core.int? depth,
    $core.Iterable<$core.String>? keys,
    AccessibilityInfoRequest_Backend? backend,
    $core.bool? profile,
    $core.bool? collectFrameCoverage,
  }) {
    final result = create();
    if (point != null) result.point = point;
    if (format != null) result.format = format;
    if (marker != null) result.marker = marker;
    if (matchKey != null) result.matchKey = matchKey;
    if (depth != null) result.depth = depth;
    if (keys != null) result.keys.addAll(keys);
    if (backend != null) result.backend = backend;
    if (profile != null) result.profile = profile;
    if (collectFrameCoverage != null)
      result.collectFrameCoverage = collectFrameCoverage;
    return result;
  }

  AccessibilityInfoRequest._();

  factory AccessibilityInfoRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AccessibilityInfoRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AccessibilityInfoRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<Point>(2, _omitFieldNames ? '' : 'point', subBuilder: Point.create)
    ..aE<AccessibilityInfoRequest_Format>(3, _omitFieldNames ? '' : 'format',
        enumValues: AccessibilityInfoRequest_Format.values)
    ..aOS(4, _omitFieldNames ? '' : 'marker')
    ..aE<AccessibilityActionRequest_SearchableKey>(
        5, _omitFieldNames ? '' : 'matchKey',
        enumValues: AccessibilityActionRequest_SearchableKey.values)
    ..aI(6, _omitFieldNames ? '' : 'depth', fieldType: $pb.PbFieldType.OU3)
    ..pPS(7, _omitFieldNames ? '' : 'keys')
    ..aE<AccessibilityInfoRequest_Backend>(8, _omitFieldNames ? '' : 'backend',
        enumValues: AccessibilityInfoRequest_Backend.values)
    ..aOB(9, _omitFieldNames ? '' : 'profile')
    ..aOB(10, _omitFieldNames ? '' : 'collectFrameCoverage')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityInfoRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityInfoRequest copyWith(
          void Function(AccessibilityInfoRequest) updates) =>
      super.copyWith((message) => updates(message as AccessibilityInfoRequest))
          as AccessibilityInfoRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AccessibilityInfoRequest create() => AccessibilityInfoRequest._();
  @$core.override
  AccessibilityInfoRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AccessibilityInfoRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AccessibilityInfoRequest>(create);
  static AccessibilityInfoRequest? _defaultInstance;

  @$pb.TagNumber(2)
  Point get point => $_getN(0);
  @$pb.TagNumber(2)
  set point(Point value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPoint() => $_has(0);
  @$pb.TagNumber(2)
  void clearPoint() => $_clearField(2);
  @$pb.TagNumber(2)
  Point ensurePoint() => $_ensure(0);

  @$pb.TagNumber(3)
  AccessibilityInfoRequest_Format get format => $_getN(1);
  @$pb.TagNumber(3)
  set format(AccessibilityInfoRequest_Format value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasFormat() => $_has(1);
  @$pb.TagNumber(3)
  void clearFormat() => $_clearField(3);

  /// Optional: describe a single element by marker (substring match against
  /// match_key, within depth) instead of by point / the whole screen.
  @$pb.TagNumber(4)
  $core.String get marker => $_getSZ(2);
  @$pb.TagNumber(4)
  set marker($core.String value) => $_setString(2, value);
  @$pb.TagNumber(4)
  $core.bool hasMarker() => $_has(2);
  @$pb.TagNumber(4)
  void clearMarker() => $_clearField(4);

  @$pb.TagNumber(5)
  AccessibilityActionRequest_SearchableKey get matchKey => $_getN(3);
  @$pb.TagNumber(5)
  set matchKey(AccessibilityActionRequest_SearchableKey value) =>
      $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasMatchKey() => $_has(3);
  @$pb.TagNumber(5)
  void clearMatchKey() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.int get depth => $_getIZ(4);
  @$pb.TagNumber(6)
  set depth($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(6)
  $core.bool hasDepth() => $_has(4);
  @$pb.TagNumber(6)
  void clearDepth() => $_clearField(6);

  /// Restricts the described accessibility keys to this set; an empty list
  /// returns the default key set.
  @$pb.TagNumber(7)
  $pb.PbList<$core.String> get keys => $_getList(5);

  @$pb.TagNumber(8)
  AccessibilityInfoRequest_Backend get backend => $_getN(6);
  @$pb.TagNumber(8)
  set backend(AccessibilityInfoRequest_Backend value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasBackend() => $_has(6);
  @$pb.TagNumber(8)
  void clearBackend() => $_clearField(8);

  /// Collect element counts and timings for the read. Reported by the COMPLETE
  /// format only; the legacy formats collect but have nowhere to report, so
  /// their output is unchanged.
  @$pb.TagNumber(9)
  $core.bool get profile => $_getBF(7);
  @$pb.TagNumber(9)
  set profile($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(9)
  $core.bool hasProfile() => $_has(7);
  @$pb.TagNumber(9)
  void clearProfile() => $_clearField(9);

  /// Collect upper-region frame coverage for the read. Reported by the
  /// COMPLETE format only, like profile.
  @$pb.TagNumber(10)
  $core.bool get collectFrameCoverage => $_getBF(8);
  @$pb.TagNumber(10)
  set collectFrameCoverage($core.bool value) => $_setBool(8, value);
  @$pb.TagNumber(10)
  $core.bool hasCollectFrameCoverage() => $_has(8);
  @$pb.TagNumber(10)
  void clearCollectFrameCoverage() => $_clearField(10);
}

class AccessibilityInfoResponse extends $pb.GeneratedMessage {
  factory AccessibilityInfoResponse({
    $core.String? json,
  }) {
    final result = create();
    if (json != null) result.json = json;
    return result;
  }

  AccessibilityInfoResponse._();

  factory AccessibilityInfoResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AccessibilityInfoResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AccessibilityInfoResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'json')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityInfoResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityInfoResponse copyWith(
          void Function(AccessibilityInfoResponse) updates) =>
      super.copyWith((message) => updates(message as AccessibilityInfoResponse))
          as AccessibilityInfoResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AccessibilityInfoResponse create() => AccessibilityInfoResponse._();
  @$core.override
  AccessibilityInfoResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AccessibilityInfoResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AccessibilityInfoResponse>(create);
  static AccessibilityInfoResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get json => $_getSZ(0);
  @$pb.TagNumber(1)
  set json($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasJson() => $_has(0);
  @$pb.TagNumber(1)
  void clearJson() => $_clearField(1);
}

class AccessibilityActionRequest_Tap extends $pb.GeneratedMessage {
  factory AccessibilityActionRequest_Tap({
    $core.bool? checkExpectedValue,
    $core.String? expectedValue,
    AccessibilityActionRequest_SearchableKey? expectedKey,
  }) {
    final result = create();
    if (checkExpectedValue != null)
      result.checkExpectedValue = checkExpectedValue;
    if (expectedValue != null) result.expectedValue = expectedValue;
    if (expectedKey != null) result.expectedKey = expectedKey;
    return result;
  }

  AccessibilityActionRequest_Tap._();

  factory AccessibilityActionRequest_Tap.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AccessibilityActionRequest_Tap.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AccessibilityActionRequest.Tap',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'checkExpectedValue')
    ..aOS(2, _omitFieldNames ? '' : 'expectedValue')
    ..aE<AccessibilityActionRequest_SearchableKey>(
        3, _omitFieldNames ? '' : 'expectedKey',
        enumValues: AccessibilityActionRequest_SearchableKey.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityActionRequest_Tap clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityActionRequest_Tap copyWith(
          void Function(AccessibilityActionRequest_Tap) updates) =>
      super.copyWith(
              (message) => updates(message as AccessibilityActionRequest_Tap))
          as AccessibilityActionRequest_Tap;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AccessibilityActionRequest_Tap create() =>
      AccessibilityActionRequest_Tap._();
  @$core.override
  AccessibilityActionRequest_Tap createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AccessibilityActionRequest_Tap getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AccessibilityActionRequest_Tap>(create);
  static AccessibilityActionRequest_Tap? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get checkExpectedValue => $_getBF(0);
  @$pb.TagNumber(1)
  set checkExpectedValue($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCheckExpectedValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearCheckExpectedValue() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get expectedValue => $_getSZ(1);
  @$pb.TagNumber(2)
  set expectedValue($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasExpectedValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearExpectedValue() => $_clearField(2);

  @$pb.TagNumber(3)
  AccessibilityActionRequest_SearchableKey get expectedKey => $_getN(2);
  @$pb.TagNumber(3)
  set expectedKey(AccessibilityActionRequest_SearchableKey value) =>
      $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasExpectedKey() => $_has(2);
  @$pb.TagNumber(3)
  void clearExpectedKey() => $_clearField(3);
}

class AccessibilityActionRequest_Scroll extends $pb.GeneratedMessage {
  factory AccessibilityActionRequest_Scroll({
    AccessibilityActionRequest_Scroll_Direction? direction,
  }) {
    final result = create();
    if (direction != null) result.direction = direction;
    return result;
  }

  AccessibilityActionRequest_Scroll._();

  factory AccessibilityActionRequest_Scroll.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AccessibilityActionRequest_Scroll.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AccessibilityActionRequest.Scroll',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<AccessibilityActionRequest_Scroll_Direction>(
        1, _omitFieldNames ? '' : 'direction',
        enumValues: AccessibilityActionRequest_Scroll_Direction.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityActionRequest_Scroll clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityActionRequest_Scroll copyWith(
          void Function(AccessibilityActionRequest_Scroll) updates) =>
      super.copyWith((message) =>
              updates(message as AccessibilityActionRequest_Scroll))
          as AccessibilityActionRequest_Scroll;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AccessibilityActionRequest_Scroll create() =>
      AccessibilityActionRequest_Scroll._();
  @$core.override
  AccessibilityActionRequest_Scroll createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AccessibilityActionRequest_Scroll getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AccessibilityActionRequest_Scroll>(
          create);
  static AccessibilityActionRequest_Scroll? _defaultInstance;

  @$pb.TagNumber(1)
  AccessibilityActionRequest_Scroll_Direction get direction => $_getN(0);
  @$pb.TagNumber(1)
  set direction(AccessibilityActionRequest_Scroll_Direction value) =>
      $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasDirection() => $_has(0);
  @$pb.TagNumber(1)
  void clearDirection() => $_clearField(1);
}

class AccessibilityActionRequest_SetValue extends $pb.GeneratedMessage {
  factory AccessibilityActionRequest_SetValue({
    $core.String? value,
  }) {
    final result = create();
    if (value != null) result.value = value;
    return result;
  }

  AccessibilityActionRequest_SetValue._();

  factory AccessibilityActionRequest_SetValue.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AccessibilityActionRequest_SetValue.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AccessibilityActionRequest.SetValue',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'value')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityActionRequest_SetValue clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityActionRequest_SetValue copyWith(
          void Function(AccessibilityActionRequest_SetValue) updates) =>
      super.copyWith((message) =>
              updates(message as AccessibilityActionRequest_SetValue))
          as AccessibilityActionRequest_SetValue;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AccessibilityActionRequest_SetValue create() =>
      AccessibilityActionRequest_SetValue._();
  @$core.override
  AccessibilityActionRequest_SetValue createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AccessibilityActionRequest_SetValue getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<
          AccessibilityActionRequest_SetValue>(create);
  static AccessibilityActionRequest_SetValue? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get value => $_getSZ(0);
  @$pb.TagNumber(1)
  set value($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearValue() => $_clearField(1);
}

enum AccessibilityActionRequest_Target { marker, point, notSet }

enum AccessibilityActionRequest_Action { tap, scroll, setValue, notSet }

class AccessibilityActionRequest extends $pb.GeneratedMessage {
  factory AccessibilityActionRequest({
    $core.String? marker,
    Point? point,
    AccessibilityActionRequest_SearchableKey? matchKey,
    $core.int? depth,
    AccessibilityActionRequest_Tap? tap,
    AccessibilityActionRequest_Scroll? scroll,
    AccessibilityActionRequest_SetValue? setValue,
  }) {
    final result = create();
    if (marker != null) result.marker = marker;
    if (point != null) result.point = point;
    if (matchKey != null) result.matchKey = matchKey;
    if (depth != null) result.depth = depth;
    if (tap != null) result.tap = tap;
    if (scroll != null) result.scroll = scroll;
    if (setValue != null) result.setValue = setValue;
    return result;
  }

  AccessibilityActionRequest._();

  factory AccessibilityActionRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AccessibilityActionRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, AccessibilityActionRequest_Target>
      _AccessibilityActionRequest_TargetByTag = {
    1: AccessibilityActionRequest_Target.marker,
    2: AccessibilityActionRequest_Target.point,
    0: AccessibilityActionRequest_Target.notSet
  };
  static const $core.Map<$core.int, AccessibilityActionRequest_Action>
      _AccessibilityActionRequest_ActionByTag = {
    5: AccessibilityActionRequest_Action.tap,
    6: AccessibilityActionRequest_Action.scroll,
    7: AccessibilityActionRequest_Action.setValue,
    0: AccessibilityActionRequest_Action.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AccessibilityActionRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..oo(1, [5, 6, 7])
    ..aOS(1, _omitFieldNames ? '' : 'marker')
    ..aOM<Point>(2, _omitFieldNames ? '' : 'point', subBuilder: Point.create)
    ..aE<AccessibilityActionRequest_SearchableKey>(
        3, _omitFieldNames ? '' : 'matchKey',
        enumValues: AccessibilityActionRequest_SearchableKey.values)
    ..aI(4, _omitFieldNames ? '' : 'depth', fieldType: $pb.PbFieldType.OU3)
    ..aOM<AccessibilityActionRequest_Tap>(5, _omitFieldNames ? '' : 'tap',
        subBuilder: AccessibilityActionRequest_Tap.create)
    ..aOM<AccessibilityActionRequest_Scroll>(6, _omitFieldNames ? '' : 'scroll',
        subBuilder: AccessibilityActionRequest_Scroll.create)
    ..aOM<AccessibilityActionRequest_SetValue>(
        7, _omitFieldNames ? '' : 'setValue',
        subBuilder: AccessibilityActionRequest_SetValue.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityActionRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityActionRequest copyWith(
          void Function(AccessibilityActionRequest) updates) =>
      super.copyWith(
              (message) => updates(message as AccessibilityActionRequest))
          as AccessibilityActionRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AccessibilityActionRequest create() => AccessibilityActionRequest._();
  @$core.override
  AccessibilityActionRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AccessibilityActionRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AccessibilityActionRequest>(create);
  static AccessibilityActionRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  AccessibilityActionRequest_Target whichTarget() =>
      _AccessibilityActionRequest_TargetByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearTarget() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  AccessibilityActionRequest_Action whichAction() =>
      _AccessibilityActionRequest_ActionByTag[$_whichOneof(1)]!;
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  void clearAction() => $_clearField($_whichOneof(1));

  @$pb.TagNumber(1)
  $core.String get marker => $_getSZ(0);
  @$pb.TagNumber(1)
  set marker($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMarker() => $_has(0);
  @$pb.TagNumber(1)
  void clearMarker() => $_clearField(1);

  @$pb.TagNumber(2)
  Point get point => $_getN(1);
  @$pb.TagNumber(2)
  set point(Point value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPoint() => $_has(1);
  @$pb.TagNumber(2)
  void clearPoint() => $_clearField(2);
  @$pb.TagNumber(2)
  Point ensurePoint() => $_ensure(1);

  @$pb.TagNumber(3)
  AccessibilityActionRequest_SearchableKey get matchKey => $_getN(2);
  @$pb.TagNumber(3)
  set matchKey(AccessibilityActionRequest_SearchableKey value) =>
      $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasMatchKey() => $_has(2);
  @$pb.TagNumber(3)
  void clearMatchKey() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get depth => $_getIZ(3);
  @$pb.TagNumber(4)
  set depth($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasDepth() => $_has(3);
  @$pb.TagNumber(4)
  void clearDepth() => $_clearField(4);

  @$pb.TagNumber(5)
  AccessibilityActionRequest_Tap get tap => $_getN(4);
  @$pb.TagNumber(5)
  set tap(AccessibilityActionRequest_Tap value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasTap() => $_has(4);
  @$pb.TagNumber(5)
  void clearTap() => $_clearField(5);
  @$pb.TagNumber(5)
  AccessibilityActionRequest_Tap ensureTap() => $_ensure(4);

  @$pb.TagNumber(6)
  AccessibilityActionRequest_Scroll get scroll => $_getN(5);
  @$pb.TagNumber(6)
  set scroll(AccessibilityActionRequest_Scroll value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasScroll() => $_has(5);
  @$pb.TagNumber(6)
  void clearScroll() => $_clearField(6);
  @$pb.TagNumber(6)
  AccessibilityActionRequest_Scroll ensureScroll() => $_ensure(5);

  @$pb.TagNumber(7)
  AccessibilityActionRequest_SetValue get setValue => $_getN(6);
  @$pb.TagNumber(7)
  set setValue(AccessibilityActionRequest_SetValue value) =>
      $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasSetValue() => $_has(6);
  @$pb.TagNumber(7)
  void clearSetValue() => $_clearField(7);
  @$pb.TagNumber(7)
  AccessibilityActionRequest_SetValue ensureSetValue() => $_ensure(6);
}

class AccessibilityActionResponse extends $pb.GeneratedMessage {
  factory AccessibilityActionResponse() => create();

  AccessibilityActionResponse._();

  factory AccessibilityActionResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AccessibilityActionResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AccessibilityActionResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityActionResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AccessibilityActionResponse copyWith(
          void Function(AccessibilityActionResponse) updates) =>
      super.copyWith(
              (message) => updates(message as AccessibilityActionResponse))
          as AccessibilityActionResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AccessibilityActionResponse create() =>
      AccessibilityActionResponse._();
  @$core.override
  AccessibilityActionResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AccessibilityActionResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AccessibilityActionResponse>(create);
  static AccessibilityActionResponse? _defaultInstance;
}

class ApproveRequest extends $pb.GeneratedMessage {
  factory ApproveRequest({
    $core.String? bundleId,
    $core.Iterable<ApproveRequest_Permission>? permissions,
    $core.String? scheme,
  }) {
    final result = create();
    if (bundleId != null) result.bundleId = bundleId;
    if (permissions != null) result.permissions.addAll(permissions);
    if (scheme != null) result.scheme = scheme;
    return result;
  }

  ApproveRequest._();

  factory ApproveRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ApproveRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ApproveRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'bundleId')
    ..pc<ApproveRequest_Permission>(
        2, _omitFieldNames ? '' : 'permissions', $pb.PbFieldType.KE,
        valueOf: ApproveRequest_Permission.valueOf,
        enumValues: ApproveRequest_Permission.values,
        defaultEnumValue: ApproveRequest_Permission.PHOTOS)
    ..aOS(3, _omitFieldNames ? '' : 'scheme')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ApproveRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ApproveRequest copyWith(void Function(ApproveRequest) updates) =>
      super.copyWith((message) => updates(message as ApproveRequest))
          as ApproveRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ApproveRequest create() => ApproveRequest._();
  @$core.override
  ApproveRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ApproveRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ApproveRequest>(create);
  static ApproveRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get bundleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set bundleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBundleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBundleId() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<ApproveRequest_Permission> get permissions => $_getList(1);

  @$pb.TagNumber(3)
  $core.String get scheme => $_getSZ(2);
  @$pb.TagNumber(3)
  set scheme($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasScheme() => $_has(2);
  @$pb.TagNumber(3)
  void clearScheme() => $_clearField(3);
}

class ApproveResponse extends $pb.GeneratedMessage {
  factory ApproveResponse() => create();

  ApproveResponse._();

  factory ApproveResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ApproveResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ApproveResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ApproveResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ApproveResponse copyWith(void Function(ApproveResponse) updates) =>
      super.copyWith((message) => updates(message as ApproveResponse))
          as ApproveResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ApproveResponse create() => ApproveResponse._();
  @$core.override
  ApproveResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ApproveResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ApproveResponse>(create);
  static ApproveResponse? _defaultInstance;
}

class RevokeRequest extends $pb.GeneratedMessage {
  factory RevokeRequest({
    $core.String? bundleId,
    $core.Iterable<RevokeRequest_Permission>? permissions,
    $core.String? scheme,
  }) {
    final result = create();
    if (bundleId != null) result.bundleId = bundleId;
    if (permissions != null) result.permissions.addAll(permissions);
    if (scheme != null) result.scheme = scheme;
    return result;
  }

  RevokeRequest._();

  factory RevokeRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RevokeRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RevokeRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'bundleId')
    ..pc<RevokeRequest_Permission>(
        2, _omitFieldNames ? '' : 'permissions', $pb.PbFieldType.KE,
        valueOf: RevokeRequest_Permission.valueOf,
        enumValues: RevokeRequest_Permission.values,
        defaultEnumValue: RevokeRequest_Permission.PHOTOS)
    ..aOS(3, _omitFieldNames ? '' : 'scheme')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RevokeRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RevokeRequest copyWith(void Function(RevokeRequest) updates) =>
      super.copyWith((message) => updates(message as RevokeRequest))
          as RevokeRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RevokeRequest create() => RevokeRequest._();
  @$core.override
  RevokeRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RevokeRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RevokeRequest>(create);
  static RevokeRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get bundleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set bundleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBundleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBundleId() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<RevokeRequest_Permission> get permissions => $_getList(1);

  @$pb.TagNumber(3)
  $core.String get scheme => $_getSZ(2);
  @$pb.TagNumber(3)
  set scheme($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasScheme() => $_has(2);
  @$pb.TagNumber(3)
  void clearScheme() => $_clearField(3);
}

class RevokeResponse extends $pb.GeneratedMessage {
  factory RevokeResponse() => create();

  RevokeResponse._();

  factory RevokeResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RevokeResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RevokeResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RevokeResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RevokeResponse copyWith(void Function(RevokeResponse) updates) =>
      super.copyWith((message) => updates(message as RevokeResponse))
          as RevokeResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RevokeResponse create() => RevokeResponse._();
  @$core.override
  RevokeResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RevokeResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RevokeResponse>(create);
  static RevokeResponse? _defaultInstance;
}

class ClearKeychainRequest extends $pb.GeneratedMessage {
  factory ClearKeychainRequest() => create();

  ClearKeychainRequest._();

  factory ClearKeychainRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ClearKeychainRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClearKeychainRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearKeychainRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearKeychainRequest copyWith(void Function(ClearKeychainRequest) updates) =>
      super.copyWith((message) => updates(message as ClearKeychainRequest))
          as ClearKeychainRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClearKeychainRequest create() => ClearKeychainRequest._();
  @$core.override
  ClearKeychainRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ClearKeychainRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ClearKeychainRequest>(create);
  static ClearKeychainRequest? _defaultInstance;
}

class ClearKeychainResponse extends $pb.GeneratedMessage {
  factory ClearKeychainResponse() => create();

  ClearKeychainResponse._();

  factory ClearKeychainResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ClearKeychainResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClearKeychainResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearKeychainResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearKeychainResponse copyWith(
          void Function(ClearKeychainResponse) updates) =>
      super.copyWith((message) => updates(message as ClearKeychainResponse))
          as ClearKeychainResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClearKeychainResponse create() => ClearKeychainResponse._();
  @$core.override
  ClearKeychainResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ClearKeychainResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ClearKeychainResponse>(create);
  static ClearKeychainResponse? _defaultInstance;
}

class SetLocationRequest extends $pb.GeneratedMessage {
  factory SetLocationRequest({
    Location? location,
  }) {
    final result = create();
    if (location != null) result.location = location;
    return result;
  }

  SetLocationRequest._();

  factory SetLocationRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SetLocationRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SetLocationRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<Location>(1, _omitFieldNames ? '' : 'location',
        subBuilder: Location.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetLocationRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetLocationRequest copyWith(void Function(SetLocationRequest) updates) =>
      super.copyWith((message) => updates(message as SetLocationRequest))
          as SetLocationRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SetLocationRequest create() => SetLocationRequest._();
  @$core.override
  SetLocationRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SetLocationRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SetLocationRequest>(create);
  static SetLocationRequest? _defaultInstance;

  @$pb.TagNumber(1)
  Location get location => $_getN(0);
  @$pb.TagNumber(1)
  set location(Location value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasLocation() => $_has(0);
  @$pb.TagNumber(1)
  void clearLocation() => $_clearField(1);
  @$pb.TagNumber(1)
  Location ensureLocation() => $_ensure(0);
}

class Location extends $pb.GeneratedMessage {
  factory Location({
    $core.double? latitude,
    $core.double? longitude,
  }) {
    final result = create();
    if (latitude != null) result.latitude = latitude;
    if (longitude != null) result.longitude = longitude;
    return result;
  }

  Location._();

  factory Location.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Location.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Location',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aD(1, _omitFieldNames ? '' : 'latitude')
    ..aD(2, _omitFieldNames ? '' : 'longitude')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Location clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Location copyWith(void Function(Location) updates) =>
      super.copyWith((message) => updates(message as Location)) as Location;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Location create() => Location._();
  @$core.override
  Location createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Location getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Location>(create);
  static Location? _defaultInstance;

  @$pb.TagNumber(1)
  $core.double get latitude => $_getN(0);
  @$pb.TagNumber(1)
  set latitude($core.double value) => $_setDouble(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLatitude() => $_has(0);
  @$pb.TagNumber(1)
  void clearLatitude() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.double get longitude => $_getN(1);
  @$pb.TagNumber(2)
  set longitude($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasLongitude() => $_has(1);
  @$pb.TagNumber(2)
  void clearLongitude() => $_clearField(2);
}

class SetLocationResponse extends $pb.GeneratedMessage {
  factory SetLocationResponse() => create();

  SetLocationResponse._();

  factory SetLocationResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SetLocationResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SetLocationResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetLocationResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetLocationResponse copyWith(void Function(SetLocationResponse) updates) =>
      super.copyWith((message) => updates(message as SetLocationResponse))
          as SetLocationResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SetLocationResponse create() => SetLocationResponse._();
  @$core.override
  SetLocationResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SetLocationResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SetLocationResponse>(create);
  static SetLocationResponse? _defaultInstance;
}

class UninstallRequest extends $pb.GeneratedMessage {
  factory UninstallRequest({
    $core.String? bundleId,
  }) {
    final result = create();
    if (bundleId != null) result.bundleId = bundleId;
    return result;
  }

  UninstallRequest._();

  factory UninstallRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory UninstallRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UninstallRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'bundleId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UninstallRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UninstallRequest copyWith(void Function(UninstallRequest) updates) =>
      super.copyWith((message) => updates(message as UninstallRequest))
          as UninstallRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static UninstallRequest create() => UninstallRequest._();
  @$core.override
  UninstallRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static UninstallRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UninstallRequest>(create);
  static UninstallRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get bundleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set bundleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBundleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBundleId() => $_clearField(1);
}

class UninstallResponse extends $pb.GeneratedMessage {
  factory UninstallResponse() => create();

  UninstallResponse._();

  factory UninstallResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory UninstallResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UninstallResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UninstallResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UninstallResponse copyWith(void Function(UninstallResponse) updates) =>
      super.copyWith((message) => updates(message as UninstallResponse))
          as UninstallResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static UninstallResponse create() => UninstallResponse._();
  @$core.override
  UninstallResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static UninstallResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UninstallResponse>(create);
  static UninstallResponse? _defaultInstance;
}

class TerminateRequest extends $pb.GeneratedMessage {
  factory TerminateRequest({
    $core.String? bundleId,
  }) {
    final result = create();
    if (bundleId != null) result.bundleId = bundleId;
    return result;
  }

  TerminateRequest._();

  factory TerminateRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TerminateRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TerminateRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'bundleId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TerminateRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TerminateRequest copyWith(void Function(TerminateRequest) updates) =>
      super.copyWith((message) => updates(message as TerminateRequest))
          as TerminateRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TerminateRequest create() => TerminateRequest._();
  @$core.override
  TerminateRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TerminateRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TerminateRequest>(create);
  static TerminateRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get bundleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set bundleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBundleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBundleId() => $_clearField(1);
}

class TerminateResponse extends $pb.GeneratedMessage {
  factory TerminateResponse() => create();

  TerminateResponse._();

  factory TerminateResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TerminateResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TerminateResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TerminateResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TerminateResponse copyWith(void Function(TerminateResponse) updates) =>
      super.copyWith((message) => updates(message as TerminateResponse))
          as TerminateResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TerminateResponse create() => TerminateResponse._();
  @$core.override
  TerminateResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TerminateResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TerminateResponse>(create);
  static TerminateResponse? _defaultInstance;
}

class OpenUrlRequest extends $pb.GeneratedMessage {
  factory OpenUrlRequest({
    $core.String? url,
  }) {
    final result = create();
    if (url != null) result.url = url;
    return result;
  }

  OpenUrlRequest._();

  factory OpenUrlRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory OpenUrlRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OpenUrlRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'url')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OpenUrlRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OpenUrlRequest copyWith(void Function(OpenUrlRequest) updates) =>
      super.copyWith((message) => updates(message as OpenUrlRequest))
          as OpenUrlRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static OpenUrlRequest create() => OpenUrlRequest._();
  @$core.override
  OpenUrlRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static OpenUrlRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<OpenUrlRequest>(create);
  static OpenUrlRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get url => $_getSZ(0);
  @$pb.TagNumber(1)
  set url($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUrl() => $_has(0);
  @$pb.TagNumber(1)
  void clearUrl() => $_clearField(1);
}

class OpenUrlResponse extends $pb.GeneratedMessage {
  factory OpenUrlResponse() => create();

  OpenUrlResponse._();

  factory OpenUrlResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory OpenUrlResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OpenUrlResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OpenUrlResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OpenUrlResponse copyWith(void Function(OpenUrlResponse) updates) =>
      super.copyWith((message) => updates(message as OpenUrlResponse))
          as OpenUrlResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static OpenUrlResponse create() => OpenUrlResponse._();
  @$core.override
  OpenUrlResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static OpenUrlResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<OpenUrlResponse>(create);
  static OpenUrlResponse? _defaultInstance;
}

class ContactsUpdateRequest extends $pb.GeneratedMessage {
  factory ContactsUpdateRequest({
    Payload? payload,
  }) {
    final result = create();
    if (payload != null) result.payload = payload;
    return result;
  }

  ContactsUpdateRequest._();

  factory ContactsUpdateRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ContactsUpdateRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ContactsUpdateRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<Payload>(1, _omitFieldNames ? '' : 'payload',
        subBuilder: Payload.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ContactsUpdateRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ContactsUpdateRequest copyWith(
          void Function(ContactsUpdateRequest) updates) =>
      super.copyWith((message) => updates(message as ContactsUpdateRequest))
          as ContactsUpdateRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ContactsUpdateRequest create() => ContactsUpdateRequest._();
  @$core.override
  ContactsUpdateRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ContactsUpdateRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ContactsUpdateRequest>(create);
  static ContactsUpdateRequest? _defaultInstance;

  @$pb.TagNumber(1)
  Payload get payload => $_getN(0);
  @$pb.TagNumber(1)
  set payload(Payload value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPayload() => $_has(0);
  @$pb.TagNumber(1)
  void clearPayload() => $_clearField(1);
  @$pb.TagNumber(1)
  Payload ensurePayload() => $_ensure(0);
}

class ContactsUpdateResponse extends $pb.GeneratedMessage {
  factory ContactsUpdateResponse() => create();

  ContactsUpdateResponse._();

  factory ContactsUpdateResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ContactsUpdateResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ContactsUpdateResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ContactsUpdateResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ContactsUpdateResponse copyWith(
          void Function(ContactsUpdateResponse) updates) =>
      super.copyWith((message) => updates(message as ContactsUpdateResponse))
          as ContactsUpdateResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ContactsUpdateResponse create() => ContactsUpdateResponse._();
  @$core.override
  ContactsUpdateResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ContactsUpdateResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ContactsUpdateResponse>(create);
  static ContactsUpdateResponse? _defaultInstance;
}

class ContactsClearRequest extends $pb.GeneratedMessage {
  factory ContactsClearRequest() => create();

  ContactsClearRequest._();

  factory ContactsClearRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ContactsClearRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ContactsClearRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ContactsClearRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ContactsClearRequest copyWith(void Function(ContactsClearRequest) updates) =>
      super.copyWith((message) => updates(message as ContactsClearRequest))
          as ContactsClearRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ContactsClearRequest create() => ContactsClearRequest._();
  @$core.override
  ContactsClearRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ContactsClearRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ContactsClearRequest>(create);
  static ContactsClearRequest? _defaultInstance;
}

class ContactsClearResponse extends $pb.GeneratedMessage {
  factory ContactsClearResponse() => create();

  ContactsClearResponse._();

  factory ContactsClearResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ContactsClearResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ContactsClearResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ContactsClearResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ContactsClearResponse copyWith(
          void Function(ContactsClearResponse) updates) =>
      super.copyWith((message) => updates(message as ContactsClearResponse))
          as ContactsClearResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ContactsClearResponse create() => ContactsClearResponse._();
  @$core.override
  ContactsClearResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ContactsClearResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ContactsClearResponse>(create);
  static ContactsClearResponse? _defaultInstance;
}

class PhotosClearRequest extends $pb.GeneratedMessage {
  factory PhotosClearRequest() => create();

  PhotosClearRequest._();

  factory PhotosClearRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PhotosClearRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PhotosClearRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PhotosClearRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PhotosClearRequest copyWith(void Function(PhotosClearRequest) updates) =>
      super.copyWith((message) => updates(message as PhotosClearRequest))
          as PhotosClearRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PhotosClearRequest create() => PhotosClearRequest._();
  @$core.override
  PhotosClearRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PhotosClearRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PhotosClearRequest>(create);
  static PhotosClearRequest? _defaultInstance;
}

class PhotosClearResponse extends $pb.GeneratedMessage {
  factory PhotosClearResponse() => create();

  PhotosClearResponse._();

  factory PhotosClearResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PhotosClearResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PhotosClearResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PhotosClearResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PhotosClearResponse copyWith(void Function(PhotosClearResponse) updates) =>
      super.copyWith((message) => updates(message as PhotosClearResponse))
          as PhotosClearResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PhotosClearResponse create() => PhotosClearResponse._();
  @$core.override
  PhotosClearResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PhotosClearResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PhotosClearResponse>(create);
  static PhotosClearResponse? _defaultInstance;
}

class TargetDescriptionRequest extends $pb.GeneratedMessage {
  factory TargetDescriptionRequest({
    $core.bool? fetchDiagnostics,
  }) {
    final result = create();
    if (fetchDiagnostics != null) result.fetchDiagnostics = fetchDiagnostics;
    return result;
  }

  TargetDescriptionRequest._();

  factory TargetDescriptionRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TargetDescriptionRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TargetDescriptionRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'fetchDiagnostics')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TargetDescriptionRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TargetDescriptionRequest copyWith(
          void Function(TargetDescriptionRequest) updates) =>
      super.copyWith((message) => updates(message as TargetDescriptionRequest))
          as TargetDescriptionRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TargetDescriptionRequest create() => TargetDescriptionRequest._();
  @$core.override
  TargetDescriptionRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TargetDescriptionRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TargetDescriptionRequest>(create);
  static TargetDescriptionRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get fetchDiagnostics => $_getBF(0);
  @$pb.TagNumber(1)
  set fetchDiagnostics($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasFetchDiagnostics() => $_has(0);
  @$pb.TagNumber(1)
  void clearFetchDiagnostics() => $_clearField(1);
}

class TargetDescriptionResponse extends $pb.GeneratedMessage {
  factory TargetDescriptionResponse({
    TargetDescription? targetDescription,
    CompanionInfo? companion,
  }) {
    final result = create();
    if (targetDescription != null) result.targetDescription = targetDescription;
    if (companion != null) result.companion = companion;
    return result;
  }

  TargetDescriptionResponse._();

  factory TargetDescriptionResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TargetDescriptionResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TargetDescriptionResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<TargetDescription>(1, _omitFieldNames ? '' : 'targetDescription',
        subBuilder: TargetDescription.create)
    ..aOM<CompanionInfo>(2, _omitFieldNames ? '' : 'companion',
        subBuilder: CompanionInfo.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TargetDescriptionResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TargetDescriptionResponse copyWith(
          void Function(TargetDescriptionResponse) updates) =>
      super.copyWith((message) => updates(message as TargetDescriptionResponse))
          as TargetDescriptionResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TargetDescriptionResponse create() => TargetDescriptionResponse._();
  @$core.override
  TargetDescriptionResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TargetDescriptionResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TargetDescriptionResponse>(create);
  static TargetDescriptionResponse? _defaultInstance;

  @$pb.TagNumber(1)
  TargetDescription get targetDescription => $_getN(0);
  @$pb.TagNumber(1)
  set targetDescription(TargetDescription value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTargetDescription() => $_has(0);
  @$pb.TagNumber(1)
  void clearTargetDescription() => $_clearField(1);
  @$pb.TagNumber(1)
  TargetDescription ensureTargetDescription() => $_ensure(0);

  @$pb.TagNumber(2)
  CompanionInfo get companion => $_getN(1);
  @$pb.TagNumber(2)
  set companion(CompanionInfo value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasCompanion() => $_has(1);
  @$pb.TagNumber(2)
  void clearCompanion() => $_clearField(2);
  @$pb.TagNumber(2)
  CompanionInfo ensureCompanion() => $_ensure(1);
}

class HIDEvent_HIDTouch extends $pb.GeneratedMessage {
  factory HIDEvent_HIDTouch({
    Point? point,
  }) {
    final result = create();
    if (point != null) result.point = point;
    return result;
  }

  HIDEvent_HIDTouch._();

  factory HIDEvent_HIDTouch.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent_HIDTouch.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent.HIDTouch',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<Point>(1, _omitFieldNames ? '' : 'point', subBuilder: Point.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDTouch clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDTouch copyWith(void Function(HIDEvent_HIDTouch) updates) =>
      super.copyWith((message) => updates(message as HIDEvent_HIDTouch))
          as HIDEvent_HIDTouch;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDTouch create() => HIDEvent_HIDTouch._();
  @$core.override
  HIDEvent_HIDTouch createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDTouch getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDEvent_HIDTouch>(create);
  static HIDEvent_HIDTouch? _defaultInstance;

  @$pb.TagNumber(1)
  Point get point => $_getN(0);
  @$pb.TagNumber(1)
  set point(Point value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPoint() => $_has(0);
  @$pb.TagNumber(1)
  void clearPoint() => $_clearField(1);
  @$pb.TagNumber(1)
  Point ensurePoint() => $_ensure(0);
}

class HIDEvent_HIDButton extends $pb.GeneratedMessage {
  factory HIDEvent_HIDButton({
    HIDEvent_HIDButtonType? button,
  }) {
    final result = create();
    if (button != null) result.button = button;
    return result;
  }

  HIDEvent_HIDButton._();

  factory HIDEvent_HIDButton.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent_HIDButton.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent.HIDButton',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<HIDEvent_HIDButtonType>(1, _omitFieldNames ? '' : 'button',
        enumValues: HIDEvent_HIDButtonType.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDButton clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDButton copyWith(void Function(HIDEvent_HIDButton) updates) =>
      super.copyWith((message) => updates(message as HIDEvent_HIDButton))
          as HIDEvent_HIDButton;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDButton create() => HIDEvent_HIDButton._();
  @$core.override
  HIDEvent_HIDButton createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDButton getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDEvent_HIDButton>(create);
  static HIDEvent_HIDButton? _defaultInstance;

  @$pb.TagNumber(1)
  HIDEvent_HIDButtonType get button => $_getN(0);
  @$pb.TagNumber(1)
  set button(HIDEvent_HIDButtonType value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasButton() => $_has(0);
  @$pb.TagNumber(1)
  void clearButton() => $_clearField(1);
}

class HIDEvent_HIDKey extends $pb.GeneratedMessage {
  factory HIDEvent_HIDKey({
    $fixnum.Int64? keycode,
  }) {
    final result = create();
    if (keycode != null) result.keycode = keycode;
    return result;
  }

  HIDEvent_HIDKey._();

  factory HIDEvent_HIDKey.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent_HIDKey.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent.HIDKey',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$fixnum.Int64>(1, _omitFieldNames ? '' : 'keycode', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDKey clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDKey copyWith(void Function(HIDEvent_HIDKey) updates) =>
      super.copyWith((message) => updates(message as HIDEvent_HIDKey))
          as HIDEvent_HIDKey;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDKey create() => HIDEvent_HIDKey._();
  @$core.override
  HIDEvent_HIDKey createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDKey getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDEvent_HIDKey>(create);
  static HIDEvent_HIDKey? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get keycode => $_getI64(0);
  @$pb.TagNumber(1)
  set keycode($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasKeycode() => $_has(0);
  @$pb.TagNumber(1)
  void clearKeycode() => $_clearField(1);
}

enum HIDEvent_HIDPressAction_Action { touch, button, key, notSet }

class HIDEvent_HIDPressAction extends $pb.GeneratedMessage {
  factory HIDEvent_HIDPressAction({
    HIDEvent_HIDTouch? touch,
    HIDEvent_HIDButton? button,
    HIDEvent_HIDKey? key,
  }) {
    final result = create();
    if (touch != null) result.touch = touch;
    if (button != null) result.button = button;
    if (key != null) result.key = key;
    return result;
  }

  HIDEvent_HIDPressAction._();

  factory HIDEvent_HIDPressAction.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent_HIDPressAction.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, HIDEvent_HIDPressAction_Action>
      _HIDEvent_HIDPressAction_ActionByTag = {
    1: HIDEvent_HIDPressAction_Action.touch,
    2: HIDEvent_HIDPressAction_Action.button,
    3: HIDEvent_HIDPressAction_Action.key,
    0: HIDEvent_HIDPressAction_Action.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent.HIDPressAction',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3])
    ..aOM<HIDEvent_HIDTouch>(1, _omitFieldNames ? '' : 'touch',
        subBuilder: HIDEvent_HIDTouch.create)
    ..aOM<HIDEvent_HIDButton>(2, _omitFieldNames ? '' : 'button',
        subBuilder: HIDEvent_HIDButton.create)
    ..aOM<HIDEvent_HIDKey>(3, _omitFieldNames ? '' : 'key',
        subBuilder: HIDEvent_HIDKey.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDPressAction clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDPressAction copyWith(
          void Function(HIDEvent_HIDPressAction) updates) =>
      super.copyWith((message) => updates(message as HIDEvent_HIDPressAction))
          as HIDEvent_HIDPressAction;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDPressAction create() => HIDEvent_HIDPressAction._();
  @$core.override
  HIDEvent_HIDPressAction createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDPressAction getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDEvent_HIDPressAction>(create);
  static HIDEvent_HIDPressAction? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  HIDEvent_HIDPressAction_Action whichAction() =>
      _HIDEvent_HIDPressAction_ActionByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearAction() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  HIDEvent_HIDTouch get touch => $_getN(0);
  @$pb.TagNumber(1)
  set touch(HIDEvent_HIDTouch value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTouch() => $_has(0);
  @$pb.TagNumber(1)
  void clearTouch() => $_clearField(1);
  @$pb.TagNumber(1)
  HIDEvent_HIDTouch ensureTouch() => $_ensure(0);

  @$pb.TagNumber(2)
  HIDEvent_HIDButton get button => $_getN(1);
  @$pb.TagNumber(2)
  set button(HIDEvent_HIDButton value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasButton() => $_has(1);
  @$pb.TagNumber(2)
  void clearButton() => $_clearField(2);
  @$pb.TagNumber(2)
  HIDEvent_HIDButton ensureButton() => $_ensure(1);

  @$pb.TagNumber(3)
  HIDEvent_HIDKey get key => $_getN(2);
  @$pb.TagNumber(3)
  set key(HIDEvent_HIDKey value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasKey() => $_has(2);
  @$pb.TagNumber(3)
  void clearKey() => $_clearField(3);
  @$pb.TagNumber(3)
  HIDEvent_HIDKey ensureKey() => $_ensure(2);
}

class HIDEvent_HIDPress extends $pb.GeneratedMessage {
  factory HIDEvent_HIDPress({
    HIDEvent_HIDPressAction? action,
    HIDEvent_HIDDirection? direction,
  }) {
    final result = create();
    if (action != null) result.action = action;
    if (direction != null) result.direction = direction;
    return result;
  }

  HIDEvent_HIDPress._();

  factory HIDEvent_HIDPress.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent_HIDPress.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent.HIDPress',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<HIDEvent_HIDPressAction>(1, _omitFieldNames ? '' : 'action',
        subBuilder: HIDEvent_HIDPressAction.create)
    ..aE<HIDEvent_HIDDirection>(2, _omitFieldNames ? '' : 'direction',
        enumValues: HIDEvent_HIDDirection.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDPress clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDPress copyWith(void Function(HIDEvent_HIDPress) updates) =>
      super.copyWith((message) => updates(message as HIDEvent_HIDPress))
          as HIDEvent_HIDPress;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDPress create() => HIDEvent_HIDPress._();
  @$core.override
  HIDEvent_HIDPress createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDPress getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDEvent_HIDPress>(create);
  static HIDEvent_HIDPress? _defaultInstance;

  @$pb.TagNumber(1)
  HIDEvent_HIDPressAction get action => $_getN(0);
  @$pb.TagNumber(1)
  set action(HIDEvent_HIDPressAction value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasAction() => $_has(0);
  @$pb.TagNumber(1)
  void clearAction() => $_clearField(1);
  @$pb.TagNumber(1)
  HIDEvent_HIDPressAction ensureAction() => $_ensure(0);

  @$pb.TagNumber(2)
  HIDEvent_HIDDirection get direction => $_getN(1);
  @$pb.TagNumber(2)
  set direction(HIDEvent_HIDDirection value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasDirection() => $_has(1);
  @$pb.TagNumber(2)
  void clearDirection() => $_clearField(2);
}

class HIDEvent_HIDSwipe extends $pb.GeneratedMessage {
  factory HIDEvent_HIDSwipe({
    Point? start,
    Point? end,
    $core.double? delta,
    $core.double? duration,
  }) {
    final result = create();
    if (start != null) result.start = start;
    if (end != null) result.end = end;
    if (delta != null) result.delta = delta;
    if (duration != null) result.duration = duration;
    return result;
  }

  HIDEvent_HIDSwipe._();

  factory HIDEvent_HIDSwipe.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent_HIDSwipe.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent.HIDSwipe',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<Point>(1, _omitFieldNames ? '' : 'start', subBuilder: Point.create)
    ..aOM<Point>(2, _omitFieldNames ? '' : 'end', subBuilder: Point.create)
    ..aD(5, _omitFieldNames ? '' : 'delta')
    ..aD(6, _omitFieldNames ? '' : 'duration')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDSwipe clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDSwipe copyWith(void Function(HIDEvent_HIDSwipe) updates) =>
      super.copyWith((message) => updates(message as HIDEvent_HIDSwipe))
          as HIDEvent_HIDSwipe;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDSwipe create() => HIDEvent_HIDSwipe._();
  @$core.override
  HIDEvent_HIDSwipe createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDSwipe getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDEvent_HIDSwipe>(create);
  static HIDEvent_HIDSwipe? _defaultInstance;

  @$pb.TagNumber(1)
  Point get start => $_getN(0);
  @$pb.TagNumber(1)
  set start(Point value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStart() => $_has(0);
  @$pb.TagNumber(1)
  void clearStart() => $_clearField(1);
  @$pb.TagNumber(1)
  Point ensureStart() => $_ensure(0);

  @$pb.TagNumber(2)
  Point get end => $_getN(1);
  @$pb.TagNumber(2)
  set end(Point value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasEnd() => $_has(1);
  @$pb.TagNumber(2)
  void clearEnd() => $_clearField(2);
  @$pb.TagNumber(2)
  Point ensureEnd() => $_ensure(1);

  @$pb.TagNumber(5)
  $core.double get delta => $_getN(2);
  @$pb.TagNumber(5)
  set delta($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(5)
  $core.bool hasDelta() => $_has(2);
  @$pb.TagNumber(5)
  void clearDelta() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.double get duration => $_getN(3);
  @$pb.TagNumber(6)
  set duration($core.double value) => $_setDouble(3, value);
  @$pb.TagNumber(6)
  $core.bool hasDuration() => $_has(3);
  @$pb.TagNumber(6)
  void clearDuration() => $_clearField(6);
}

class HIDEvent_HIDDelay extends $pb.GeneratedMessage {
  factory HIDEvent_HIDDelay({
    $core.double? duration,
  }) {
    final result = create();
    if (duration != null) result.duration = duration;
    return result;
  }

  HIDEvent_HIDDelay._();

  factory HIDEvent_HIDDelay.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent_HIDDelay.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent.HIDDelay',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aD(1, _omitFieldNames ? '' : 'duration')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDDelay clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDDelay copyWith(void Function(HIDEvent_HIDDelay) updates) =>
      super.copyWith((message) => updates(message as HIDEvent_HIDDelay))
          as HIDEvent_HIDDelay;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDDelay create() => HIDEvent_HIDDelay._();
  @$core.override
  HIDEvent_HIDDelay createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDDelay getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDEvent_HIDDelay>(create);
  static HIDEvent_HIDDelay? _defaultInstance;

  @$pb.TagNumber(1)
  $core.double get duration => $_getN(0);
  @$pb.TagNumber(1)
  set duration($core.double value) => $_setDouble(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDuration() => $_has(0);
  @$pb.TagNumber(1)
  void clearDuration() => $_clearField(1);
}

class HIDEvent_HIDPinch extends $pb.GeneratedMessage {
  factory HIDEvent_HIDPinch({
    Point? center,
    $core.double? scale,
    $core.double? duration,
    $core.double? radius,
  }) {
    final result = create();
    if (center != null) result.center = center;
    if (scale != null) result.scale = scale;
    if (duration != null) result.duration = duration;
    if (radius != null) result.radius = radius;
    return result;
  }

  HIDEvent_HIDPinch._();

  factory HIDEvent_HIDPinch.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent_HIDPinch.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent.HIDPinch',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<Point>(1, _omitFieldNames ? '' : 'center', subBuilder: Point.create)
    ..aD(2, _omitFieldNames ? '' : 'scale')
    ..aD(3, _omitFieldNames ? '' : 'duration')
    ..aD(4, _omitFieldNames ? '' : 'radius')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDPinch clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDPinch copyWith(void Function(HIDEvent_HIDPinch) updates) =>
      super.copyWith((message) => updates(message as HIDEvent_HIDPinch))
          as HIDEvent_HIDPinch;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDPinch create() => HIDEvent_HIDPinch._();
  @$core.override
  HIDEvent_HIDPinch createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDPinch getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDEvent_HIDPinch>(create);
  static HIDEvent_HIDPinch? _defaultInstance;

  @$pb.TagNumber(1)
  Point get center => $_getN(0);
  @$pb.TagNumber(1)
  set center(Point value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasCenter() => $_has(0);
  @$pb.TagNumber(1)
  void clearCenter() => $_clearField(1);
  @$pb.TagNumber(1)
  Point ensureCenter() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.double get scale => $_getN(1);
  @$pb.TagNumber(2)
  set scale($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasScale() => $_has(1);
  @$pb.TagNumber(2)
  void clearScale() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get duration => $_getN(2);
  @$pb.TagNumber(3)
  set duration($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDuration() => $_has(2);
  @$pb.TagNumber(3)
  void clearDuration() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.double get radius => $_getN(3);
  @$pb.TagNumber(4)
  set radius($core.double value) => $_setDouble(3, value);
  @$pb.TagNumber(4)
  $core.bool hasRadius() => $_has(3);
  @$pb.TagNumber(4)
  void clearRadius() => $_clearField(4);
}

class HIDEvent_HIDOrientation extends $pb.GeneratedMessage {
  factory HIDEvent_HIDOrientation({
    HIDEvent_HIDOrientationType? orientation,
  }) {
    final result = create();
    if (orientation != null) result.orientation = orientation;
    return result;
  }

  HIDEvent_HIDOrientation._();

  factory HIDEvent_HIDOrientation.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent_HIDOrientation.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent.HIDOrientation',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<HIDEvent_HIDOrientationType>(1, _omitFieldNames ? '' : 'orientation',
        enumValues: HIDEvent_HIDOrientationType.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDOrientation clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDOrientation copyWith(
          void Function(HIDEvent_HIDOrientation) updates) =>
      super.copyWith((message) => updates(message as HIDEvent_HIDOrientation))
          as HIDEvent_HIDOrientation;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDOrientation create() => HIDEvent_HIDOrientation._();
  @$core.override
  HIDEvent_HIDOrientation createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDOrientation getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDEvent_HIDOrientation>(create);
  static HIDEvent_HIDOrientation? _defaultInstance;

  @$pb.TagNumber(1)
  HIDEvent_HIDOrientationType get orientation => $_getN(0);
  @$pb.TagNumber(1)
  set orientation(HIDEvent_HIDOrientationType value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasOrientation() => $_has(0);
  @$pb.TagNumber(1)
  void clearOrientation() => $_clearField(1);
}

class HIDEvent_HIDShake extends $pb.GeneratedMessage {
  factory HIDEvent_HIDShake() => create();

  HIDEvent_HIDShake._();

  factory HIDEvent_HIDShake.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent_HIDShake.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent.HIDShake',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDShake clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent_HIDShake copyWith(void Function(HIDEvent_HIDShake) updates) =>
      super.copyWith((message) => updates(message as HIDEvent_HIDShake))
          as HIDEvent_HIDShake;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDShake create() => HIDEvent_HIDShake._();
  @$core.override
  HIDEvent_HIDShake createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent_HIDShake getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDEvent_HIDShake>(create);
  static HIDEvent_HIDShake? _defaultInstance;
}

enum HIDEvent_Event { press, swipe, delay, pinch, orientation, shake, notSet }

class HIDEvent extends $pb.GeneratedMessage {
  factory HIDEvent({
    HIDEvent_HIDPress? press,
    HIDEvent_HIDSwipe? swipe,
    HIDEvent_HIDDelay? delay,
    HIDEvent_HIDPinch? pinch,
    HIDEvent_HIDOrientation? orientation,
    HIDEvent_HIDShake? shake,
  }) {
    final result = create();
    if (press != null) result.press = press;
    if (swipe != null) result.swipe = swipe;
    if (delay != null) result.delay = delay;
    if (pinch != null) result.pinch = pinch;
    if (orientation != null) result.orientation = orientation;
    if (shake != null) result.shake = shake;
    return result;
  }

  HIDEvent._();

  factory HIDEvent.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDEvent.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, HIDEvent_Event> _HIDEvent_EventByTag = {
    1: HIDEvent_Event.press,
    2: HIDEvent_Event.swipe,
    3: HIDEvent_Event.delay,
    4: HIDEvent_Event.pinch,
    5: HIDEvent_Event.orientation,
    6: HIDEvent_Event.shake,
    0: HIDEvent_Event.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDEvent',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3, 4, 5, 6])
    ..aOM<HIDEvent_HIDPress>(1, _omitFieldNames ? '' : 'press',
        subBuilder: HIDEvent_HIDPress.create)
    ..aOM<HIDEvent_HIDSwipe>(2, _omitFieldNames ? '' : 'swipe',
        subBuilder: HIDEvent_HIDSwipe.create)
    ..aOM<HIDEvent_HIDDelay>(3, _omitFieldNames ? '' : 'delay',
        subBuilder: HIDEvent_HIDDelay.create)
    ..aOM<HIDEvent_HIDPinch>(4, _omitFieldNames ? '' : 'pinch',
        subBuilder: HIDEvent_HIDPinch.create)
    ..aOM<HIDEvent_HIDOrientation>(5, _omitFieldNames ? '' : 'orientation',
        subBuilder: HIDEvent_HIDOrientation.create)
    ..aOM<HIDEvent_HIDShake>(6, _omitFieldNames ? '' : 'shake',
        subBuilder: HIDEvent_HIDShake.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDEvent copyWith(void Function(HIDEvent) updates) =>
      super.copyWith((message) => updates(message as HIDEvent)) as HIDEvent;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDEvent create() => HIDEvent._();
  @$core.override
  HIDEvent createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDEvent getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<HIDEvent>(create);
  static HIDEvent? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  HIDEvent_Event whichEvent() => _HIDEvent_EventByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  void clearEvent() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  HIDEvent_HIDPress get press => $_getN(0);
  @$pb.TagNumber(1)
  set press(HIDEvent_HIDPress value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPress() => $_has(0);
  @$pb.TagNumber(1)
  void clearPress() => $_clearField(1);
  @$pb.TagNumber(1)
  HIDEvent_HIDPress ensurePress() => $_ensure(0);

  @$pb.TagNumber(2)
  HIDEvent_HIDSwipe get swipe => $_getN(1);
  @$pb.TagNumber(2)
  set swipe(HIDEvent_HIDSwipe value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasSwipe() => $_has(1);
  @$pb.TagNumber(2)
  void clearSwipe() => $_clearField(2);
  @$pb.TagNumber(2)
  HIDEvent_HIDSwipe ensureSwipe() => $_ensure(1);

  @$pb.TagNumber(3)
  HIDEvent_HIDDelay get delay => $_getN(2);
  @$pb.TagNumber(3)
  set delay(HIDEvent_HIDDelay value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasDelay() => $_has(2);
  @$pb.TagNumber(3)
  void clearDelay() => $_clearField(3);
  @$pb.TagNumber(3)
  HIDEvent_HIDDelay ensureDelay() => $_ensure(2);

  @$pb.TagNumber(4)
  HIDEvent_HIDPinch get pinch => $_getN(3);
  @$pb.TagNumber(4)
  set pinch(HIDEvent_HIDPinch value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasPinch() => $_has(3);
  @$pb.TagNumber(4)
  void clearPinch() => $_clearField(4);
  @$pb.TagNumber(4)
  HIDEvent_HIDPinch ensurePinch() => $_ensure(3);

  @$pb.TagNumber(5)
  HIDEvent_HIDOrientation get orientation => $_getN(4);
  @$pb.TagNumber(5)
  set orientation(HIDEvent_HIDOrientation value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasOrientation() => $_has(4);
  @$pb.TagNumber(5)
  void clearOrientation() => $_clearField(5);
  @$pb.TagNumber(5)
  HIDEvent_HIDOrientation ensureOrientation() => $_ensure(4);

  @$pb.TagNumber(6)
  HIDEvent_HIDShake get shake => $_getN(5);
  @$pb.TagNumber(6)
  set shake(HIDEvent_HIDShake value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasShake() => $_has(5);
  @$pb.TagNumber(6)
  void clearShake() => $_clearField(6);
  @$pb.TagNumber(6)
  HIDEvent_HIDShake ensureShake() => $_ensure(5);
}

class HIDResponse extends $pb.GeneratedMessage {
  factory HIDResponse() => create();

  HIDResponse._();

  factory HIDResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HIDResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HIDResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HIDResponse copyWith(void Function(HIDResponse) updates) =>
      super.copyWith((message) => updates(message as HIDResponse))
          as HIDResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HIDResponse create() => HIDResponse._();
  @$core.override
  HIDResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HIDResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HIDResponse>(create);
  static HIDResponse? _defaultInstance;
}

class ConnectRequest extends $pb.GeneratedMessage {
  factory ConnectRequest({
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? metadata,
    $core.String? localFilePath,
  }) {
    final result = create();
    if (metadata != null) result.metadata.addEntries(metadata);
    if (localFilePath != null) result.localFilePath = localFilePath;
    return result;
  }

  ConnectRequest._();

  factory ConnectRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ConnectRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ConnectRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..m<$core.String, $core.String>(1, _omitFieldNames ? '' : 'metadata',
        entryClassName: 'ConnectRequest.MetadataEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('idb'))
    ..aOS(4, _omitFieldNames ? '' : 'localFilePath')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConnectRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConnectRequest copyWith(void Function(ConnectRequest) updates) =>
      super.copyWith((message) => updates(message as ConnectRequest))
          as ConnectRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ConnectRequest create() => ConnectRequest._();
  @$core.override
  ConnectRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ConnectRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ConnectRequest>(create);
  static ConnectRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbMap<$core.String, $core.String> get metadata => $_getMap(0);

  @$pb.TagNumber(4)
  $core.String get localFilePath => $_getSZ(1);
  @$pb.TagNumber(4)
  set localFilePath($core.String value) => $_setString(1, value);
  @$pb.TagNumber(4)
  $core.bool hasLocalFilePath() => $_has(1);
  @$pb.TagNumber(4)
  void clearLocalFilePath() => $_clearField(4);
}

class ConnectResponse extends $pb.GeneratedMessage {
  factory ConnectResponse({
    CompanionInfo? companion,
  }) {
    final result = create();
    if (companion != null) result.companion = companion;
    return result;
  }

  ConnectResponse._();

  factory ConnectResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ConnectResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ConnectResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<CompanionInfo>(1, _omitFieldNames ? '' : 'companion',
        subBuilder: CompanionInfo.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConnectResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConnectResponse copyWith(void Function(ConnectResponse) updates) =>
      super.copyWith((message) => updates(message as ConnectResponse))
          as ConnectResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ConnectResponse create() => ConnectResponse._();
  @$core.override
  ConnectResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ConnectResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ConnectResponse>(create);
  static ConnectResponse? _defaultInstance;

  @$pb.TagNumber(1)
  CompanionInfo get companion => $_getN(0);
  @$pb.TagNumber(1)
  set companion(CompanionInfo value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasCompanion() => $_has(0);
  @$pb.TagNumber(1)
  void clearCompanion() => $_clearField(1);
  @$pb.TagNumber(1)
  CompanionInfo ensureCompanion() => $_ensure(0);
}

class ScreenDimensions extends $pb.GeneratedMessage {
  factory ScreenDimensions({
    $fixnum.Int64? width,
    $fixnum.Int64? height,
    $core.double? density,
    $fixnum.Int64? widthPoints,
    $fixnum.Int64? heightPoints,
  }) {
    final result = create();
    if (width != null) result.width = width;
    if (height != null) result.height = height;
    if (density != null) result.density = density;
    if (widthPoints != null) result.widthPoints = widthPoints;
    if (heightPoints != null) result.heightPoints = heightPoints;
    return result;
  }

  ScreenDimensions._();

  factory ScreenDimensions.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ScreenDimensions.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ScreenDimensions',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$fixnum.Int64>(1, _omitFieldNames ? '' : 'width', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'height', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aD(3, _omitFieldNames ? '' : 'density')
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'widthPoints', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        5, _omitFieldNames ? '' : 'heightPoints', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenDimensions clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScreenDimensions copyWith(void Function(ScreenDimensions) updates) =>
      super.copyWith((message) => updates(message as ScreenDimensions))
          as ScreenDimensions;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ScreenDimensions create() => ScreenDimensions._();
  @$core.override
  ScreenDimensions createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ScreenDimensions getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ScreenDimensions>(create);
  static ScreenDimensions? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get width => $_getI64(0);
  @$pb.TagNumber(1)
  set width($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasWidth() => $_has(0);
  @$pb.TagNumber(1)
  void clearWidth() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get height => $_getI64(1);
  @$pb.TagNumber(2)
  set height($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasHeight() => $_has(1);
  @$pb.TagNumber(2)
  void clearHeight() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get density => $_getN(2);
  @$pb.TagNumber(3)
  set density($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDensity() => $_has(2);
  @$pb.TagNumber(3)
  void clearDensity() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get widthPoints => $_getI64(3);
  @$pb.TagNumber(4)
  set widthPoints($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasWidthPoints() => $_has(3);
  @$pb.TagNumber(4)
  void clearWidthPoints() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get heightPoints => $_getI64(4);
  @$pb.TagNumber(5)
  set heightPoints($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasHeightPoints() => $_has(4);
  @$pb.TagNumber(5)
  void clearHeightPoints() => $_clearField(5);
}

class TargetDescription extends $pb.GeneratedMessage {
  factory TargetDescription({
    $core.String? udid,
    $core.String? name,
    ScreenDimensions? screenDimensions,
    $core.String? state,
    $core.String? targetType,
    $core.String? osVersion,
    $core.String? architecture,
    $core.List<$core.int>? extended,
    $core.List<$core.int>? diagnostics,
  }) {
    final result = create();
    if (udid != null) result.udid = udid;
    if (name != null) result.name = name;
    if (screenDimensions != null) result.screenDimensions = screenDimensions;
    if (state != null) result.state = state;
    if (targetType != null) result.targetType = targetType;
    if (osVersion != null) result.osVersion = osVersion;
    if (architecture != null) result.architecture = architecture;
    if (extended != null) result.extended = extended;
    if (diagnostics != null) result.diagnostics = diagnostics;
    return result;
  }

  TargetDescription._();

  factory TargetDescription.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TargetDescription.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TargetDescription',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'udid')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aOM<ScreenDimensions>(3, _omitFieldNames ? '' : 'screenDimensions',
        subBuilder: ScreenDimensions.create)
    ..aOS(4, _omitFieldNames ? '' : 'state')
    ..aOS(5, _omitFieldNames ? '' : 'targetType')
    ..aOS(6, _omitFieldNames ? '' : 'osVersion')
    ..aOS(7, _omitFieldNames ? '' : 'architecture')
    ..a<$core.List<$core.int>>(
        9, _omitFieldNames ? '' : 'extended', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        10, _omitFieldNames ? '' : 'diagnostics', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TargetDescription clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TargetDescription copyWith(void Function(TargetDescription) updates) =>
      super.copyWith((message) => updates(message as TargetDescription))
          as TargetDescription;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TargetDescription create() => TargetDescription._();
  @$core.override
  TargetDescription createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TargetDescription getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TargetDescription>(create);
  static TargetDescription? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get udid => $_getSZ(0);
  @$pb.TagNumber(1)
  set udid($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUdid() => $_has(0);
  @$pb.TagNumber(1)
  void clearUdid() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  ScreenDimensions get screenDimensions => $_getN(2);
  @$pb.TagNumber(3)
  set screenDimensions(ScreenDimensions value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasScreenDimensions() => $_has(2);
  @$pb.TagNumber(3)
  void clearScreenDimensions() => $_clearField(3);
  @$pb.TagNumber(3)
  ScreenDimensions ensureScreenDimensions() => $_ensure(2);

  @$pb.TagNumber(4)
  $core.String get state => $_getSZ(3);
  @$pb.TagNumber(4)
  set state($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasState() => $_has(3);
  @$pb.TagNumber(4)
  void clearState() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get targetType => $_getSZ(4);
  @$pb.TagNumber(5)
  set targetType($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasTargetType() => $_has(4);
  @$pb.TagNumber(5)
  void clearTargetType() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.String get osVersion => $_getSZ(5);
  @$pb.TagNumber(6)
  set osVersion($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasOsVersion() => $_has(5);
  @$pb.TagNumber(6)
  void clearOsVersion() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.String get architecture => $_getSZ(6);
  @$pb.TagNumber(7)
  set architecture($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasArchitecture() => $_has(6);
  @$pb.TagNumber(7)
  void clearArchitecture() => $_clearField(7);

  @$pb.TagNumber(9)
  $core.List<$core.int> get extended => $_getN(7);
  @$pb.TagNumber(9)
  set extended($core.List<$core.int> value) => $_setBytes(7, value);
  @$pb.TagNumber(9)
  $core.bool hasExtended() => $_has(7);
  @$pb.TagNumber(9)
  void clearExtended() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.List<$core.int> get diagnostics => $_getN(8);
  @$pb.TagNumber(10)
  set diagnostics($core.List<$core.int> value) => $_setBytes(8, value);
  @$pb.TagNumber(10)
  $core.bool hasDiagnostics() => $_has(8);
  @$pb.TagNumber(10)
  void clearDiagnostics() => $_clearField(10);
}

class LogRequest extends $pb.GeneratedMessage {
  factory LogRequest({
    $core.Iterable<$core.String>? arguments,
    LogRequest_Source? source,
  }) {
    final result = create();
    if (arguments != null) result.arguments.addAll(arguments);
    if (source != null) result.source = source;
    return result;
  }

  LogRequest._();

  factory LogRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory LogRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LogRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPS(1, _omitFieldNames ? '' : 'arguments')
    ..aE<LogRequest_Source>(2, _omitFieldNames ? '' : 'source',
        enumValues: LogRequest_Source.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LogRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LogRequest copyWith(void Function(LogRequest) updates) =>
      super.copyWith((message) => updates(message as LogRequest)) as LogRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LogRequest create() => LogRequest._();
  @$core.override
  LogRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static LogRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LogRequest>(create);
  static LogRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get arguments => $_getList(0);

  @$pb.TagNumber(2)
  LogRequest_Source get source => $_getN(1);
  @$pb.TagNumber(2)
  set source(LogRequest_Source value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasSource() => $_has(1);
  @$pb.TagNumber(2)
  void clearSource() => $_clearField(2);
}

class LogResponse extends $pb.GeneratedMessage {
  factory LogResponse({
    $core.List<$core.int>? output,
  }) {
    final result = create();
    if (output != null) result.output = output;
    return result;
  }

  LogResponse._();

  factory LogResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory LogResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LogResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'output', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LogResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LogResponse copyWith(void Function(LogResponse) updates) =>
      super.copyWith((message) => updates(message as LogResponse))
          as LogResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LogResponse create() => LogResponse._();
  @$core.override
  LogResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static LogResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LogResponse>(create);
  static LogResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get output => $_getN(0);
  @$pb.TagNumber(1)
  set output($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasOutput() => $_has(0);
  @$pb.TagNumber(1)
  void clearOutput() => $_clearField(1);
}

class RecordRequest_Start extends $pb.GeneratedMessage {
  factory RecordRequest_Start({
    $core.String? filePath,
  }) {
    final result = create();
    if (filePath != null) result.filePath = filePath;
    return result;
  }

  RecordRequest_Start._();

  factory RecordRequest_Start.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RecordRequest_Start.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RecordRequest.Start',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'filePath')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RecordRequest_Start clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RecordRequest_Start copyWith(void Function(RecordRequest_Start) updates) =>
      super.copyWith((message) => updates(message as RecordRequest_Start))
          as RecordRequest_Start;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RecordRequest_Start create() => RecordRequest_Start._();
  @$core.override
  RecordRequest_Start createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RecordRequest_Start getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RecordRequest_Start>(create);
  static RecordRequest_Start? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get filePath => $_getSZ(0);
  @$pb.TagNumber(1)
  set filePath($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasFilePath() => $_has(0);
  @$pb.TagNumber(1)
  void clearFilePath() => $_clearField(1);
}

class RecordRequest_Stop extends $pb.GeneratedMessage {
  factory RecordRequest_Stop() => create();

  RecordRequest_Stop._();

  factory RecordRequest_Stop.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RecordRequest_Stop.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RecordRequest.Stop',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RecordRequest_Stop clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RecordRequest_Stop copyWith(void Function(RecordRequest_Stop) updates) =>
      super.copyWith((message) => updates(message as RecordRequest_Stop))
          as RecordRequest_Stop;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RecordRequest_Stop create() => RecordRequest_Stop._();
  @$core.override
  RecordRequest_Stop createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RecordRequest_Stop getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RecordRequest_Stop>(create);
  static RecordRequest_Stop? _defaultInstance;
}

enum RecordRequest_Control { start, stop, notSet }

class RecordRequest extends $pb.GeneratedMessage {
  factory RecordRequest({
    RecordRequest_Start? start,
    RecordRequest_Stop? stop,
  }) {
    final result = create();
    if (start != null) result.start = start;
    if (stop != null) result.stop = stop;
    return result;
  }

  RecordRequest._();

  factory RecordRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RecordRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, RecordRequest_Control>
      _RecordRequest_ControlByTag = {
    1: RecordRequest_Control.start,
    2: RecordRequest_Control.stop,
    0: RecordRequest_Control.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RecordRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOM<RecordRequest_Start>(1, _omitFieldNames ? '' : 'start',
        subBuilder: RecordRequest_Start.create)
    ..aOM<RecordRequest_Stop>(2, _omitFieldNames ? '' : 'stop',
        subBuilder: RecordRequest_Stop.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RecordRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RecordRequest copyWith(void Function(RecordRequest) updates) =>
      super.copyWith((message) => updates(message as RecordRequest))
          as RecordRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RecordRequest create() => RecordRequest._();
  @$core.override
  RecordRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RecordRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RecordRequest>(create);
  static RecordRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  RecordRequest_Control whichControl() =>
      _RecordRequest_ControlByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearControl() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  RecordRequest_Start get start => $_getN(0);
  @$pb.TagNumber(1)
  set start(RecordRequest_Start value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStart() => $_has(0);
  @$pb.TagNumber(1)
  void clearStart() => $_clearField(1);
  @$pb.TagNumber(1)
  RecordRequest_Start ensureStart() => $_ensure(0);

  @$pb.TagNumber(2)
  RecordRequest_Stop get stop => $_getN(1);
  @$pb.TagNumber(2)
  set stop(RecordRequest_Stop value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStop() => $_has(1);
  @$pb.TagNumber(2)
  void clearStop() => $_clearField(2);
  @$pb.TagNumber(2)
  RecordRequest_Stop ensureStop() => $_ensure(1);
}

enum RecordResponse_Output { logOutput, payload, notSet }

class RecordResponse extends $pb.GeneratedMessage {
  factory RecordResponse({
    $core.List<$core.int>? logOutput,
    Payload? payload,
  }) {
    final result = create();
    if (logOutput != null) result.logOutput = logOutput;
    if (payload != null) result.payload = payload;
    return result;
  }

  RecordResponse._();

  factory RecordResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RecordResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, RecordResponse_Output>
      _RecordResponse_OutputByTag = {
    1: RecordResponse_Output.logOutput,
    2: RecordResponse_Output.payload,
    0: RecordResponse_Output.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RecordResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'logOutput', $pb.PbFieldType.OY)
    ..aOM<Payload>(2, _omitFieldNames ? '' : 'payload',
        subBuilder: Payload.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RecordResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RecordResponse copyWith(void Function(RecordResponse) updates) =>
      super.copyWith((message) => updates(message as RecordResponse))
          as RecordResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RecordResponse create() => RecordResponse._();
  @$core.override
  RecordResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RecordResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RecordResponse>(create);
  static RecordResponse? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  RecordResponse_Output whichOutput() =>
      _RecordResponse_OutputByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearOutput() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.List<$core.int> get logOutput => $_getN(0);
  @$pb.TagNumber(1)
  set logOutput($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLogOutput() => $_has(0);
  @$pb.TagNumber(1)
  void clearLogOutput() => $_clearField(1);

  @$pb.TagNumber(2)
  Payload get payload => $_getN(1);
  @$pb.TagNumber(2)
  set payload(Payload value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPayload() => $_has(1);
  @$pb.TagNumber(2)
  void clearPayload() => $_clearField(2);
  @$pb.TagNumber(2)
  Payload ensurePayload() => $_ensure(1);
}

class VideoStreamRequest_Start extends $pb.GeneratedMessage {
  factory VideoStreamRequest_Start({
    $core.String? filePath,
    $fixnum.Int64? fps,
    VideoStreamRequest_Format? format,
    $core.double? compressionQuality,
    $core.double? scaleFactor,
    $core.double? avgBitrate,
    $core.double? keyFrameRate,
  }) {
    final result = create();
    if (filePath != null) result.filePath = filePath;
    if (fps != null) result.fps = fps;
    if (format != null) result.format = format;
    if (compressionQuality != null)
      result.compressionQuality = compressionQuality;
    if (scaleFactor != null) result.scaleFactor = scaleFactor;
    if (avgBitrate != null) result.avgBitrate = avgBitrate;
    if (keyFrameRate != null) result.keyFrameRate = keyFrameRate;
    return result;
  }

  VideoStreamRequest_Start._();

  factory VideoStreamRequest_Start.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory VideoStreamRequest_Start.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'VideoStreamRequest.Start',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'filePath')
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'fps', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aE<VideoStreamRequest_Format>(3, _omitFieldNames ? '' : 'format',
        enumValues: VideoStreamRequest_Format.values)
    ..aD(4, _omitFieldNames ? '' : 'compressionQuality')
    ..aD(5, _omitFieldNames ? '' : 'scaleFactor')
    ..aD(6, _omitFieldNames ? '' : 'avgBitrate')
    ..aD(7, _omitFieldNames ? '' : 'keyFrameRate')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VideoStreamRequest_Start clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VideoStreamRequest_Start copyWith(
          void Function(VideoStreamRequest_Start) updates) =>
      super.copyWith((message) => updates(message as VideoStreamRequest_Start))
          as VideoStreamRequest_Start;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static VideoStreamRequest_Start create() => VideoStreamRequest_Start._();
  @$core.override
  VideoStreamRequest_Start createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static VideoStreamRequest_Start getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<VideoStreamRequest_Start>(create);
  static VideoStreamRequest_Start? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get filePath => $_getSZ(0);
  @$pb.TagNumber(1)
  set filePath($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasFilePath() => $_has(0);
  @$pb.TagNumber(1)
  void clearFilePath() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get fps => $_getI64(1);
  @$pb.TagNumber(2)
  set fps($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasFps() => $_has(1);
  @$pb.TagNumber(2)
  void clearFps() => $_clearField(2);

  @$pb.TagNumber(3)
  VideoStreamRequest_Format get format => $_getN(2);
  @$pb.TagNumber(3)
  set format(VideoStreamRequest_Format value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasFormat() => $_has(2);
  @$pb.TagNumber(3)
  void clearFormat() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.double get compressionQuality => $_getN(3);
  @$pb.TagNumber(4)
  set compressionQuality($core.double value) => $_setDouble(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCompressionQuality() => $_has(3);
  @$pb.TagNumber(4)
  void clearCompressionQuality() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.double get scaleFactor => $_getN(4);
  @$pb.TagNumber(5)
  set scaleFactor($core.double value) => $_setDouble(4, value);
  @$pb.TagNumber(5)
  $core.bool hasScaleFactor() => $_has(4);
  @$pb.TagNumber(5)
  void clearScaleFactor() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.double get avgBitrate => $_getN(5);
  @$pb.TagNumber(6)
  set avgBitrate($core.double value) => $_setDouble(5, value);
  @$pb.TagNumber(6)
  $core.bool hasAvgBitrate() => $_has(5);
  @$pb.TagNumber(6)
  void clearAvgBitrate() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.double get keyFrameRate => $_getN(6);
  @$pb.TagNumber(7)
  set keyFrameRate($core.double value) => $_setDouble(6, value);
  @$pb.TagNumber(7)
  $core.bool hasKeyFrameRate() => $_has(6);
  @$pb.TagNumber(7)
  void clearKeyFrameRate() => $_clearField(7);
}

class VideoStreamRequest_Stop extends $pb.GeneratedMessage {
  factory VideoStreamRequest_Stop() => create();

  VideoStreamRequest_Stop._();

  factory VideoStreamRequest_Stop.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory VideoStreamRequest_Stop.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'VideoStreamRequest.Stop',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VideoStreamRequest_Stop clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VideoStreamRequest_Stop copyWith(
          void Function(VideoStreamRequest_Stop) updates) =>
      super.copyWith((message) => updates(message as VideoStreamRequest_Stop))
          as VideoStreamRequest_Stop;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static VideoStreamRequest_Stop create() => VideoStreamRequest_Stop._();
  @$core.override
  VideoStreamRequest_Stop createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static VideoStreamRequest_Stop getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<VideoStreamRequest_Stop>(create);
  static VideoStreamRequest_Stop? _defaultInstance;
}

enum VideoStreamRequest_Control { start, stop, notSet }

class VideoStreamRequest extends $pb.GeneratedMessage {
  factory VideoStreamRequest({
    VideoStreamRequest_Start? start,
    VideoStreamRequest_Stop? stop,
  }) {
    final result = create();
    if (start != null) result.start = start;
    if (stop != null) result.stop = stop;
    return result;
  }

  VideoStreamRequest._();

  factory VideoStreamRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory VideoStreamRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, VideoStreamRequest_Control>
      _VideoStreamRequest_ControlByTag = {
    1: VideoStreamRequest_Control.start,
    2: VideoStreamRequest_Control.stop,
    0: VideoStreamRequest_Control.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'VideoStreamRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOM<VideoStreamRequest_Start>(1, _omitFieldNames ? '' : 'start',
        subBuilder: VideoStreamRequest_Start.create)
    ..aOM<VideoStreamRequest_Stop>(2, _omitFieldNames ? '' : 'stop',
        subBuilder: VideoStreamRequest_Stop.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VideoStreamRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VideoStreamRequest copyWith(void Function(VideoStreamRequest) updates) =>
      super.copyWith((message) => updates(message as VideoStreamRequest))
          as VideoStreamRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static VideoStreamRequest create() => VideoStreamRequest._();
  @$core.override
  VideoStreamRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static VideoStreamRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<VideoStreamRequest>(create);
  static VideoStreamRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  VideoStreamRequest_Control whichControl() =>
      _VideoStreamRequest_ControlByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearControl() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  VideoStreamRequest_Start get start => $_getN(0);
  @$pb.TagNumber(1)
  set start(VideoStreamRequest_Start value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStart() => $_has(0);
  @$pb.TagNumber(1)
  void clearStart() => $_clearField(1);
  @$pb.TagNumber(1)
  VideoStreamRequest_Start ensureStart() => $_ensure(0);

  @$pb.TagNumber(2)
  VideoStreamRequest_Stop get stop => $_getN(1);
  @$pb.TagNumber(2)
  set stop(VideoStreamRequest_Stop value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStop() => $_has(1);
  @$pb.TagNumber(2)
  void clearStop() => $_clearField(2);
  @$pb.TagNumber(2)
  VideoStreamRequest_Stop ensureStop() => $_ensure(1);
}

enum VideoStreamResponse_Output { logOutput, payload, notSet }

class VideoStreamResponse extends $pb.GeneratedMessage {
  factory VideoStreamResponse({
    $core.List<$core.int>? logOutput,
    Payload? payload,
  }) {
    final result = create();
    if (logOutput != null) result.logOutput = logOutput;
    if (payload != null) result.payload = payload;
    return result;
  }

  VideoStreamResponse._();

  factory VideoStreamResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory VideoStreamResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, VideoStreamResponse_Output>
      _VideoStreamResponse_OutputByTag = {
    1: VideoStreamResponse_Output.logOutput,
    2: VideoStreamResponse_Output.payload,
    0: VideoStreamResponse_Output.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'VideoStreamResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'logOutput', $pb.PbFieldType.OY)
    ..aOM<Payload>(2, _omitFieldNames ? '' : 'payload',
        subBuilder: Payload.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VideoStreamResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VideoStreamResponse copyWith(void Function(VideoStreamResponse) updates) =>
      super.copyWith((message) => updates(message as VideoStreamResponse))
          as VideoStreamResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static VideoStreamResponse create() => VideoStreamResponse._();
  @$core.override
  VideoStreamResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static VideoStreamResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<VideoStreamResponse>(create);
  static VideoStreamResponse? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  VideoStreamResponse_Output whichOutput() =>
      _VideoStreamResponse_OutputByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearOutput() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.List<$core.int> get logOutput => $_getN(0);
  @$pb.TagNumber(1)
  set logOutput($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLogOutput() => $_has(0);
  @$pb.TagNumber(1)
  void clearLogOutput() => $_clearField(1);

  @$pb.TagNumber(2)
  Payload get payload => $_getN(1);
  @$pb.TagNumber(2)
  set payload(Payload value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPayload() => $_has(1);
  @$pb.TagNumber(2)
  void clearPayload() => $_clearField(2);
  @$pb.TagNumber(2)
  Payload ensurePayload() => $_ensure(1);
}

class LaunchRequest_Start extends $pb.GeneratedMessage {
  factory LaunchRequest_Start({
    $core.String? bundleId,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? env,
    $core.Iterable<$core.String>? appArgs,
    $core.bool? foregroundIfRunning,
    $core.bool? waitFor,
    $core.bool? waitForDebugger,
    $core.bool? enableRepl,
  }) {
    final result = create();
    if (bundleId != null) result.bundleId = bundleId;
    if (env != null) result.env.addEntries(env);
    if (appArgs != null) result.appArgs.addAll(appArgs);
    if (foregroundIfRunning != null)
      result.foregroundIfRunning = foregroundIfRunning;
    if (waitFor != null) result.waitFor = waitFor;
    if (waitForDebugger != null) result.waitForDebugger = waitForDebugger;
    if (enableRepl != null) result.enableRepl = enableRepl;
    return result;
  }

  LaunchRequest_Start._();

  factory LaunchRequest_Start.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory LaunchRequest_Start.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LaunchRequest.Start',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'bundleId')
    ..m<$core.String, $core.String>(2, _omitFieldNames ? '' : 'env',
        entryClassName: 'LaunchRequest.Start.EnvEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('idb'))
    ..pPS(3, _omitFieldNames ? '' : 'appArgs')
    ..aOB(4, _omitFieldNames ? '' : 'foregroundIfRunning')
    ..aOB(5, _omitFieldNames ? '' : 'waitFor')
    ..aOB(6, _omitFieldNames ? '' : 'waitForDebugger')
    ..aOB(7, _omitFieldNames ? '' : 'enableRepl')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LaunchRequest_Start clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LaunchRequest_Start copyWith(void Function(LaunchRequest_Start) updates) =>
      super.copyWith((message) => updates(message as LaunchRequest_Start))
          as LaunchRequest_Start;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LaunchRequest_Start create() => LaunchRequest_Start._();
  @$core.override
  LaunchRequest_Start createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static LaunchRequest_Start getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LaunchRequest_Start>(create);
  static LaunchRequest_Start? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get bundleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set bundleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBundleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBundleId() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbMap<$core.String, $core.String> get env => $_getMap(1);

  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get appArgs => $_getList(2);

  @$pb.TagNumber(4)
  $core.bool get foregroundIfRunning => $_getBF(3);
  @$pb.TagNumber(4)
  set foregroundIfRunning($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasForegroundIfRunning() => $_has(3);
  @$pb.TagNumber(4)
  void clearForegroundIfRunning() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.bool get waitFor => $_getBF(4);
  @$pb.TagNumber(5)
  set waitFor($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasWaitFor() => $_has(4);
  @$pb.TagNumber(5)
  void clearWaitFor() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.bool get waitForDebugger => $_getBF(5);
  @$pb.TagNumber(6)
  set waitForDebugger($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasWaitForDebugger() => $_has(5);
  @$pb.TagNumber(6)
  void clearWaitForDebugger() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.bool get enableRepl => $_getBF(6);
  @$pb.TagNumber(7)
  set enableRepl($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasEnableRepl() => $_has(6);
  @$pb.TagNumber(7)
  void clearEnableRepl() => $_clearField(7);
}

class LaunchRequest_Stop extends $pb.GeneratedMessage {
  factory LaunchRequest_Stop() => create();

  LaunchRequest_Stop._();

  factory LaunchRequest_Stop.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory LaunchRequest_Stop.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LaunchRequest.Stop',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LaunchRequest_Stop clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LaunchRequest_Stop copyWith(void Function(LaunchRequest_Stop) updates) =>
      super.copyWith((message) => updates(message as LaunchRequest_Stop))
          as LaunchRequest_Stop;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LaunchRequest_Stop create() => LaunchRequest_Stop._();
  @$core.override
  LaunchRequest_Stop createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static LaunchRequest_Stop getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LaunchRequest_Stop>(create);
  static LaunchRequest_Stop? _defaultInstance;
}

enum LaunchRequest_Control { start, stop, notSet }

class LaunchRequest extends $pb.GeneratedMessage {
  factory LaunchRequest({
    LaunchRequest_Start? start,
    LaunchRequest_Stop? stop,
  }) {
    final result = create();
    if (start != null) result.start = start;
    if (stop != null) result.stop = stop;
    return result;
  }

  LaunchRequest._();

  factory LaunchRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory LaunchRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, LaunchRequest_Control>
      _LaunchRequest_ControlByTag = {
    1: LaunchRequest_Control.start,
    2: LaunchRequest_Control.stop,
    0: LaunchRequest_Control.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LaunchRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOM<LaunchRequest_Start>(1, _omitFieldNames ? '' : 'start',
        subBuilder: LaunchRequest_Start.create)
    ..aOM<LaunchRequest_Stop>(2, _omitFieldNames ? '' : 'stop',
        subBuilder: LaunchRequest_Stop.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LaunchRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LaunchRequest copyWith(void Function(LaunchRequest) updates) =>
      super.copyWith((message) => updates(message as LaunchRequest))
          as LaunchRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LaunchRequest create() => LaunchRequest._();
  @$core.override
  LaunchRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static LaunchRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LaunchRequest>(create);
  static LaunchRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  LaunchRequest_Control whichControl() =>
      _LaunchRequest_ControlByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearControl() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  LaunchRequest_Start get start => $_getN(0);
  @$pb.TagNumber(1)
  set start(LaunchRequest_Start value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStart() => $_has(0);
  @$pb.TagNumber(1)
  void clearStart() => $_clearField(1);
  @$pb.TagNumber(1)
  LaunchRequest_Start ensureStart() => $_ensure(0);

  @$pb.TagNumber(2)
  LaunchRequest_Stop get stop => $_getN(1);
  @$pb.TagNumber(2)
  set stop(LaunchRequest_Stop value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStop() => $_has(1);
  @$pb.TagNumber(2)
  void clearStop() => $_clearField(2);
  @$pb.TagNumber(2)
  LaunchRequest_Stop ensureStop() => $_ensure(1);
}

class LaunchResponse extends $pb.GeneratedMessage {
  factory LaunchResponse({
    ProcessOutput? output,
    DebuggerInfo? debugger,
  }) {
    final result = create();
    if (output != null) result.output = output;
    if (debugger != null) result.debugger = debugger;
    return result;
  }

  LaunchResponse._();

  factory LaunchResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory LaunchResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LaunchResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<ProcessOutput>(3, _omitFieldNames ? '' : 'output',
        subBuilder: ProcessOutput.create)
    ..aOM<DebuggerInfo>(4, _omitFieldNames ? '' : 'debugger',
        subBuilder: DebuggerInfo.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LaunchResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LaunchResponse copyWith(void Function(LaunchResponse) updates) =>
      super.copyWith((message) => updates(message as LaunchResponse))
          as LaunchResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LaunchResponse create() => LaunchResponse._();
  @$core.override
  LaunchResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static LaunchResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LaunchResponse>(create);
  static LaunchResponse? _defaultInstance;

  @$pb.TagNumber(3)
  ProcessOutput get output => $_getN(0);
  @$pb.TagNumber(3)
  set output(ProcessOutput value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasOutput() => $_has(0);
  @$pb.TagNumber(3)
  void clearOutput() => $_clearField(3);
  @$pb.TagNumber(3)
  ProcessOutput ensureOutput() => $_ensure(0);

  @$pb.TagNumber(4)
  DebuggerInfo get debugger => $_getN(1);
  @$pb.TagNumber(4)
  set debugger(DebuggerInfo value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasDebugger() => $_has(1);
  @$pb.TagNumber(4)
  void clearDebugger() => $_clearField(4);
  @$pb.TagNumber(4)
  DebuggerInfo ensureDebugger() => $_ensure(1);
}

class AddMediaRequest extends $pb.GeneratedMessage {
  factory AddMediaRequest({
    Payload? payload,
  }) {
    final result = create();
    if (payload != null) result.payload = payload;
    return result;
  }

  AddMediaRequest._();

  factory AddMediaRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AddMediaRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AddMediaRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<Payload>(1, _omitFieldNames ? '' : 'payload',
        subBuilder: Payload.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddMediaRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddMediaRequest copyWith(void Function(AddMediaRequest) updates) =>
      super.copyWith((message) => updates(message as AddMediaRequest))
          as AddMediaRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AddMediaRequest create() => AddMediaRequest._();
  @$core.override
  AddMediaRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AddMediaRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AddMediaRequest>(create);
  static AddMediaRequest? _defaultInstance;

  @$pb.TagNumber(1)
  Payload get payload => $_getN(0);
  @$pb.TagNumber(1)
  set payload(Payload value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPayload() => $_has(0);
  @$pb.TagNumber(1)
  void clearPayload() => $_clearField(1);
  @$pb.TagNumber(1)
  Payload ensurePayload() => $_ensure(0);
}

class AddMediaResponse extends $pb.GeneratedMessage {
  factory AddMediaResponse() => create();

  AddMediaResponse._();

  factory AddMediaResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AddMediaResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AddMediaResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddMediaResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddMediaResponse copyWith(void Function(AddMediaResponse) updates) =>
      super.copyWith((message) => updates(message as AddMediaResponse))
          as AddMediaResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AddMediaResponse create() => AddMediaResponse._();
  @$core.override
  AddMediaResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AddMediaResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AddMediaResponse>(create);
  static AddMediaResponse? _defaultInstance;
}

class InstrumentsRunRequest_InstrumentsTimings extends $pb.GeneratedMessage {
  factory InstrumentsRunRequest_InstrumentsTimings({
    $core.double? terminateTimeout,
    $core.double? launchRetryTimeout,
    $core.double? launchErrorTimeout,
    $core.double? operationDuration,
  }) {
    final result = create();
    if (terminateTimeout != null) result.terminateTimeout = terminateTimeout;
    if (launchRetryTimeout != null)
      result.launchRetryTimeout = launchRetryTimeout;
    if (launchErrorTimeout != null)
      result.launchErrorTimeout = launchErrorTimeout;
    if (operationDuration != null) result.operationDuration = operationDuration;
    return result;
  }

  InstrumentsRunRequest_InstrumentsTimings._();

  factory InstrumentsRunRequest_InstrumentsTimings.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory InstrumentsRunRequest_InstrumentsTimings.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InstrumentsRunRequest.InstrumentsTimings',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aD(1, _omitFieldNames ? '' : 'terminateTimeout')
    ..aD(2, _omitFieldNames ? '' : 'launchRetryTimeout')
    ..aD(3, _omitFieldNames ? '' : 'launchErrorTimeout')
    ..aD(4, _omitFieldNames ? '' : 'operationDuration')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstrumentsRunRequest_InstrumentsTimings clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstrumentsRunRequest_InstrumentsTimings copyWith(
          void Function(InstrumentsRunRequest_InstrumentsTimings) updates) =>
      super.copyWith((message) =>
              updates(message as InstrumentsRunRequest_InstrumentsTimings))
          as InstrumentsRunRequest_InstrumentsTimings;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static InstrumentsRunRequest_InstrumentsTimings create() =>
      InstrumentsRunRequest_InstrumentsTimings._();
  @$core.override
  InstrumentsRunRequest_InstrumentsTimings createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static InstrumentsRunRequest_InstrumentsTimings getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<
          InstrumentsRunRequest_InstrumentsTimings>(create);
  static InstrumentsRunRequest_InstrumentsTimings? _defaultInstance;

  @$pb.TagNumber(1)
  $core.double get terminateTimeout => $_getN(0);
  @$pb.TagNumber(1)
  set terminateTimeout($core.double value) => $_setDouble(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTerminateTimeout() => $_has(0);
  @$pb.TagNumber(1)
  void clearTerminateTimeout() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.double get launchRetryTimeout => $_getN(1);
  @$pb.TagNumber(2)
  set launchRetryTimeout($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasLaunchRetryTimeout() => $_has(1);
  @$pb.TagNumber(2)
  void clearLaunchRetryTimeout() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get launchErrorTimeout => $_getN(2);
  @$pb.TagNumber(3)
  set launchErrorTimeout($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasLaunchErrorTimeout() => $_has(2);
  @$pb.TagNumber(3)
  void clearLaunchErrorTimeout() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.double get operationDuration => $_getN(3);
  @$pb.TagNumber(4)
  set operationDuration($core.double value) => $_setDouble(3, value);
  @$pb.TagNumber(4)
  $core.bool hasOperationDuration() => $_has(3);
  @$pb.TagNumber(4)
  void clearOperationDuration() => $_clearField(4);
}

class InstrumentsRunRequest_Start extends $pb.GeneratedMessage {
  factory InstrumentsRunRequest_Start({
    $core.String? templateName,
    $core.String? appBundleId,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? environment,
    $core.Iterable<$core.String>? arguments,
    InstrumentsRunRequest_InstrumentsTimings? timings,
    $core.Iterable<$core.String>? toolArguments,
  }) {
    final result = create();
    if (templateName != null) result.templateName = templateName;
    if (appBundleId != null) result.appBundleId = appBundleId;
    if (environment != null) result.environment.addEntries(environment);
    if (arguments != null) result.arguments.addAll(arguments);
    if (timings != null) result.timings = timings;
    if (toolArguments != null) result.toolArguments.addAll(toolArguments);
    return result;
  }

  InstrumentsRunRequest_Start._();

  factory InstrumentsRunRequest_Start.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory InstrumentsRunRequest_Start.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InstrumentsRunRequest.Start',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(2, _omitFieldNames ? '' : 'templateName')
    ..aOS(3, _omitFieldNames ? '' : 'appBundleId')
    ..m<$core.String, $core.String>(4, _omitFieldNames ? '' : 'environment',
        entryClassName: 'InstrumentsRunRequest.Start.EnvironmentEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('idb'))
    ..pPS(5, _omitFieldNames ? '' : 'arguments')
    ..aOM<InstrumentsRunRequest_InstrumentsTimings>(
        6, _omitFieldNames ? '' : 'timings',
        subBuilder: InstrumentsRunRequest_InstrumentsTimings.create)
    ..pPS(7, _omitFieldNames ? '' : 'toolArguments')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstrumentsRunRequest_Start clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstrumentsRunRequest_Start copyWith(
          void Function(InstrumentsRunRequest_Start) updates) =>
      super.copyWith(
              (message) => updates(message as InstrumentsRunRequest_Start))
          as InstrumentsRunRequest_Start;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static InstrumentsRunRequest_Start create() =>
      InstrumentsRunRequest_Start._();
  @$core.override
  InstrumentsRunRequest_Start createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static InstrumentsRunRequest_Start getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<InstrumentsRunRequest_Start>(create);
  static InstrumentsRunRequest_Start? _defaultInstance;

  @$pb.TagNumber(2)
  $core.String get templateName => $_getSZ(0);
  @$pb.TagNumber(2)
  set templateName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(2)
  $core.bool hasTemplateName() => $_has(0);
  @$pb.TagNumber(2)
  void clearTemplateName() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get appBundleId => $_getSZ(1);
  @$pb.TagNumber(3)
  set appBundleId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(3)
  $core.bool hasAppBundleId() => $_has(1);
  @$pb.TagNumber(3)
  void clearAppBundleId() => $_clearField(3);

  @$pb.TagNumber(4)
  $pb.PbMap<$core.String, $core.String> get environment => $_getMap(2);

  @$pb.TagNumber(5)
  $pb.PbList<$core.String> get arguments => $_getList(3);

  @$pb.TagNumber(6)
  InstrumentsRunRequest_InstrumentsTimings get timings => $_getN(4);
  @$pb.TagNumber(6)
  set timings(InstrumentsRunRequest_InstrumentsTimings value) =>
      $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasTimings() => $_has(4);
  @$pb.TagNumber(6)
  void clearTimings() => $_clearField(6);
  @$pb.TagNumber(6)
  InstrumentsRunRequest_InstrumentsTimings ensureTimings() => $_ensure(4);

  @$pb.TagNumber(7)
  $pb.PbList<$core.String> get toolArguments => $_getList(5);
}

class InstrumentsRunRequest_Stop extends $pb.GeneratedMessage {
  factory InstrumentsRunRequest_Stop({
    $core.Iterable<$core.String>? postProcessArguments,
  }) {
    final result = create();
    if (postProcessArguments != null)
      result.postProcessArguments.addAll(postProcessArguments);
    return result;
  }

  InstrumentsRunRequest_Stop._();

  factory InstrumentsRunRequest_Stop.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory InstrumentsRunRequest_Stop.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InstrumentsRunRequest.Stop',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPS(1, _omitFieldNames ? '' : 'postProcessArguments')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstrumentsRunRequest_Stop clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstrumentsRunRequest_Stop copyWith(
          void Function(InstrumentsRunRequest_Stop) updates) =>
      super.copyWith(
              (message) => updates(message as InstrumentsRunRequest_Stop))
          as InstrumentsRunRequest_Stop;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static InstrumentsRunRequest_Stop create() => InstrumentsRunRequest_Stop._();
  @$core.override
  InstrumentsRunRequest_Stop createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static InstrumentsRunRequest_Stop getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<InstrumentsRunRequest_Stop>(create);
  static InstrumentsRunRequest_Stop? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get postProcessArguments => $_getList(0);
}

enum InstrumentsRunRequest_Control { start, stop, notSet }

class InstrumentsRunRequest extends $pb.GeneratedMessage {
  factory InstrumentsRunRequest({
    InstrumentsRunRequest_Start? start,
    InstrumentsRunRequest_Stop? stop,
  }) {
    final result = create();
    if (start != null) result.start = start;
    if (stop != null) result.stop = stop;
    return result;
  }

  InstrumentsRunRequest._();

  factory InstrumentsRunRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory InstrumentsRunRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, InstrumentsRunRequest_Control>
      _InstrumentsRunRequest_ControlByTag = {
    1: InstrumentsRunRequest_Control.start,
    2: InstrumentsRunRequest_Control.stop,
    0: InstrumentsRunRequest_Control.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InstrumentsRunRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOM<InstrumentsRunRequest_Start>(1, _omitFieldNames ? '' : 'start',
        subBuilder: InstrumentsRunRequest_Start.create)
    ..aOM<InstrumentsRunRequest_Stop>(2, _omitFieldNames ? '' : 'stop',
        subBuilder: InstrumentsRunRequest_Stop.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstrumentsRunRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstrumentsRunRequest copyWith(
          void Function(InstrumentsRunRequest) updates) =>
      super.copyWith((message) => updates(message as InstrumentsRunRequest))
          as InstrumentsRunRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static InstrumentsRunRequest create() => InstrumentsRunRequest._();
  @$core.override
  InstrumentsRunRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static InstrumentsRunRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<InstrumentsRunRequest>(create);
  static InstrumentsRunRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  InstrumentsRunRequest_Control whichControl() =>
      _InstrumentsRunRequest_ControlByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearControl() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  InstrumentsRunRequest_Start get start => $_getN(0);
  @$pb.TagNumber(1)
  set start(InstrumentsRunRequest_Start value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStart() => $_has(0);
  @$pb.TagNumber(1)
  void clearStart() => $_clearField(1);
  @$pb.TagNumber(1)
  InstrumentsRunRequest_Start ensureStart() => $_ensure(0);

  @$pb.TagNumber(2)
  InstrumentsRunRequest_Stop get stop => $_getN(1);
  @$pb.TagNumber(2)
  set stop(InstrumentsRunRequest_Stop value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStop() => $_has(1);
  @$pb.TagNumber(2)
  void clearStop() => $_clearField(2);
  @$pb.TagNumber(2)
  InstrumentsRunRequest_Stop ensureStop() => $_ensure(1);
}

enum InstrumentsRunResponse_Output { logOutput, payload, state, notSet }

class InstrumentsRunResponse extends $pb.GeneratedMessage {
  factory InstrumentsRunResponse({
    $core.List<$core.int>? logOutput,
    Payload? payload,
    InstrumentsRunResponse_State? state,
  }) {
    final result = create();
    if (logOutput != null) result.logOutput = logOutput;
    if (payload != null) result.payload = payload;
    if (state != null) result.state = state;
    return result;
  }

  InstrumentsRunResponse._();

  factory InstrumentsRunResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory InstrumentsRunResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, InstrumentsRunResponse_Output>
      _InstrumentsRunResponse_OutputByTag = {
    1: InstrumentsRunResponse_Output.logOutput,
    2: InstrumentsRunResponse_Output.payload,
    3: InstrumentsRunResponse_Output.state,
    0: InstrumentsRunResponse_Output.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InstrumentsRunResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3])
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'logOutput', $pb.PbFieldType.OY)
    ..aOM<Payload>(2, _omitFieldNames ? '' : 'payload',
        subBuilder: Payload.create)
    ..aE<InstrumentsRunResponse_State>(3, _omitFieldNames ? '' : 'state',
        enumValues: InstrumentsRunResponse_State.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstrumentsRunResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstrumentsRunResponse copyWith(
          void Function(InstrumentsRunResponse) updates) =>
      super.copyWith((message) => updates(message as InstrumentsRunResponse))
          as InstrumentsRunResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static InstrumentsRunResponse create() => InstrumentsRunResponse._();
  @$core.override
  InstrumentsRunResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static InstrumentsRunResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<InstrumentsRunResponse>(create);
  static InstrumentsRunResponse? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  InstrumentsRunResponse_Output whichOutput() =>
      _InstrumentsRunResponse_OutputByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearOutput() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.List<$core.int> get logOutput => $_getN(0);
  @$pb.TagNumber(1)
  set logOutput($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLogOutput() => $_has(0);
  @$pb.TagNumber(1)
  void clearLogOutput() => $_clearField(1);

  @$pb.TagNumber(2)
  Payload get payload => $_getN(1);
  @$pb.TagNumber(2)
  set payload(Payload value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPayload() => $_has(1);
  @$pb.TagNumber(2)
  void clearPayload() => $_clearField(2);
  @$pb.TagNumber(2)
  Payload ensurePayload() => $_ensure(1);

  @$pb.TagNumber(3)
  InstrumentsRunResponse_State get state => $_getN(2);
  @$pb.TagNumber(3)
  set state(InstrumentsRunResponse_State value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasState() => $_has(2);
  @$pb.TagNumber(3)
  void clearState() => $_clearField(3);
}

class XctraceRecordRequest_LauchProcess extends $pb.GeneratedMessage {
  factory XctraceRecordRequest_LauchProcess({
    $core.String? processToLaunch,
    $core.Iterable<$core.String>? launchArgs,
    $core.String? targetStdin,
    $core.String? targetStdout,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? processEnv,
  }) {
    final result = create();
    if (processToLaunch != null) result.processToLaunch = processToLaunch;
    if (launchArgs != null) result.launchArgs.addAll(launchArgs);
    if (targetStdin != null) result.targetStdin = targetStdin;
    if (targetStdout != null) result.targetStdout = targetStdout;
    if (processEnv != null) result.processEnv.addEntries(processEnv);
    return result;
  }

  XctraceRecordRequest_LauchProcess._();

  factory XctraceRecordRequest_LauchProcess.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctraceRecordRequest_LauchProcess.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctraceRecordRequest.LauchProcess',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'processToLaunch')
    ..pPS(2, _omitFieldNames ? '' : 'launchArgs')
    ..aOS(3, _omitFieldNames ? '' : 'targetStdin')
    ..aOS(4, _omitFieldNames ? '' : 'targetStdout')
    ..m<$core.String, $core.String>(5, _omitFieldNames ? '' : 'processEnv',
        entryClassName: 'XctraceRecordRequest.LauchProcess.ProcessEnvEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('idb'))
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordRequest_LauchProcess clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordRequest_LauchProcess copyWith(
          void Function(XctraceRecordRequest_LauchProcess) updates) =>
      super.copyWith((message) =>
              updates(message as XctraceRecordRequest_LauchProcess))
          as XctraceRecordRequest_LauchProcess;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctraceRecordRequest_LauchProcess create() =>
      XctraceRecordRequest_LauchProcess._();
  @$core.override
  XctraceRecordRequest_LauchProcess createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctraceRecordRequest_LauchProcess getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctraceRecordRequest_LauchProcess>(
          create);
  static XctraceRecordRequest_LauchProcess? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get processToLaunch => $_getSZ(0);
  @$pb.TagNumber(1)
  set processToLaunch($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasProcessToLaunch() => $_has(0);
  @$pb.TagNumber(1)
  void clearProcessToLaunch() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<$core.String> get launchArgs => $_getList(1);

  @$pb.TagNumber(3)
  $core.String get targetStdin => $_getSZ(2);
  @$pb.TagNumber(3)
  set targetStdin($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTargetStdin() => $_has(2);
  @$pb.TagNumber(3)
  void clearTargetStdin() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get targetStdout => $_getSZ(3);
  @$pb.TagNumber(4)
  set targetStdout($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasTargetStdout() => $_has(3);
  @$pb.TagNumber(4)
  void clearTargetStdout() => $_clearField(4);

  @$pb.TagNumber(5)
  $pb.PbMap<$core.String, $core.String> get processEnv => $_getMap(4);
}

enum XctraceRecordRequest_Target_Target {
  allProcesses,
  processToAttach,
  launchProcess,
  notSet
}

class XctraceRecordRequest_Target extends $pb.GeneratedMessage {
  factory XctraceRecordRequest_Target({
    $core.bool? allProcesses,
    $core.String? processToAttach,
    XctraceRecordRequest_LauchProcess? launchProcess,
  }) {
    final result = create();
    if (allProcesses != null) result.allProcesses = allProcesses;
    if (processToAttach != null) result.processToAttach = processToAttach;
    if (launchProcess != null) result.launchProcess = launchProcess;
    return result;
  }

  XctraceRecordRequest_Target._();

  factory XctraceRecordRequest_Target.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctraceRecordRequest_Target.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, XctraceRecordRequest_Target_Target>
      _XctraceRecordRequest_Target_TargetByTag = {
    1: XctraceRecordRequest_Target_Target.allProcesses,
    2: XctraceRecordRequest_Target_Target.processToAttach,
    3: XctraceRecordRequest_Target_Target.launchProcess,
    0: XctraceRecordRequest_Target_Target.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctraceRecordRequest.Target',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3])
    ..aOB(1, _omitFieldNames ? '' : 'allProcesses')
    ..aOS(2, _omitFieldNames ? '' : 'processToAttach')
    ..aOM<XctraceRecordRequest_LauchProcess>(
        3, _omitFieldNames ? '' : 'launchProcess',
        subBuilder: XctraceRecordRequest_LauchProcess.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordRequest_Target clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordRequest_Target copyWith(
          void Function(XctraceRecordRequest_Target) updates) =>
      super.copyWith(
              (message) => updates(message as XctraceRecordRequest_Target))
          as XctraceRecordRequest_Target;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctraceRecordRequest_Target create() =>
      XctraceRecordRequest_Target._();
  @$core.override
  XctraceRecordRequest_Target createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctraceRecordRequest_Target getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctraceRecordRequest_Target>(create);
  static XctraceRecordRequest_Target? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  XctraceRecordRequest_Target_Target whichTarget() =>
      _XctraceRecordRequest_Target_TargetByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearTarget() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.bool get allProcesses => $_getBF(0);
  @$pb.TagNumber(1)
  set allProcesses($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAllProcesses() => $_has(0);
  @$pb.TagNumber(1)
  void clearAllProcesses() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get processToAttach => $_getSZ(1);
  @$pb.TagNumber(2)
  set processToAttach($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasProcessToAttach() => $_has(1);
  @$pb.TagNumber(2)
  void clearProcessToAttach() => $_clearField(2);

  @$pb.TagNumber(3)
  XctraceRecordRequest_LauchProcess get launchProcess => $_getN(2);
  @$pb.TagNumber(3)
  set launchProcess(XctraceRecordRequest_LauchProcess value) =>
      $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasLaunchProcess() => $_has(2);
  @$pb.TagNumber(3)
  void clearLaunchProcess() => $_clearField(3);
  @$pb.TagNumber(3)
  XctraceRecordRequest_LauchProcess ensureLaunchProcess() => $_ensure(2);
}

class XctraceRecordRequest_Start extends $pb.GeneratedMessage {
  factory XctraceRecordRequest_Start({
    $core.String? templateName,
    $core.double? timeLimit,
    $core.String? package,
    XctraceRecordRequest_Target? target,
  }) {
    final result = create();
    if (templateName != null) result.templateName = templateName;
    if (timeLimit != null) result.timeLimit = timeLimit;
    if (package != null) result.package = package;
    if (target != null) result.target = target;
    return result;
  }

  XctraceRecordRequest_Start._();

  factory XctraceRecordRequest_Start.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctraceRecordRequest_Start.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctraceRecordRequest.Start',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'templateName')
    ..aD(2, _omitFieldNames ? '' : 'timeLimit')
    ..aOS(3, _omitFieldNames ? '' : 'package')
    ..aOM<XctraceRecordRequest_Target>(4, _omitFieldNames ? '' : 'target',
        subBuilder: XctraceRecordRequest_Target.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordRequest_Start clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordRequest_Start copyWith(
          void Function(XctraceRecordRequest_Start) updates) =>
      super.copyWith(
              (message) => updates(message as XctraceRecordRequest_Start))
          as XctraceRecordRequest_Start;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctraceRecordRequest_Start create() => XctraceRecordRequest_Start._();
  @$core.override
  XctraceRecordRequest_Start createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctraceRecordRequest_Start getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctraceRecordRequest_Start>(create);
  static XctraceRecordRequest_Start? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get templateName => $_getSZ(0);
  @$pb.TagNumber(1)
  set templateName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTemplateName() => $_has(0);
  @$pb.TagNumber(1)
  void clearTemplateName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.double get timeLimit => $_getN(1);
  @$pb.TagNumber(2)
  set timeLimit($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTimeLimit() => $_has(1);
  @$pb.TagNumber(2)
  void clearTimeLimit() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get package => $_getSZ(2);
  @$pb.TagNumber(3)
  set package($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPackage() => $_has(2);
  @$pb.TagNumber(3)
  void clearPackage() => $_clearField(3);

  @$pb.TagNumber(4)
  XctraceRecordRequest_Target get target => $_getN(3);
  @$pb.TagNumber(4)
  set target(XctraceRecordRequest_Target value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasTarget() => $_has(3);
  @$pb.TagNumber(4)
  void clearTarget() => $_clearField(4);
  @$pb.TagNumber(4)
  XctraceRecordRequest_Target ensureTarget() => $_ensure(3);
}

class XctraceRecordRequest_Stop extends $pb.GeneratedMessage {
  factory XctraceRecordRequest_Stop({
    $core.double? timeout,
    $core.Iterable<$core.String>? args,
  }) {
    final result = create();
    if (timeout != null) result.timeout = timeout;
    if (args != null) result.args.addAll(args);
    return result;
  }

  XctraceRecordRequest_Stop._();

  factory XctraceRecordRequest_Stop.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctraceRecordRequest_Stop.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctraceRecordRequest.Stop',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aD(1, _omitFieldNames ? '' : 'timeout')
    ..pPS(2, _omitFieldNames ? '' : 'args')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordRequest_Stop clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordRequest_Stop copyWith(
          void Function(XctraceRecordRequest_Stop) updates) =>
      super.copyWith((message) => updates(message as XctraceRecordRequest_Stop))
          as XctraceRecordRequest_Stop;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctraceRecordRequest_Stop create() => XctraceRecordRequest_Stop._();
  @$core.override
  XctraceRecordRequest_Stop createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctraceRecordRequest_Stop getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctraceRecordRequest_Stop>(create);
  static XctraceRecordRequest_Stop? _defaultInstance;

  @$pb.TagNumber(1)
  $core.double get timeout => $_getN(0);
  @$pb.TagNumber(1)
  set timeout($core.double value) => $_setDouble(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTimeout() => $_has(0);
  @$pb.TagNumber(1)
  void clearTimeout() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<$core.String> get args => $_getList(1);
}

enum XctraceRecordRequest_Control { start, stop, notSet }

class XctraceRecordRequest extends $pb.GeneratedMessage {
  factory XctraceRecordRequest({
    XctraceRecordRequest_Start? start,
    XctraceRecordRequest_Stop? stop,
  }) {
    final result = create();
    if (start != null) result.start = start;
    if (stop != null) result.stop = stop;
    return result;
  }

  XctraceRecordRequest._();

  factory XctraceRecordRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctraceRecordRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, XctraceRecordRequest_Control>
      _XctraceRecordRequest_ControlByTag = {
    1: XctraceRecordRequest_Control.start,
    2: XctraceRecordRequest_Control.stop,
    0: XctraceRecordRequest_Control.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctraceRecordRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOM<XctraceRecordRequest_Start>(1, _omitFieldNames ? '' : 'start',
        subBuilder: XctraceRecordRequest_Start.create)
    ..aOM<XctraceRecordRequest_Stop>(2, _omitFieldNames ? '' : 'stop',
        subBuilder: XctraceRecordRequest_Stop.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordRequest copyWith(void Function(XctraceRecordRequest) updates) =>
      super.copyWith((message) => updates(message as XctraceRecordRequest))
          as XctraceRecordRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctraceRecordRequest create() => XctraceRecordRequest._();
  @$core.override
  XctraceRecordRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctraceRecordRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctraceRecordRequest>(create);
  static XctraceRecordRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  XctraceRecordRequest_Control whichControl() =>
      _XctraceRecordRequest_ControlByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearControl() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  XctraceRecordRequest_Start get start => $_getN(0);
  @$pb.TagNumber(1)
  set start(XctraceRecordRequest_Start value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStart() => $_has(0);
  @$pb.TagNumber(1)
  void clearStart() => $_clearField(1);
  @$pb.TagNumber(1)
  XctraceRecordRequest_Start ensureStart() => $_ensure(0);

  @$pb.TagNumber(2)
  XctraceRecordRequest_Stop get stop => $_getN(1);
  @$pb.TagNumber(2)
  set stop(XctraceRecordRequest_Stop value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStop() => $_has(1);
  @$pb.TagNumber(2)
  void clearStop() => $_clearField(2);
  @$pb.TagNumber(2)
  XctraceRecordRequest_Stop ensureStop() => $_ensure(1);
}

enum XctraceRecordResponse_Output { log, payload, state, notSet }

class XctraceRecordResponse extends $pb.GeneratedMessage {
  factory XctraceRecordResponse({
    $core.List<$core.int>? log,
    Payload? payload,
    XctraceRecordResponse_State? state,
  }) {
    final result = create();
    if (log != null) result.log = log;
    if (payload != null) result.payload = payload;
    if (state != null) result.state = state;
    return result;
  }

  XctraceRecordResponse._();

  factory XctraceRecordResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctraceRecordResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, XctraceRecordResponse_Output>
      _XctraceRecordResponse_OutputByTag = {
    1: XctraceRecordResponse_Output.log,
    2: XctraceRecordResponse_Output.payload,
    3: XctraceRecordResponse_Output.state,
    0: XctraceRecordResponse_Output.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctraceRecordResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3])
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'log', $pb.PbFieldType.OY)
    ..aOM<Payload>(2, _omitFieldNames ? '' : 'payload',
        subBuilder: Payload.create)
    ..aE<XctraceRecordResponse_State>(3, _omitFieldNames ? '' : 'state',
        enumValues: XctraceRecordResponse_State.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctraceRecordResponse copyWith(
          void Function(XctraceRecordResponse) updates) =>
      super.copyWith((message) => updates(message as XctraceRecordResponse))
          as XctraceRecordResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctraceRecordResponse create() => XctraceRecordResponse._();
  @$core.override
  XctraceRecordResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctraceRecordResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctraceRecordResponse>(create);
  static XctraceRecordResponse? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  XctraceRecordResponse_Output whichOutput() =>
      _XctraceRecordResponse_OutputByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearOutput() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.List<$core.int> get log => $_getN(0);
  @$pb.TagNumber(1)
  set log($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLog() => $_has(0);
  @$pb.TagNumber(1)
  void clearLog() => $_clearField(1);

  @$pb.TagNumber(2)
  Payload get payload => $_getN(1);
  @$pb.TagNumber(2)
  set payload(Payload value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPayload() => $_has(1);
  @$pb.TagNumber(2)
  void clearPayload() => $_clearField(2);
  @$pb.TagNumber(2)
  Payload ensurePayload() => $_ensure(1);

  @$pb.TagNumber(3)
  XctraceRecordResponse_State get state => $_getN(2);
  @$pb.TagNumber(3)
  set state(XctraceRecordResponse_State value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasState() => $_has(2);
  @$pb.TagNumber(3)
  void clearState() => $_clearField(3);
}

class DebugServerRequest_Start extends $pb.GeneratedMessage {
  factory DebugServerRequest_Start({
    $core.String? bundleId,
  }) {
    final result = create();
    if (bundleId != null) result.bundleId = bundleId;
    return result;
  }

  DebugServerRequest_Start._();

  factory DebugServerRequest_Start.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DebugServerRequest_Start.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DebugServerRequest.Start',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'bundleId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerRequest_Start clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerRequest_Start copyWith(
          void Function(DebugServerRequest_Start) updates) =>
      super.copyWith((message) => updates(message as DebugServerRequest_Start))
          as DebugServerRequest_Start;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DebugServerRequest_Start create() => DebugServerRequest_Start._();
  @$core.override
  DebugServerRequest_Start createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DebugServerRequest_Start getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DebugServerRequest_Start>(create);
  static DebugServerRequest_Start? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get bundleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set bundleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBundleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBundleId() => $_clearField(1);
}

class DebugServerRequest_Status extends $pb.GeneratedMessage {
  factory DebugServerRequest_Status() => create();

  DebugServerRequest_Status._();

  factory DebugServerRequest_Status.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DebugServerRequest_Status.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DebugServerRequest.Status',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerRequest_Status clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerRequest_Status copyWith(
          void Function(DebugServerRequest_Status) updates) =>
      super.copyWith((message) => updates(message as DebugServerRequest_Status))
          as DebugServerRequest_Status;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DebugServerRequest_Status create() => DebugServerRequest_Status._();
  @$core.override
  DebugServerRequest_Status createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DebugServerRequest_Status getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DebugServerRequest_Status>(create);
  static DebugServerRequest_Status? _defaultInstance;
}

class DebugServerRequest_Stop extends $pb.GeneratedMessage {
  factory DebugServerRequest_Stop() => create();

  DebugServerRequest_Stop._();

  factory DebugServerRequest_Stop.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DebugServerRequest_Stop.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DebugServerRequest.Stop',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerRequest_Stop clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerRequest_Stop copyWith(
          void Function(DebugServerRequest_Stop) updates) =>
      super.copyWith((message) => updates(message as DebugServerRequest_Stop))
          as DebugServerRequest_Stop;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DebugServerRequest_Stop create() => DebugServerRequest_Stop._();
  @$core.override
  DebugServerRequest_Stop createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DebugServerRequest_Stop getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DebugServerRequest_Stop>(create);
  static DebugServerRequest_Stop? _defaultInstance;
}

class DebugServerRequest_Pipe extends $pb.GeneratedMessage {
  factory DebugServerRequest_Pipe({
    $core.List<$core.int>? data,
  }) {
    final result = create();
    if (data != null) result.data = data;
    return result;
  }

  DebugServerRequest_Pipe._();

  factory DebugServerRequest_Pipe.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DebugServerRequest_Pipe.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DebugServerRequest.Pipe',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerRequest_Pipe clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerRequest_Pipe copyWith(
          void Function(DebugServerRequest_Pipe) updates) =>
      super.copyWith((message) => updates(message as DebugServerRequest_Pipe))
          as DebugServerRequest_Pipe;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DebugServerRequest_Pipe create() => DebugServerRequest_Pipe._();
  @$core.override
  DebugServerRequest_Pipe createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DebugServerRequest_Pipe getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DebugServerRequest_Pipe>(create);
  static DebugServerRequest_Pipe? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get data => $_getN(0);
  @$pb.TagNumber(1)
  set data($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasData() => $_has(0);
  @$pb.TagNumber(1)
  void clearData() => $_clearField(1);
}

enum DebugServerRequest_Control { start, stop, status, pipe, notSet }

class DebugServerRequest extends $pb.GeneratedMessage {
  factory DebugServerRequest({
    DebugServerRequest_Start? start,
    DebugServerRequest_Stop? stop,
    DebugServerRequest_Status? status,
    DebugServerRequest_Pipe? pipe,
  }) {
    final result = create();
    if (start != null) result.start = start;
    if (stop != null) result.stop = stop;
    if (status != null) result.status = status;
    if (pipe != null) result.pipe = pipe;
    return result;
  }

  DebugServerRequest._();

  factory DebugServerRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DebugServerRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, DebugServerRequest_Control>
      _DebugServerRequest_ControlByTag = {
    1: DebugServerRequest_Control.start,
    2: DebugServerRequest_Control.stop,
    3: DebugServerRequest_Control.status,
    4: DebugServerRequest_Control.pipe,
    0: DebugServerRequest_Control.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DebugServerRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3, 4])
    ..aOM<DebugServerRequest_Start>(1, _omitFieldNames ? '' : 'start',
        subBuilder: DebugServerRequest_Start.create)
    ..aOM<DebugServerRequest_Stop>(2, _omitFieldNames ? '' : 'stop',
        subBuilder: DebugServerRequest_Stop.create)
    ..aOM<DebugServerRequest_Status>(3, _omitFieldNames ? '' : 'status',
        subBuilder: DebugServerRequest_Status.create)
    ..aOM<DebugServerRequest_Pipe>(4, _omitFieldNames ? '' : 'pipe',
        subBuilder: DebugServerRequest_Pipe.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerRequest copyWith(void Function(DebugServerRequest) updates) =>
      super.copyWith((message) => updates(message as DebugServerRequest))
          as DebugServerRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DebugServerRequest create() => DebugServerRequest._();
  @$core.override
  DebugServerRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DebugServerRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DebugServerRequest>(create);
  static DebugServerRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  DebugServerRequest_Control whichControl() =>
      _DebugServerRequest_ControlByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  void clearControl() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  DebugServerRequest_Start get start => $_getN(0);
  @$pb.TagNumber(1)
  set start(DebugServerRequest_Start value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStart() => $_has(0);
  @$pb.TagNumber(1)
  void clearStart() => $_clearField(1);
  @$pb.TagNumber(1)
  DebugServerRequest_Start ensureStart() => $_ensure(0);

  @$pb.TagNumber(2)
  DebugServerRequest_Stop get stop => $_getN(1);
  @$pb.TagNumber(2)
  set stop(DebugServerRequest_Stop value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStop() => $_has(1);
  @$pb.TagNumber(2)
  void clearStop() => $_clearField(2);
  @$pb.TagNumber(2)
  DebugServerRequest_Stop ensureStop() => $_ensure(1);

  @$pb.TagNumber(3)
  DebugServerRequest_Status get status => $_getN(2);
  @$pb.TagNumber(3)
  set status(DebugServerRequest_Status value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasStatus() => $_has(2);
  @$pb.TagNumber(3)
  void clearStatus() => $_clearField(3);
  @$pb.TagNumber(3)
  DebugServerRequest_Status ensureStatus() => $_ensure(2);

  @$pb.TagNumber(4)
  DebugServerRequest_Pipe get pipe => $_getN(3);
  @$pb.TagNumber(4)
  set pipe(DebugServerRequest_Pipe value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasPipe() => $_has(3);
  @$pb.TagNumber(4)
  void clearPipe() => $_clearField(4);
  @$pb.TagNumber(4)
  DebugServerRequest_Pipe ensurePipe() => $_ensure(3);
}

class DebugServerResponse_Pipe extends $pb.GeneratedMessage {
  factory DebugServerResponse_Pipe({
    $core.List<$core.int>? data,
  }) {
    final result = create();
    if (data != null) result.data = data;
    return result;
  }

  DebugServerResponse_Pipe._();

  factory DebugServerResponse_Pipe.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DebugServerResponse_Pipe.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DebugServerResponse.Pipe',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerResponse_Pipe clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerResponse_Pipe copyWith(
          void Function(DebugServerResponse_Pipe) updates) =>
      super.copyWith((message) => updates(message as DebugServerResponse_Pipe))
          as DebugServerResponse_Pipe;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DebugServerResponse_Pipe create() => DebugServerResponse_Pipe._();
  @$core.override
  DebugServerResponse_Pipe createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DebugServerResponse_Pipe getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DebugServerResponse_Pipe>(create);
  static DebugServerResponse_Pipe? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get data => $_getN(0);
  @$pb.TagNumber(1)
  set data($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasData() => $_has(0);
  @$pb.TagNumber(1)
  void clearData() => $_clearField(1);
}

class DebugServerResponse_Status extends $pb.GeneratedMessage {
  factory DebugServerResponse_Status({
    $core.Iterable<$core.String>? lldbBootstrapCommands,
  }) {
    final result = create();
    if (lldbBootstrapCommands != null)
      result.lldbBootstrapCommands.addAll(lldbBootstrapCommands);
    return result;
  }

  DebugServerResponse_Status._();

  factory DebugServerResponse_Status.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DebugServerResponse_Status.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DebugServerResponse.Status',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPS(1, _omitFieldNames ? '' : 'lldbBootstrapCommands')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerResponse_Status clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerResponse_Status copyWith(
          void Function(DebugServerResponse_Status) updates) =>
      super.copyWith(
              (message) => updates(message as DebugServerResponse_Status))
          as DebugServerResponse_Status;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DebugServerResponse_Status create() => DebugServerResponse_Status._();
  @$core.override
  DebugServerResponse_Status createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DebugServerResponse_Status getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DebugServerResponse_Status>(create);
  static DebugServerResponse_Status? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get lldbBootstrapCommands => $_getList(0);
}

enum DebugServerResponse_Control { status, pipe, notSet }

class DebugServerResponse extends $pb.GeneratedMessage {
  factory DebugServerResponse({
    DebugServerResponse_Status? status,
    DebugServerResponse_Pipe? pipe,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (pipe != null) result.pipe = pipe;
    return result;
  }

  DebugServerResponse._();

  factory DebugServerResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DebugServerResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, DebugServerResponse_Control>
      _DebugServerResponse_ControlByTag = {
    1: DebugServerResponse_Control.status,
    2: DebugServerResponse_Control.pipe,
    0: DebugServerResponse_Control.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DebugServerResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOM<DebugServerResponse_Status>(1, _omitFieldNames ? '' : 'status',
        subBuilder: DebugServerResponse_Status.create)
    ..aOM<DebugServerResponse_Pipe>(2, _omitFieldNames ? '' : 'pipe',
        subBuilder: DebugServerResponse_Pipe.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebugServerResponse copyWith(void Function(DebugServerResponse) updates) =>
      super.copyWith((message) => updates(message as DebugServerResponse))
          as DebugServerResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DebugServerResponse create() => DebugServerResponse._();
  @$core.override
  DebugServerResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DebugServerResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DebugServerResponse>(create);
  static DebugServerResponse? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  DebugServerResponse_Control whichControl() =>
      _DebugServerResponse_ControlByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearControl() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  DebugServerResponse_Status get status => $_getN(0);
  @$pb.TagNumber(1)
  set status(DebugServerResponse_Status value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);
  @$pb.TagNumber(1)
  DebugServerResponse_Status ensureStatus() => $_ensure(0);

  @$pb.TagNumber(2)
  DebugServerResponse_Pipe get pipe => $_getN(1);
  @$pb.TagNumber(2)
  set pipe(DebugServerResponse_Pipe value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPipe() => $_has(1);
  @$pb.TagNumber(2)
  void clearPipe() => $_clearField(2);
  @$pb.TagNumber(2)
  DebugServerResponse_Pipe ensurePipe() => $_ensure(1);
}

class CrashShowRequest extends $pb.GeneratedMessage {
  factory CrashShowRequest({
    $core.String? name,
  }) {
    final result = create();
    if (name != null) result.name = name;
    return result;
  }

  CrashShowRequest._();

  factory CrashShowRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CrashShowRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CrashShowRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CrashShowRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CrashShowRequest copyWith(void Function(CrashShowRequest) updates) =>
      super.copyWith((message) => updates(message as CrashShowRequest))
          as CrashShowRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CrashShowRequest create() => CrashShowRequest._();
  @$core.override
  CrashShowRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CrashShowRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CrashShowRequest>(create);
  static CrashShowRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);
}

class CrashLogResponse extends $pb.GeneratedMessage {
  factory CrashLogResponse({
    $core.Iterable<CrashLogInfo>? list,
  }) {
    final result = create();
    if (list != null) result.list.addAll(list);
    return result;
  }

  CrashLogResponse._();

  factory CrashLogResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CrashLogResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CrashLogResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPM<CrashLogInfo>(1, _omitFieldNames ? '' : 'list',
        subBuilder: CrashLogInfo.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CrashLogResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CrashLogResponse copyWith(void Function(CrashLogResponse) updates) =>
      super.copyWith((message) => updates(message as CrashLogResponse))
          as CrashLogResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CrashLogResponse create() => CrashLogResponse._();
  @$core.override
  CrashLogResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CrashLogResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CrashLogResponse>(create);
  static CrashLogResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<CrashLogInfo> get list => $_getList(0);
}

class CrashLogInfo extends $pb.GeneratedMessage {
  factory CrashLogInfo({
    $core.String? name,
    $core.String? bundleId,
    $core.String? processName,
    $core.String? parentProcessName,
    $fixnum.Int64? processIdentifier,
    $fixnum.Int64? parentProcessIdentifier,
    $fixnum.Int64? timestamp,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (bundleId != null) result.bundleId = bundleId;
    if (processName != null) result.processName = processName;
    if (parentProcessName != null) result.parentProcessName = parentProcessName;
    if (processIdentifier != null) result.processIdentifier = processIdentifier;
    if (parentProcessIdentifier != null)
      result.parentProcessIdentifier = parentProcessIdentifier;
    if (timestamp != null) result.timestamp = timestamp;
    return result;
  }

  CrashLogInfo._();

  factory CrashLogInfo.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CrashLogInfo.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CrashLogInfo',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'bundleId')
    ..aOS(3, _omitFieldNames ? '' : 'processName')
    ..aOS(4, _omitFieldNames ? '' : 'parentProcessName')
    ..a<$fixnum.Int64>(
        5, _omitFieldNames ? '' : 'processIdentifier', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(6, _omitFieldNames ? '' : 'parentProcessIdentifier',
        $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        7, _omitFieldNames ? '' : 'timestamp', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CrashLogInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CrashLogInfo copyWith(void Function(CrashLogInfo) updates) =>
      super.copyWith((message) => updates(message as CrashLogInfo))
          as CrashLogInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CrashLogInfo create() => CrashLogInfo._();
  @$core.override
  CrashLogInfo createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CrashLogInfo getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CrashLogInfo>(create);
  static CrashLogInfo? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get bundleId => $_getSZ(1);
  @$pb.TagNumber(2)
  set bundleId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBundleId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBundleId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get processName => $_getSZ(2);
  @$pb.TagNumber(3)
  set processName($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasProcessName() => $_has(2);
  @$pb.TagNumber(3)
  void clearProcessName() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get parentProcessName => $_getSZ(3);
  @$pb.TagNumber(4)
  set parentProcessName($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasParentProcessName() => $_has(3);
  @$pb.TagNumber(4)
  void clearParentProcessName() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get processIdentifier => $_getI64(4);
  @$pb.TagNumber(5)
  set processIdentifier($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasProcessIdentifier() => $_has(4);
  @$pb.TagNumber(5)
  void clearProcessIdentifier() => $_clearField(5);

  @$pb.TagNumber(6)
  $fixnum.Int64 get parentProcessIdentifier => $_getI64(5);
  @$pb.TagNumber(6)
  set parentProcessIdentifier($fixnum.Int64 value) => $_setInt64(5, value);
  @$pb.TagNumber(6)
  $core.bool hasParentProcessIdentifier() => $_has(5);
  @$pb.TagNumber(6)
  void clearParentProcessIdentifier() => $_clearField(6);

  @$pb.TagNumber(7)
  $fixnum.Int64 get timestamp => $_getI64(6);
  @$pb.TagNumber(7)
  set timestamp($fixnum.Int64 value) => $_setInt64(6, value);
  @$pb.TagNumber(7)
  $core.bool hasTimestamp() => $_has(6);
  @$pb.TagNumber(7)
  void clearTimestamp() => $_clearField(7);
}

class CrashShowResponse extends $pb.GeneratedMessage {
  factory CrashShowResponse({
    CrashLogInfo? info,
    $core.String? contents,
  }) {
    final result = create();
    if (info != null) result.info = info;
    if (contents != null) result.contents = contents;
    return result;
  }

  CrashShowResponse._();

  factory CrashShowResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CrashShowResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CrashShowResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<CrashLogInfo>(1, _omitFieldNames ? '' : 'info',
        subBuilder: CrashLogInfo.create)
    ..aOS(2, _omitFieldNames ? '' : 'contents')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CrashShowResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CrashShowResponse copyWith(void Function(CrashShowResponse) updates) =>
      super.copyWith((message) => updates(message as CrashShowResponse))
          as CrashShowResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CrashShowResponse create() => CrashShowResponse._();
  @$core.override
  CrashShowResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CrashShowResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CrashShowResponse>(create);
  static CrashShowResponse? _defaultInstance;

  @$pb.TagNumber(1)
  CrashLogInfo get info => $_getN(0);
  @$pb.TagNumber(1)
  set info(CrashLogInfo value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasInfo() => $_has(0);
  @$pb.TagNumber(1)
  void clearInfo() => $_clearField(1);
  @$pb.TagNumber(1)
  CrashLogInfo ensureInfo() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.String get contents => $_getSZ(1);
  @$pb.TagNumber(2)
  set contents($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasContents() => $_has(1);
  @$pb.TagNumber(2)
  void clearContents() => $_clearField(2);
}

class CrashLogQuery extends $pb.GeneratedMessage {
  factory CrashLogQuery({
    $fixnum.Int64? since,
    $fixnum.Int64? before,
    $core.String? bundleId,
    $core.String? name,
  }) {
    final result = create();
    if (since != null) result.since = since;
    if (before != null) result.before = before;
    if (bundleId != null) result.bundleId = bundleId;
    if (name != null) result.name = name;
    return result;
  }

  CrashLogQuery._();

  factory CrashLogQuery.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CrashLogQuery.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CrashLogQuery',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$fixnum.Int64>(1, _omitFieldNames ? '' : 'since', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'before', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(3, _omitFieldNames ? '' : 'bundleId')
    ..aOS(4, _omitFieldNames ? '' : 'name')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CrashLogQuery clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CrashLogQuery copyWith(void Function(CrashLogQuery) updates) =>
      super.copyWith((message) => updates(message as CrashLogQuery))
          as CrashLogQuery;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CrashLogQuery create() => CrashLogQuery._();
  @$core.override
  CrashLogQuery createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CrashLogQuery getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CrashLogQuery>(create);
  static CrashLogQuery? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get since => $_getI64(0);
  @$pb.TagNumber(1)
  set since($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSince() => $_has(0);
  @$pb.TagNumber(1)
  void clearSince() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get before => $_getI64(1);
  @$pb.TagNumber(2)
  set before($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBefore() => $_has(1);
  @$pb.TagNumber(2)
  void clearBefore() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get bundleId => $_getSZ(2);
  @$pb.TagNumber(3)
  set bundleId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasBundleId() => $_has(2);
  @$pb.TagNumber(3)
  void clearBundleId() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get name => $_getSZ(3);
  @$pb.TagNumber(4)
  set name($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasName() => $_has(3);
  @$pb.TagNumber(4)
  void clearName() => $_clearField(4);
}

class XctestListBundlesRequest extends $pb.GeneratedMessage {
  factory XctestListBundlesRequest() => create();

  XctestListBundlesRequest._();

  factory XctestListBundlesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestListBundlesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestListBundlesRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestListBundlesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestListBundlesRequest copyWith(
          void Function(XctestListBundlesRequest) updates) =>
      super.copyWith((message) => updates(message as XctestListBundlesRequest))
          as XctestListBundlesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestListBundlesRequest create() => XctestListBundlesRequest._();
  @$core.override
  XctestListBundlesRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestListBundlesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestListBundlesRequest>(create);
  static XctestListBundlesRequest? _defaultInstance;
}

class XctestListBundlesResponse_Bundles extends $pb.GeneratedMessage {
  factory XctestListBundlesResponse_Bundles({
    $core.String? name,
    $core.String? bundleId,
    $core.Iterable<$core.String>? architectures,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (bundleId != null) result.bundleId = bundleId;
    if (architectures != null) result.architectures.addAll(architectures);
    return result;
  }

  XctestListBundlesResponse_Bundles._();

  factory XctestListBundlesResponse_Bundles.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestListBundlesResponse_Bundles.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestListBundlesResponse.Bundles',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'bundleId')
    ..pPS(3, _omitFieldNames ? '' : 'architectures')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestListBundlesResponse_Bundles clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestListBundlesResponse_Bundles copyWith(
          void Function(XctestListBundlesResponse_Bundles) updates) =>
      super.copyWith((message) =>
              updates(message as XctestListBundlesResponse_Bundles))
          as XctestListBundlesResponse_Bundles;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestListBundlesResponse_Bundles create() =>
      XctestListBundlesResponse_Bundles._();
  @$core.override
  XctestListBundlesResponse_Bundles createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestListBundlesResponse_Bundles getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestListBundlesResponse_Bundles>(
          create);
  static XctestListBundlesResponse_Bundles? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get bundleId => $_getSZ(1);
  @$pb.TagNumber(2)
  set bundleId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBundleId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBundleId() => $_clearField(2);

  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get architectures => $_getList(2);
}

class XctestListBundlesResponse extends $pb.GeneratedMessage {
  factory XctestListBundlesResponse({
    $core.Iterable<XctestListBundlesResponse_Bundles>? bundles,
  }) {
    final result = create();
    if (bundles != null) result.bundles.addAll(bundles);
    return result;
  }

  XctestListBundlesResponse._();

  factory XctestListBundlesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestListBundlesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestListBundlesResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPM<XctestListBundlesResponse_Bundles>(
        1, _omitFieldNames ? '' : 'bundles',
        subBuilder: XctestListBundlesResponse_Bundles.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestListBundlesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestListBundlesResponse copyWith(
          void Function(XctestListBundlesResponse) updates) =>
      super.copyWith((message) => updates(message as XctestListBundlesResponse))
          as XctestListBundlesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestListBundlesResponse create() => XctestListBundlesResponse._();
  @$core.override
  XctestListBundlesResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestListBundlesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestListBundlesResponse>(create);
  static XctestListBundlesResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<XctestListBundlesResponse_Bundles> get bundles => $_getList(0);
}

class XctestListTestsRequest extends $pb.GeneratedMessage {
  factory XctestListTestsRequest({
    $core.String? bundleName,
    $core.String? appPath,
  }) {
    final result = create();
    if (bundleName != null) result.bundleName = bundleName;
    if (appPath != null) result.appPath = appPath;
    return result;
  }

  XctestListTestsRequest._();

  factory XctestListTestsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestListTestsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestListTestsRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'bundleName')
    ..aOS(2, _omitFieldNames ? '' : 'appPath')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestListTestsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestListTestsRequest copyWith(
          void Function(XctestListTestsRequest) updates) =>
      super.copyWith((message) => updates(message as XctestListTestsRequest))
          as XctestListTestsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestListTestsRequest create() => XctestListTestsRequest._();
  @$core.override
  XctestListTestsRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestListTestsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestListTestsRequest>(create);
  static XctestListTestsRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get bundleName => $_getSZ(0);
  @$pb.TagNumber(1)
  set bundleName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBundleName() => $_has(0);
  @$pb.TagNumber(1)
  void clearBundleName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get appPath => $_getSZ(1);
  @$pb.TagNumber(2)
  set appPath($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasAppPath() => $_has(1);
  @$pb.TagNumber(2)
  void clearAppPath() => $_clearField(2);
}

class XctestListTestsResponse extends $pb.GeneratedMessage {
  factory XctestListTestsResponse({
    $core.Iterable<$core.String>? names,
  }) {
    final result = create();
    if (names != null) result.names.addAll(names);
    return result;
  }

  XctestListTestsResponse._();

  factory XctestListTestsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestListTestsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestListTestsResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPS(1, _omitFieldNames ? '' : 'names')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestListTestsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestListTestsResponse copyWith(
          void Function(XctestListTestsResponse) updates) =>
      super.copyWith((message) => updates(message as XctestListTestsResponse))
          as XctestListTestsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestListTestsResponse create() => XctestListTestsResponse._();
  @$core.override
  XctestListTestsResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestListTestsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestListTestsResponse>(create);
  static XctestListTestsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get names => $_getList(0);
}

class XctestRunRequest_Logic extends $pb.GeneratedMessage {
  factory XctestRunRequest_Logic() => create();

  XctestRunRequest_Logic._();

  factory XctestRunRequest_Logic.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunRequest_Logic.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestRunRequest.Logic',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest_Logic clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest_Logic copyWith(
          void Function(XctestRunRequest_Logic) updates) =>
      super.copyWith((message) => updates(message as XctestRunRequest_Logic))
          as XctestRunRequest_Logic;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunRequest_Logic create() => XctestRunRequest_Logic._();
  @$core.override
  XctestRunRequest_Logic createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestRunRequest_Logic getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestRunRequest_Logic>(create);
  static XctestRunRequest_Logic? _defaultInstance;
}

class XctestRunRequest_Application extends $pb.GeneratedMessage {
  factory XctestRunRequest_Application({
    $core.String? appBundleId,
  }) {
    final result = create();
    if (appBundleId != null) result.appBundleId = appBundleId;
    return result;
  }

  XctestRunRequest_Application._();

  factory XctestRunRequest_Application.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunRequest_Application.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestRunRequest.Application',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'appBundleId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest_Application clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest_Application copyWith(
          void Function(XctestRunRequest_Application) updates) =>
      super.copyWith(
              (message) => updates(message as XctestRunRequest_Application))
          as XctestRunRequest_Application;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunRequest_Application create() =>
      XctestRunRequest_Application._();
  @$core.override
  XctestRunRequest_Application createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestRunRequest_Application getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestRunRequest_Application>(create);
  static XctestRunRequest_Application? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get appBundleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set appBundleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAppBundleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearAppBundleId() => $_clearField(1);
}

class XctestRunRequest_UI extends $pb.GeneratedMessage {
  factory XctestRunRequest_UI({
    $core.String? appBundleId,
    $core.String? testHostAppBundleId,
  }) {
    final result = create();
    if (appBundleId != null) result.appBundleId = appBundleId;
    if (testHostAppBundleId != null)
      result.testHostAppBundleId = testHostAppBundleId;
    return result;
  }

  XctestRunRequest_UI._();

  factory XctestRunRequest_UI.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunRequest_UI.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestRunRequest.UI',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'appBundleId')
    ..aOS(2, _omitFieldNames ? '' : 'testHostAppBundleId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest_UI clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest_UI copyWith(void Function(XctestRunRequest_UI) updates) =>
      super.copyWith((message) => updates(message as XctestRunRequest_UI))
          as XctestRunRequest_UI;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunRequest_UI create() => XctestRunRequest_UI._();
  @$core.override
  XctestRunRequest_UI createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestRunRequest_UI getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestRunRequest_UI>(create);
  static XctestRunRequest_UI? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get appBundleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set appBundleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAppBundleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearAppBundleId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get testHostAppBundleId => $_getSZ(1);
  @$pb.TagNumber(2)
  set testHostAppBundleId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTestHostAppBundleId() => $_has(1);
  @$pb.TagNumber(2)
  void clearTestHostAppBundleId() => $_clearField(2);
}

enum XctestRunRequest_Mode_Mode { logic, application, ui, notSet }

class XctestRunRequest_Mode extends $pb.GeneratedMessage {
  factory XctestRunRequest_Mode({
    XctestRunRequest_Logic? logic,
    XctestRunRequest_Application? application,
    XctestRunRequest_UI? ui,
  }) {
    final result = create();
    if (logic != null) result.logic = logic;
    if (application != null) result.application = application;
    if (ui != null) result.ui = ui;
    return result;
  }

  XctestRunRequest_Mode._();

  factory XctestRunRequest_Mode.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunRequest_Mode.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, XctestRunRequest_Mode_Mode>
      _XctestRunRequest_Mode_ModeByTag = {
    1: XctestRunRequest_Mode_Mode.logic,
    2: XctestRunRequest_Mode_Mode.application,
    3: XctestRunRequest_Mode_Mode.ui,
    0: XctestRunRequest_Mode_Mode.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestRunRequest.Mode',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3])
    ..aOM<XctestRunRequest_Logic>(1, _omitFieldNames ? '' : 'logic',
        subBuilder: XctestRunRequest_Logic.create)
    ..aOM<XctestRunRequest_Application>(2, _omitFieldNames ? '' : 'application',
        subBuilder: XctestRunRequest_Application.create)
    ..aOM<XctestRunRequest_UI>(3, _omitFieldNames ? '' : 'ui',
        subBuilder: XctestRunRequest_UI.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest_Mode clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest_Mode copyWith(
          void Function(XctestRunRequest_Mode) updates) =>
      super.copyWith((message) => updates(message as XctestRunRequest_Mode))
          as XctestRunRequest_Mode;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunRequest_Mode create() => XctestRunRequest_Mode._();
  @$core.override
  XctestRunRequest_Mode createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestRunRequest_Mode getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestRunRequest_Mode>(create);
  static XctestRunRequest_Mode? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  XctestRunRequest_Mode_Mode whichMode() =>
      _XctestRunRequest_Mode_ModeByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearMode() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  XctestRunRequest_Logic get logic => $_getN(0);
  @$pb.TagNumber(1)
  set logic(XctestRunRequest_Logic value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasLogic() => $_has(0);
  @$pb.TagNumber(1)
  void clearLogic() => $_clearField(1);
  @$pb.TagNumber(1)
  XctestRunRequest_Logic ensureLogic() => $_ensure(0);

  @$pb.TagNumber(2)
  XctestRunRequest_Application get application => $_getN(1);
  @$pb.TagNumber(2)
  set application(XctestRunRequest_Application value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasApplication() => $_has(1);
  @$pb.TagNumber(2)
  void clearApplication() => $_clearField(2);
  @$pb.TagNumber(2)
  XctestRunRequest_Application ensureApplication() => $_ensure(1);

  @$pb.TagNumber(3)
  XctestRunRequest_UI get ui => $_getN(2);
  @$pb.TagNumber(3)
  set ui(XctestRunRequest_UI value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasUi() => $_has(2);
  @$pb.TagNumber(3)
  void clearUi() => $_clearField(3);
  @$pb.TagNumber(3)
  XctestRunRequest_UI ensureUi() => $_ensure(2);
}

class XctestRunRequest_CodeCoverage extends $pb.GeneratedMessage {
  factory XctestRunRequest_CodeCoverage({
    $core.bool? collect,
    XctestRunRequest_CodeCoverage_Format? format,
    $core.bool? enableContinuousCoverageCollection,
  }) {
    final result = create();
    if (collect != null) result.collect = collect;
    if (format != null) result.format = format;
    if (enableContinuousCoverageCollection != null)
      result.enableContinuousCoverageCollection =
          enableContinuousCoverageCollection;
    return result;
  }

  XctestRunRequest_CodeCoverage._();

  factory XctestRunRequest_CodeCoverage.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunRequest_CodeCoverage.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestRunRequest.CodeCoverage',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'collect')
    ..aE<XctestRunRequest_CodeCoverage_Format>(
        2, _omitFieldNames ? '' : 'format',
        enumValues: XctestRunRequest_CodeCoverage_Format.values)
    ..aOB(3, _omitFieldNames ? '' : 'enableContinuousCoverageCollection')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest_CodeCoverage clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest_CodeCoverage copyWith(
          void Function(XctestRunRequest_CodeCoverage) updates) =>
      super.copyWith(
              (message) => updates(message as XctestRunRequest_CodeCoverage))
          as XctestRunRequest_CodeCoverage;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunRequest_CodeCoverage create() =>
      XctestRunRequest_CodeCoverage._();
  @$core.override
  XctestRunRequest_CodeCoverage createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestRunRequest_CodeCoverage getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestRunRequest_CodeCoverage>(create);
  static XctestRunRequest_CodeCoverage? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get collect => $_getBF(0);
  @$pb.TagNumber(1)
  set collect($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCollect() => $_has(0);
  @$pb.TagNumber(1)
  void clearCollect() => $_clearField(1);

  @$pb.TagNumber(2)
  XctestRunRequest_CodeCoverage_Format get format => $_getN(1);
  @$pb.TagNumber(2)
  set format(XctestRunRequest_CodeCoverage_Format value) =>
      $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasFormat() => $_has(1);
  @$pb.TagNumber(2)
  void clearFormat() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get enableContinuousCoverageCollection => $_getBF(2);
  @$pb.TagNumber(3)
  set enableContinuousCoverageCollection($core.bool value) =>
      $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasEnableContinuousCoverageCollection() => $_has(2);
  @$pb.TagNumber(3)
  void clearEnableContinuousCoverageCollection() => $_clearField(3);
}

class XctestRunRequest extends $pb.GeneratedMessage {
  factory XctestRunRequest({
    XctestRunRequest_Mode? mode,
    $core.String? testBundleId,
    $core.Iterable<$core.String>? testsToRun,
    $core.Iterable<$core.String>? testsToSkip,
    $core.Iterable<$core.String>? arguments,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? environment,
    $fixnum.Int64? timeout,
    $core.bool? reportActivities,
    $core.bool? collectCoverage,
    $core.bool? reportAttachments,
    $core.bool? collectLogs,
    $core.bool? waitForDebugger,
    XctestRunRequest_CodeCoverage? codeCoverage,
    $core.bool? collectResultBundle,
  }) {
    final result = create();
    if (mode != null) result.mode = mode;
    if (testBundleId != null) result.testBundleId = testBundleId;
    if (testsToRun != null) result.testsToRun.addAll(testsToRun);
    if (testsToSkip != null) result.testsToSkip.addAll(testsToSkip);
    if (arguments != null) result.arguments.addAll(arguments);
    if (environment != null) result.environment.addEntries(environment);
    if (timeout != null) result.timeout = timeout;
    if (reportActivities != null) result.reportActivities = reportActivities;
    if (collectCoverage != null) result.collectCoverage = collectCoverage;
    if (reportAttachments != null) result.reportAttachments = reportAttachments;
    if (collectLogs != null) result.collectLogs = collectLogs;
    if (waitForDebugger != null) result.waitForDebugger = waitForDebugger;
    if (codeCoverage != null) result.codeCoverage = codeCoverage;
    if (collectResultBundle != null)
      result.collectResultBundle = collectResultBundle;
    return result;
  }

  XctestRunRequest._();

  factory XctestRunRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestRunRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<XctestRunRequest_Mode>(1, _omitFieldNames ? '' : 'mode',
        subBuilder: XctestRunRequest_Mode.create)
    ..aOS(2, _omitFieldNames ? '' : 'testBundleId')
    ..pPS(3, _omitFieldNames ? '' : 'testsToRun')
    ..pPS(4, _omitFieldNames ? '' : 'testsToSkip')
    ..pPS(5, _omitFieldNames ? '' : 'arguments')
    ..m<$core.String, $core.String>(6, _omitFieldNames ? '' : 'environment',
        entryClassName: 'XctestRunRequest.EnvironmentEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('idb'))
    ..a<$fixnum.Int64>(7, _omitFieldNames ? '' : 'timeout', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOB(8, _omitFieldNames ? '' : 'reportActivities')
    ..aOB(9, _omitFieldNames ? '' : 'collectCoverage')
    ..aOB(10, _omitFieldNames ? '' : 'reportAttachments')
    ..aOB(11, _omitFieldNames ? '' : 'collectLogs')
    ..aOB(12, _omitFieldNames ? '' : 'waitForDebugger')
    ..aOM<XctestRunRequest_CodeCoverage>(
        13, _omitFieldNames ? '' : 'codeCoverage',
        subBuilder: XctestRunRequest_CodeCoverage.create)
    ..aOB(14, _omitFieldNames ? '' : 'collectResultBundle')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunRequest copyWith(void Function(XctestRunRequest) updates) =>
      super.copyWith((message) => updates(message as XctestRunRequest))
          as XctestRunRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunRequest create() => XctestRunRequest._();
  @$core.override
  XctestRunRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestRunRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestRunRequest>(create);
  static XctestRunRequest? _defaultInstance;

  @$pb.TagNumber(1)
  XctestRunRequest_Mode get mode => $_getN(0);
  @$pb.TagNumber(1)
  set mode(XctestRunRequest_Mode value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasMode() => $_has(0);
  @$pb.TagNumber(1)
  void clearMode() => $_clearField(1);
  @$pb.TagNumber(1)
  XctestRunRequest_Mode ensureMode() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.String get testBundleId => $_getSZ(1);
  @$pb.TagNumber(2)
  set testBundleId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTestBundleId() => $_has(1);
  @$pb.TagNumber(2)
  void clearTestBundleId() => $_clearField(2);

  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get testsToRun => $_getList(2);

  @$pb.TagNumber(4)
  $pb.PbList<$core.String> get testsToSkip => $_getList(3);

  @$pb.TagNumber(5)
  $pb.PbList<$core.String> get arguments => $_getList(4);

  @$pb.TagNumber(6)
  $pb.PbMap<$core.String, $core.String> get environment => $_getMap(5);

  @$pb.TagNumber(7)
  $fixnum.Int64 get timeout => $_getI64(6);
  @$pb.TagNumber(7)
  set timeout($fixnum.Int64 value) => $_setInt64(6, value);
  @$pb.TagNumber(7)
  $core.bool hasTimeout() => $_has(6);
  @$pb.TagNumber(7)
  void clearTimeout() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.bool get reportActivities => $_getBF(7);
  @$pb.TagNumber(8)
  set reportActivities($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasReportActivities() => $_has(7);
  @$pb.TagNumber(8)
  void clearReportActivities() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.bool get collectCoverage => $_getBF(8);
  @$pb.TagNumber(9)
  set collectCoverage($core.bool value) => $_setBool(8, value);
  @$pb.TagNumber(9)
  $core.bool hasCollectCoverage() => $_has(8);
  @$pb.TagNumber(9)
  void clearCollectCoverage() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.bool get reportAttachments => $_getBF(9);
  @$pb.TagNumber(10)
  set reportAttachments($core.bool value) => $_setBool(9, value);
  @$pb.TagNumber(10)
  $core.bool hasReportAttachments() => $_has(9);
  @$pb.TagNumber(10)
  void clearReportAttachments() => $_clearField(10);

  @$pb.TagNumber(11)
  $core.bool get collectLogs => $_getBF(10);
  @$pb.TagNumber(11)
  set collectLogs($core.bool value) => $_setBool(10, value);
  @$pb.TagNumber(11)
  $core.bool hasCollectLogs() => $_has(10);
  @$pb.TagNumber(11)
  void clearCollectLogs() => $_clearField(11);

  @$pb.TagNumber(12)
  $core.bool get waitForDebugger => $_getBF(11);
  @$pb.TagNumber(12)
  set waitForDebugger($core.bool value) => $_setBool(11, value);
  @$pb.TagNumber(12)
  $core.bool hasWaitForDebugger() => $_has(11);
  @$pb.TagNumber(12)
  void clearWaitForDebugger() => $_clearField(12);

  @$pb.TagNumber(13)
  XctestRunRequest_CodeCoverage get codeCoverage => $_getN(12);
  @$pb.TagNumber(13)
  set codeCoverage(XctestRunRequest_CodeCoverage value) =>
      $_setField(13, value);
  @$pb.TagNumber(13)
  $core.bool hasCodeCoverage() => $_has(12);
  @$pb.TagNumber(13)
  void clearCodeCoverage() => $_clearField(13);
  @$pb.TagNumber(13)
  XctestRunRequest_CodeCoverage ensureCodeCoverage() => $_ensure(12);

  @$pb.TagNumber(14)
  $core.bool get collectResultBundle => $_getBF(13);
  @$pb.TagNumber(14)
  set collectResultBundle($core.bool value) => $_setBool(13, value);
  @$pb.TagNumber(14)
  $core.bool hasCollectResultBundle() => $_has(13);
  @$pb.TagNumber(14)
  void clearCollectResultBundle() => $_clearField(14);
}

class XctestRunResponse_TestRunInfo_TestRunFailureInfo
    extends $pb.GeneratedMessage {
  factory XctestRunResponse_TestRunInfo_TestRunFailureInfo({
    $core.String? failureMessage,
    $core.String? file,
    $fixnum.Int64? line,
  }) {
    final result = create();
    if (failureMessage != null) result.failureMessage = failureMessage;
    if (file != null) result.file = file;
    if (line != null) result.line = line;
    return result;
  }

  XctestRunResponse_TestRunInfo_TestRunFailureInfo._();

  factory XctestRunResponse_TestRunInfo_TestRunFailureInfo.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunResponse_TestRunInfo_TestRunFailureInfo.fromJson(
          $core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames
          ? ''
          : 'XctestRunResponse.TestRunInfo.TestRunFailureInfo',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'failureMessage')
    ..aOS(2, _omitFieldNames ? '' : 'file')
    ..a<$fixnum.Int64>(3, _omitFieldNames ? '' : 'line', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunResponse_TestRunInfo_TestRunFailureInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunResponse_TestRunInfo_TestRunFailureInfo copyWith(
          void Function(XctestRunResponse_TestRunInfo_TestRunFailureInfo)
              updates) =>
      super.copyWith((message) => updates(
              message as XctestRunResponse_TestRunInfo_TestRunFailureInfo))
          as XctestRunResponse_TestRunInfo_TestRunFailureInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunResponse_TestRunInfo_TestRunFailureInfo create() =>
      XctestRunResponse_TestRunInfo_TestRunFailureInfo._();
  @$core.override
  XctestRunResponse_TestRunInfo_TestRunFailureInfo createEmptyInstance() =>
      create();
  @$core.pragma('dart2js:noInline')
  static XctestRunResponse_TestRunInfo_TestRunFailureInfo getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<
          XctestRunResponse_TestRunInfo_TestRunFailureInfo>(create);
  static XctestRunResponse_TestRunInfo_TestRunFailureInfo? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get failureMessage => $_getSZ(0);
  @$pb.TagNumber(1)
  set failureMessage($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasFailureMessage() => $_has(0);
  @$pb.TagNumber(1)
  void clearFailureMessage() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get file => $_getSZ(1);
  @$pb.TagNumber(2)
  set file($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasFile() => $_has(1);
  @$pb.TagNumber(2)
  void clearFile() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get line => $_getI64(2);
  @$pb.TagNumber(3)
  set line($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasLine() => $_has(2);
  @$pb.TagNumber(3)
  void clearLine() => $_clearField(3);
}

class XctestRunResponse_TestRunInfo_TestAttachment
    extends $pb.GeneratedMessage {
  factory XctestRunResponse_TestRunInfo_TestAttachment({
    $core.List<$core.int>? payload,
    $core.double? timestamp,
    $core.String? name,
    $core.String? uniformTypeIdentifier,
    $core.List<$core.int>? userInfoJson,
  }) {
    final result = create();
    if (payload != null) result.payload = payload;
    if (timestamp != null) result.timestamp = timestamp;
    if (name != null) result.name = name;
    if (uniformTypeIdentifier != null)
      result.uniformTypeIdentifier = uniformTypeIdentifier;
    if (userInfoJson != null) result.userInfoJson = userInfoJson;
    return result;
  }

  XctestRunResponse_TestRunInfo_TestAttachment._();

  factory XctestRunResponse_TestRunInfo_TestAttachment.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunResponse_TestRunInfo_TestAttachment.fromJson(
          $core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestRunResponse.TestRunInfo.TestAttachment',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'payload', $pb.PbFieldType.OY)
    ..aD(2, _omitFieldNames ? '' : 'timestamp')
    ..aOS(3, _omitFieldNames ? '' : 'name')
    ..aOS(4, _omitFieldNames ? '' : 'uniformTypeIdentifier')
    ..a<$core.List<$core.int>>(
        5, _omitFieldNames ? '' : 'userInfoJson', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunResponse_TestRunInfo_TestAttachment clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunResponse_TestRunInfo_TestAttachment copyWith(
          void Function(XctestRunResponse_TestRunInfo_TestAttachment)
              updates) =>
      super.copyWith((message) =>
              updates(message as XctestRunResponse_TestRunInfo_TestAttachment))
          as XctestRunResponse_TestRunInfo_TestAttachment;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunResponse_TestRunInfo_TestAttachment create() =>
      XctestRunResponse_TestRunInfo_TestAttachment._();
  @$core.override
  XctestRunResponse_TestRunInfo_TestAttachment createEmptyInstance() =>
      create();
  @$core.pragma('dart2js:noInline')
  static XctestRunResponse_TestRunInfo_TestAttachment getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<
          XctestRunResponse_TestRunInfo_TestAttachment>(create);
  static XctestRunResponse_TestRunInfo_TestAttachment? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get payload => $_getN(0);
  @$pb.TagNumber(1)
  set payload($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPayload() => $_has(0);
  @$pb.TagNumber(1)
  void clearPayload() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.double get timestamp => $_getN(1);
  @$pb.TagNumber(2)
  set timestamp($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTimestamp() => $_has(1);
  @$pb.TagNumber(2)
  void clearTimestamp() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get name => $_getSZ(2);
  @$pb.TagNumber(3)
  set name($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasName() => $_has(2);
  @$pb.TagNumber(3)
  void clearName() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get uniformTypeIdentifier => $_getSZ(3);
  @$pb.TagNumber(4)
  set uniformTypeIdentifier($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasUniformTypeIdentifier() => $_has(3);
  @$pb.TagNumber(4)
  void clearUniformTypeIdentifier() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.List<$core.int> get userInfoJson => $_getN(4);
  @$pb.TagNumber(5)
  set userInfoJson($core.List<$core.int> value) => $_setBytes(4, value);
  @$pb.TagNumber(5)
  $core.bool hasUserInfoJson() => $_has(4);
  @$pb.TagNumber(5)
  void clearUserInfoJson() => $_clearField(5);
}

class XctestRunResponse_TestRunInfo_TestActivity extends $pb.GeneratedMessage {
  factory XctestRunResponse_TestRunInfo_TestActivity({
    $core.String? title,
    $core.double? duration,
    $core.String? uuid,
    $core.String? activityType,
    $core.double? start,
    $core.double? finish,
    $core.String? name,
    $core.Iterable<XctestRunResponse_TestRunInfo_TestAttachment>? attachments,
    $core.Iterable<XctestRunResponse_TestRunInfo_TestActivity>? subActivities,
  }) {
    final result = create();
    if (title != null) result.title = title;
    if (duration != null) result.duration = duration;
    if (uuid != null) result.uuid = uuid;
    if (activityType != null) result.activityType = activityType;
    if (start != null) result.start = start;
    if (finish != null) result.finish = finish;
    if (name != null) result.name = name;
    if (attachments != null) result.attachments.addAll(attachments);
    if (subActivities != null) result.subActivities.addAll(subActivities);
    return result;
  }

  XctestRunResponse_TestRunInfo_TestActivity._();

  factory XctestRunResponse_TestRunInfo_TestActivity.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunResponse_TestRunInfo_TestActivity.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestRunResponse.TestRunInfo.TestActivity',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'title')
    ..aD(2, _omitFieldNames ? '' : 'duration')
    ..aOS(3, _omitFieldNames ? '' : 'uuid')
    ..aOS(4, _omitFieldNames ? '' : 'activityType')
    ..aD(5, _omitFieldNames ? '' : 'start')
    ..aD(6, _omitFieldNames ? '' : 'finish')
    ..aOS(7, _omitFieldNames ? '' : 'name')
    ..pPM<XctestRunResponse_TestRunInfo_TestAttachment>(
        8, _omitFieldNames ? '' : 'attachments',
        subBuilder: XctestRunResponse_TestRunInfo_TestAttachment.create)
    ..pPM<XctestRunResponse_TestRunInfo_TestActivity>(
        9, _omitFieldNames ? '' : 'subActivities',
        subBuilder: XctestRunResponse_TestRunInfo_TestActivity.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunResponse_TestRunInfo_TestActivity clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunResponse_TestRunInfo_TestActivity copyWith(
          void Function(XctestRunResponse_TestRunInfo_TestActivity) updates) =>
      super.copyWith((message) =>
              updates(message as XctestRunResponse_TestRunInfo_TestActivity))
          as XctestRunResponse_TestRunInfo_TestActivity;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunResponse_TestRunInfo_TestActivity create() =>
      XctestRunResponse_TestRunInfo_TestActivity._();
  @$core.override
  XctestRunResponse_TestRunInfo_TestActivity createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestRunResponse_TestRunInfo_TestActivity getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<
          XctestRunResponse_TestRunInfo_TestActivity>(create);
  static XctestRunResponse_TestRunInfo_TestActivity? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get title => $_getSZ(0);
  @$pb.TagNumber(1)
  set title($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTitle() => $_has(0);
  @$pb.TagNumber(1)
  void clearTitle() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.double get duration => $_getN(1);
  @$pb.TagNumber(2)
  set duration($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDuration() => $_has(1);
  @$pb.TagNumber(2)
  void clearDuration() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get uuid => $_getSZ(2);
  @$pb.TagNumber(3)
  set uuid($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasUuid() => $_has(2);
  @$pb.TagNumber(3)
  void clearUuid() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get activityType => $_getSZ(3);
  @$pb.TagNumber(4)
  set activityType($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasActivityType() => $_has(3);
  @$pb.TagNumber(4)
  void clearActivityType() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.double get start => $_getN(4);
  @$pb.TagNumber(5)
  set start($core.double value) => $_setDouble(4, value);
  @$pb.TagNumber(5)
  $core.bool hasStart() => $_has(4);
  @$pb.TagNumber(5)
  void clearStart() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.double get finish => $_getN(5);
  @$pb.TagNumber(6)
  set finish($core.double value) => $_setDouble(5, value);
  @$pb.TagNumber(6)
  $core.bool hasFinish() => $_has(5);
  @$pb.TagNumber(6)
  void clearFinish() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.String get name => $_getSZ(6);
  @$pb.TagNumber(7)
  set name($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasName() => $_has(6);
  @$pb.TagNumber(7)
  void clearName() => $_clearField(7);

  @$pb.TagNumber(8)
  $pb.PbList<XctestRunResponse_TestRunInfo_TestAttachment> get attachments =>
      $_getList(7);

  @$pb.TagNumber(9)
  $pb.PbList<XctestRunResponse_TestRunInfo_TestActivity> get subActivities =>
      $_getList(8);
}

class XctestRunResponse_TestRunInfo extends $pb.GeneratedMessage {
  factory XctestRunResponse_TestRunInfo({
    XctestRunResponse_TestRunInfo_Status? status,
    $core.String? bundleName,
    $core.String? className,
    $core.String? methodName,
    $core.double? duration,
    XctestRunResponse_TestRunInfo_TestRunFailureInfo? failureInfo,
    $core.Iterable<$core.String>? logs,
    $core.Iterable<XctestRunResponse_TestRunInfo_TestActivity>? activityLogs,
    $core.Iterable<XctestRunResponse_TestRunInfo_TestRunFailureInfo>?
        otherFailures,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (bundleName != null) result.bundleName = bundleName;
    if (className != null) result.className = className;
    if (methodName != null) result.methodName = methodName;
    if (duration != null) result.duration = duration;
    if (failureInfo != null) result.failureInfo = failureInfo;
    if (logs != null) result.logs.addAll(logs);
    if (activityLogs != null) result.activityLogs.addAll(activityLogs);
    if (otherFailures != null) result.otherFailures.addAll(otherFailures);
    return result;
  }

  XctestRunResponse_TestRunInfo._();

  factory XctestRunResponse_TestRunInfo.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunResponse_TestRunInfo.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestRunResponse.TestRunInfo',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<XctestRunResponse_TestRunInfo_Status>(
        1, _omitFieldNames ? '' : 'status',
        enumValues: XctestRunResponse_TestRunInfo_Status.values)
    ..aOS(2, _omitFieldNames ? '' : 'bundleName')
    ..aOS(3, _omitFieldNames ? '' : 'className')
    ..aOS(4, _omitFieldNames ? '' : 'methodName')
    ..aD(5, _omitFieldNames ? '' : 'duration')
    ..aOM<XctestRunResponse_TestRunInfo_TestRunFailureInfo>(
        6, _omitFieldNames ? '' : 'failureInfo',
        subBuilder: XctestRunResponse_TestRunInfo_TestRunFailureInfo.create)
    ..pPS(7, _omitFieldNames ? '' : 'logs')
    ..pPM<XctestRunResponse_TestRunInfo_TestActivity>(
        8, _omitFieldNames ? '' : 'activityLogs',
        protoName: 'activityLogs',
        subBuilder: XctestRunResponse_TestRunInfo_TestActivity.create)
    ..pPM<XctestRunResponse_TestRunInfo_TestRunFailureInfo>(
        9, _omitFieldNames ? '' : 'otherFailures',
        subBuilder: XctestRunResponse_TestRunInfo_TestRunFailureInfo.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunResponse_TestRunInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunResponse_TestRunInfo copyWith(
          void Function(XctestRunResponse_TestRunInfo) updates) =>
      super.copyWith(
              (message) => updates(message as XctestRunResponse_TestRunInfo))
          as XctestRunResponse_TestRunInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunResponse_TestRunInfo create() =>
      XctestRunResponse_TestRunInfo._();
  @$core.override
  XctestRunResponse_TestRunInfo createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestRunResponse_TestRunInfo getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestRunResponse_TestRunInfo>(create);
  static XctestRunResponse_TestRunInfo? _defaultInstance;

  @$pb.TagNumber(1)
  XctestRunResponse_TestRunInfo_Status get status => $_getN(0);
  @$pb.TagNumber(1)
  set status(XctestRunResponse_TestRunInfo_Status value) =>
      $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get bundleName => $_getSZ(1);
  @$pb.TagNumber(2)
  set bundleName($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBundleName() => $_has(1);
  @$pb.TagNumber(2)
  void clearBundleName() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get className => $_getSZ(2);
  @$pb.TagNumber(3)
  set className($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasClassName() => $_has(2);
  @$pb.TagNumber(3)
  void clearClassName() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get methodName => $_getSZ(3);
  @$pb.TagNumber(4)
  set methodName($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMethodName() => $_has(3);
  @$pb.TagNumber(4)
  void clearMethodName() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.double get duration => $_getN(4);
  @$pb.TagNumber(5)
  set duration($core.double value) => $_setDouble(4, value);
  @$pb.TagNumber(5)
  $core.bool hasDuration() => $_has(4);
  @$pb.TagNumber(5)
  void clearDuration() => $_clearField(5);

  @$pb.TagNumber(6)
  XctestRunResponse_TestRunInfo_TestRunFailureInfo get failureInfo => $_getN(5);
  @$pb.TagNumber(6)
  set failureInfo(XctestRunResponse_TestRunInfo_TestRunFailureInfo value) =>
      $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasFailureInfo() => $_has(5);
  @$pb.TagNumber(6)
  void clearFailureInfo() => $_clearField(6);
  @$pb.TagNumber(6)
  XctestRunResponse_TestRunInfo_TestRunFailureInfo ensureFailureInfo() =>
      $_ensure(5);

  @$pb.TagNumber(7)
  $pb.PbList<$core.String> get logs => $_getList(6);

  @$pb.TagNumber(8)
  $pb.PbList<XctestRunResponse_TestRunInfo_TestActivity> get activityLogs =>
      $_getList(7);

  @$pb.TagNumber(9)
  $pb.PbList<XctestRunResponse_TestRunInfo_TestRunFailureInfo>
      get otherFailures => $_getList(8);
}

class XctestRunResponse extends $pb.GeneratedMessage {
  factory XctestRunResponse({
    XctestRunResponse_Status? status,
    $core.Iterable<XctestRunResponse_TestRunInfo>? results,
    $core.Iterable<$core.String>? logOutput,
    Payload? resultBundle,
    $core.String? coverageJson,
    Payload? logDirectory,
    DebuggerInfo? debugger,
    Payload? codeCoverageData,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (results != null) result.results.addAll(results);
    if (logOutput != null) result.logOutput.addAll(logOutput);
    if (resultBundle != null) result.resultBundle = resultBundle;
    if (coverageJson != null) result.coverageJson = coverageJson;
    if (logDirectory != null) result.logDirectory = logDirectory;
    if (debugger != null) result.debugger = debugger;
    if (codeCoverageData != null) result.codeCoverageData = codeCoverageData;
    return result;
  }

  XctestRunResponse._();

  factory XctestRunResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory XctestRunResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'XctestRunResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<XctestRunResponse_Status>(1, _omitFieldNames ? '' : 'status',
        enumValues: XctestRunResponse_Status.values)
    ..pPM<XctestRunResponse_TestRunInfo>(2, _omitFieldNames ? '' : 'results',
        subBuilder: XctestRunResponse_TestRunInfo.create)
    ..pPS(3, _omitFieldNames ? '' : 'logOutput')
    ..aOM<Payload>(4, _omitFieldNames ? '' : 'resultBundle',
        subBuilder: Payload.create)
    ..aOS(5, _omitFieldNames ? '' : 'coverageJson')
    ..aOM<Payload>(6, _omitFieldNames ? '' : 'logDirectory',
        subBuilder: Payload.create)
    ..aOM<DebuggerInfo>(7, _omitFieldNames ? '' : 'debugger',
        subBuilder: DebuggerInfo.create)
    ..aOM<Payload>(8, _omitFieldNames ? '' : 'codeCoverageData',
        subBuilder: Payload.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  XctestRunResponse copyWith(void Function(XctestRunResponse) updates) =>
      super.copyWith((message) => updates(message as XctestRunResponse))
          as XctestRunResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static XctestRunResponse create() => XctestRunResponse._();
  @$core.override
  XctestRunResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static XctestRunResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<XctestRunResponse>(create);
  static XctestRunResponse? _defaultInstance;

  @$pb.TagNumber(1)
  XctestRunResponse_Status get status => $_getN(0);
  @$pb.TagNumber(1)
  set status(XctestRunResponse_Status value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<XctestRunResponse_TestRunInfo> get results => $_getList(1);

  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get logOutput => $_getList(2);

  @$pb.TagNumber(4)
  Payload get resultBundle => $_getN(3);
  @$pb.TagNumber(4)
  set resultBundle(Payload value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasResultBundle() => $_has(3);
  @$pb.TagNumber(4)
  void clearResultBundle() => $_clearField(4);
  @$pb.TagNumber(4)
  Payload ensureResultBundle() => $_ensure(3);

  @$pb.TagNumber(5)
  $core.String get coverageJson => $_getSZ(4);
  @$pb.TagNumber(5)
  set coverageJson($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasCoverageJson() => $_has(4);
  @$pb.TagNumber(5)
  void clearCoverageJson() => $_clearField(5);

  @$pb.TagNumber(6)
  Payload get logDirectory => $_getN(5);
  @$pb.TagNumber(6)
  set logDirectory(Payload value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasLogDirectory() => $_has(5);
  @$pb.TagNumber(6)
  void clearLogDirectory() => $_clearField(6);
  @$pb.TagNumber(6)
  Payload ensureLogDirectory() => $_ensure(5);

  @$pb.TagNumber(7)
  DebuggerInfo get debugger => $_getN(6);
  @$pb.TagNumber(7)
  set debugger(DebuggerInfo value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasDebugger() => $_has(6);
  @$pb.TagNumber(7)
  void clearDebugger() => $_clearField(7);
  @$pb.TagNumber(7)
  DebuggerInfo ensureDebugger() => $_ensure(6);

  @$pb.TagNumber(8)
  Payload get codeCoverageData => $_getN(7);
  @$pb.TagNumber(8)
  set codeCoverageData(Payload value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasCodeCoverageData() => $_has(7);
  @$pb.TagNumber(8)
  void clearCodeCoverageData() => $_clearField(8);
  @$pb.TagNumber(8)
  Payload ensureCodeCoverageData() => $_ensure(7);
}

/// Sent once, first, to start the session.
class ReplRequest_Start extends $pb.GeneratedMessage {
  factory ReplRequest_Start({
    $core.String? testBundlePath,
    ReplRequest_Start_Context? context,
    $core.String? appBundleId,
    $core.bool? reuseSession,
    $core.String? probeFilePath,
  }) {
    final result = create();
    if (testBundlePath != null) result.testBundlePath = testBundlePath;
    if (context != null) result.context = context;
    if (appBundleId != null) result.appBundleId = appBundleId;
    if (reuseSession != null) result.reuseSession = reuseSession;
    if (probeFilePath != null) result.probeFilePath = probeFilePath;
    return result;
  }

  ReplRequest_Start._();

  factory ReplRequest_Start.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReplRequest_Start.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReplRequest.Start',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'testBundlePath')
    ..aE<ReplRequest_Start_Context>(2, _omitFieldNames ? '' : 'context',
        enumValues: ReplRequest_Start_Context.values)
    ..aOS(3, _omitFieldNames ? '' : 'appBundleId')
    ..aOB(4, _omitFieldNames ? '' : 'reuseSession')
    ..aOS(5, _omitFieldNames ? '' : 'probeFilePath')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplRequest_Start clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplRequest_Start copyWith(void Function(ReplRequest_Start) updates) =>
      super.copyWith((message) => updates(message as ReplRequest_Start))
          as ReplRequest_Start;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReplRequest_Start create() => ReplRequest_Start._();
  @$core.override
  ReplRequest_Start createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReplRequest_Start getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReplRequest_Start>(create);
  static ReplRequest_Start? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get testBundlePath => $_getSZ(0);
  @$pb.TagNumber(1)
  set testBundlePath($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTestBundlePath() => $_has(0);
  @$pb.TagNumber(1)
  void clearTestBundlePath() => $_clearField(1);

  @$pb.TagNumber(2)
  ReplRequest_Start_Context get context => $_getN(1);
  @$pb.TagNumber(2)
  set context(ReplRequest_Start_Context value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasContext() => $_has(1);
  @$pb.TagNumber(2)
  void clearContext() => $_clearField(2);

  /// The bundle id to launch (with the REPL injected) for the APP context. If
  /// empty, the companion launches its bundled ReplHost app instead
  /// (installing it first if it is not already installed).
  @$pb.TagNumber(3)
  $core.String get appBundleId => $_getSZ(2);
  @$pb.TagNumber(3)
  set appBundleId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasAppBundleId() => $_has(2);
  @$pb.TagNumber(3)
  void clearAppBundleId() => $_clearField(3);

  /// APP context only: whether to reuse an already-running REPL for this app
  /// (reattach) instead of forcing a new session (a clean relaunch). idb-repl
  /// sends true by default and false when `--new-session` is passed. Unset --
  /// an older client that predates reattach -- is false, so the companion
  /// relaunches.
  @$pb.TagNumber(4)
  $core.bool get reuseSession => $_getBF(3);
  @$pb.TagNumber(4)
  set reuseSession($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasReuseSession() => $_has(3);
  @$pb.TagNumber(4)
  void clearReuseSession() => $_clearField(4);

  /// A path the driver created locally, used to detect whether the companion
  /// shares the driver's filesystem: the companion checks whether this path
  /// exists and reports the result in Ready.shared_filesystem. When they share
  /// a filesystem the driver moves captured artifacts directly; otherwise it
  /// pulls them back over gRPC.
  @$pb.TagNumber(5)
  $core.String get probeFilePath => $_getSZ(4);
  @$pb.TagNumber(5)
  set probeFilePath($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasProbeFilePath() => $_has(4);
  @$pb.TagNumber(5)
  void clearProbeFilePath() => $_clearField(5);
}

/// Sent for each piece of code to run: a compiled dylib and the symbol to
/// call.
class ReplRequest_Execute extends $pb.GeneratedMessage {
  factory ReplRequest_Execute({
    $core.List<$core.int>? dylib,
    $core.String? symbol,
  }) {
    final result = create();
    if (dylib != null) result.dylib = dylib;
    if (symbol != null) result.symbol = symbol;
    return result;
  }

  ReplRequest_Execute._();

  factory ReplRequest_Execute.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReplRequest_Execute.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReplRequest.Execute',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'dylib', $pb.PbFieldType.OY)
    ..aOS(2, _omitFieldNames ? '' : 'symbol')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplRequest_Execute clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplRequest_Execute copyWith(void Function(ReplRequest_Execute) updates) =>
      super.copyWith((message) => updates(message as ReplRequest_Execute))
          as ReplRequest_Execute;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReplRequest_Execute create() => ReplRequest_Execute._();
  @$core.override
  ReplRequest_Execute createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReplRequest_Execute getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReplRequest_Execute>(create);
  static ReplRequest_Execute? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get dylib => $_getN(0);
  @$pb.TagNumber(1)
  set dylib($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDylib() => $_has(0);
  @$pb.TagNumber(1)
  void clearDylib() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get symbol => $_getSZ(1);
  @$pb.TagNumber(2)
  set symbol($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSymbol() => $_has(1);
  @$pb.TagNumber(2)
  void clearSymbol() => $_clearField(2);
}

/// Sent to end the session (also implied by closing the stream).
class ReplRequest_Stop extends $pb.GeneratedMessage {
  factory ReplRequest_Stop() => create();

  ReplRequest_Stop._();

  factory ReplRequest_Stop.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReplRequest_Stop.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReplRequest.Stop',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplRequest_Stop clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplRequest_Stop copyWith(void Function(ReplRequest_Stop) updates) =>
      super.copyWith((message) => updates(message as ReplRequest_Stop))
          as ReplRequest_Stop;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReplRequest_Stop create() => ReplRequest_Stop._();
  @$core.override
  ReplRequest_Stop createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReplRequest_Stop getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReplRequest_Stop>(create);
  static ReplRequest_Stop? _defaultInstance;
}

enum ReplRequest_Control { start, execute, stop, notSet }

/// repl runs a test bundle in REPL mode and bridges compiled dylibs to the
/// in-process shim for execution. The client (idb-repl) compiles user code into
/// a dylib and streams it via Execute; the companion runs it in the test process
/// and streams the result back.
class ReplRequest extends $pb.GeneratedMessage {
  factory ReplRequest({
    ReplRequest_Start? start,
    ReplRequest_Execute? execute,
    ReplRequest_Stop? stop,
  }) {
    final result = create();
    if (start != null) result.start = start;
    if (execute != null) result.execute = execute;
    if (stop != null) result.stop = stop;
    return result;
  }

  ReplRequest._();

  factory ReplRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReplRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ReplRequest_Control>
      _ReplRequest_ControlByTag = {
    1: ReplRequest_Control.start,
    2: ReplRequest_Control.execute,
    3: ReplRequest_Control.stop,
    0: ReplRequest_Control.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReplRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3])
    ..aOM<ReplRequest_Start>(1, _omitFieldNames ? '' : 'start',
        subBuilder: ReplRequest_Start.create)
    ..aOM<ReplRequest_Execute>(2, _omitFieldNames ? '' : 'execute',
        subBuilder: ReplRequest_Execute.create)
    ..aOM<ReplRequest_Stop>(3, _omitFieldNames ? '' : 'stop',
        subBuilder: ReplRequest_Stop.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplRequest copyWith(void Function(ReplRequest) updates) =>
      super.copyWith((message) => updates(message as ReplRequest))
          as ReplRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReplRequest create() => ReplRequest._();
  @$core.override
  ReplRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReplRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReplRequest>(create);
  static ReplRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  ReplRequest_Control whichControl() =>
      _ReplRequest_ControlByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearControl() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  ReplRequest_Start get start => $_getN(0);
  @$pb.TagNumber(1)
  set start(ReplRequest_Start value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStart() => $_has(0);
  @$pb.TagNumber(1)
  void clearStart() => $_clearField(1);
  @$pb.TagNumber(1)
  ReplRequest_Start ensureStart() => $_ensure(0);

  @$pb.TagNumber(2)
  ReplRequest_Execute get execute => $_getN(1);
  @$pb.TagNumber(2)
  set execute(ReplRequest_Execute value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasExecute() => $_has(1);
  @$pb.TagNumber(2)
  void clearExecute() => $_clearField(2);
  @$pb.TagNumber(2)
  ReplRequest_Execute ensureExecute() => $_ensure(1);

  @$pb.TagNumber(3)
  ReplRequest_Stop get stop => $_getN(2);
  @$pb.TagNumber(3)
  set stop(ReplRequest_Stop value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasStop() => $_has(2);
  @$pb.TagNumber(3)
  void clearStop() => $_clearField(3);
  @$pb.TagNumber(3)
  ReplRequest_Stop ensureStop() => $_ensure(2);
}

/// The .swiftinterface files available to injected code (the test bundle's
/// probe-generated modules and the `IDB` module). Sent as contents rather
/// than paths so the driver can materialize them locally without sharing a
/// filesystem with the companion.
class ReplResponse_Ready_GeneratedInterface extends $pb.GeneratedMessage {
  factory ReplResponse_Ready_GeneratedInterface({
    $core.String? moduleName,
    $core.String? contents,
  }) {
    final result = create();
    if (moduleName != null) result.moduleName = moduleName;
    if (contents != null) result.contents = contents;
    return result;
  }

  ReplResponse_Ready_GeneratedInterface._();

  factory ReplResponse_Ready_GeneratedInterface.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReplResponse_Ready_GeneratedInterface.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReplResponse.Ready.GeneratedInterface',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'moduleName')
    ..aOS(2, _omitFieldNames ? '' : 'contents')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse_Ready_GeneratedInterface clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse_Ready_GeneratedInterface copyWith(
          void Function(ReplResponse_Ready_GeneratedInterface) updates) =>
      super.copyWith((message) =>
              updates(message as ReplResponse_Ready_GeneratedInterface))
          as ReplResponse_Ready_GeneratedInterface;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReplResponse_Ready_GeneratedInterface create() =>
      ReplResponse_Ready_GeneratedInterface._();
  @$core.override
  ReplResponse_Ready_GeneratedInterface createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReplResponse_Ready_GeneratedInterface getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<
          ReplResponse_Ready_GeneratedInterface>(create);
  static ReplResponse_Ready_GeneratedInterface? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get moduleName => $_getSZ(0);
  @$pb.TagNumber(1)
  set moduleName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasModuleName() => $_has(0);
  @$pb.TagNumber(1)
  void clearModuleName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get contents => $_getSZ(1);
  @$pb.TagNumber(2)
  set contents($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasContents() => $_has(1);
  @$pb.TagNumber(2)
  void clearContents() => $_clearField(2);
}

/// The test is running and the REPL is ready to accept Execute messages.
class ReplResponse_Ready extends $pb.GeneratedMessage {
  factory ReplResponse_Ready({
    $core.String? deviceType,
    $core.Iterable<ReplResponse_Ready_GeneratedInterface>? generatedInterfaces,
    $core.String? osVersion,
    $core.int? nextRunIndex,
    $core.bool? sharedFilesystem,
    $core.String? sessionId,
  }) {
    final result = create();
    if (deviceType != null) result.deviceType = deviceType;
    if (generatedInterfaces != null)
      result.generatedInterfaces.addAll(generatedInterfaces);
    if (osVersion != null) result.osVersion = osVersion;
    if (nextRunIndex != null) result.nextRunIndex = nextRunIndex;
    if (sharedFilesystem != null) result.sharedFilesystem = sharedFilesystem;
    if (sessionId != null) result.sessionId = sessionId;
    return result;
  }

  ReplResponse_Ready._();

  factory ReplResponse_Ready.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReplResponse_Ready.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReplResponse.Ready',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'deviceType')
    ..pPM<ReplResponse_Ready_GeneratedInterface>(
        2, _omitFieldNames ? '' : 'generatedInterfaces',
        subBuilder: ReplResponse_Ready_GeneratedInterface.create)
    ..aOS(4, _omitFieldNames ? '' : 'osVersion')
    ..aI(5, _omitFieldNames ? '' : 'nextRunIndex',
        fieldType: $pb.PbFieldType.OU3)
    ..aOB(6, _omitFieldNames ? '' : 'sharedFilesystem')
    ..aOS(7, _omitFieldNames ? '' : 'sessionId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse_Ready clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse_Ready copyWith(void Function(ReplResponse_Ready) updates) =>
      super.copyWith((message) => updates(message as ReplResponse_Ready))
          as ReplResponse_Ready;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReplResponse_Ready create() => ReplResponse_Ready._();
  @$core.override
  ReplResponse_Ready createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReplResponse_Ready getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReplResponse_Ready>(create);
  static ReplResponse_Ready? _defaultInstance;

  /// The product family of the connected target: "iphone", "ipad", "watch",
  /// "tv", "mac", or "unknown".
  @$pb.TagNumber(1)
  $core.String get deviceType => $_getSZ(0);
  @$pb.TagNumber(1)
  set deviceType($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDeviceType() => $_has(0);
  @$pb.TagNumber(1)
  void clearDeviceType() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<ReplResponse_Ready_GeneratedInterface> get generatedInterfaces =>
      $_getList(1);

  /// The OS version of the connected target, e.g. "26.2".
  @$pb.TagNumber(4)
  $core.String get osVersion => $_getSZ(2);
  @$pb.TagNumber(4)
  set osVersion($core.String value) => $_setString(2, value);
  @$pb.TagNumber(4)
  $core.bool hasOsVersion() => $_has(2);
  @$pb.TagNumber(4)
  void clearOsVersion() => $_clearField(4);

  /// The next index the driver should use for numbering a compiled module.
  @$pb.TagNumber(5)
  $core.int get nextRunIndex => $_getIZ(3);
  @$pb.TagNumber(5)
  set nextRunIndex($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(5)
  $core.bool hasNextRunIndex() => $_has(3);
  @$pb.TagNumber(5)
  void clearNextRunIndex() => $_clearField(5);

  /// Whether the companion shares the driver's filesystem, determined from
  /// Start.probe_file_path. When true the driver reads companion-written
  /// artifact paths directly.
  @$pb.TagNumber(6)
  $core.bool get sharedFilesystem => $_getBF(4);
  @$pb.TagNumber(6)
  set sharedFilesystem($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(6)
  $core.bool hasSharedFilesystem() => $_has(4);
  @$pb.TagNumber(6)
  void clearSharedFilesystem() => $_clearField(6);

  /// A stable identifier for the REPL host process, sent in every Ready. It
  /// persists across reconnects to a still-running `app` REPL and is
  /// regenerated on relaunch, so the driver can append to the same session
  /// report while a reset (a new session) starts a fresh one.
  @$pb.TagNumber(7)
  $core.String get sessionId => $_getSZ(5);
  @$pb.TagNumber(7)
  set sessionId($core.String value) => $_setString(5, value);
  @$pb.TagNumber(7)
  $core.bool hasSessionId() => $_has(5);
  @$pb.TagNumber(7)
  void clearSessionId() => $_clearField(7);
}

/// Files captured on the companion during this execute (screenshots saved to
/// a file, recordings). The driver retrieves each into its session's
/// artifacts directory -- moving it when the filesystem is shared, otherwise
/// pulling it over gRPC (the AUXILLARY container) and removing the companion
/// copy.
class ReplResponse_Result_Artifact extends $pb.GeneratedMessage {
  factory ReplResponse_Result_Artifact({
    $core.String? hostPath,
    $core.String? containerPath,
  }) {
    final result = create();
    if (hostPath != null) result.hostPath = hostPath;
    if (containerPath != null) result.containerPath = containerPath;
    return result;
  }

  ReplResponse_Result_Artifact._();

  factory ReplResponse_Result_Artifact.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReplResponse_Result_Artifact.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReplResponse.Result.Artifact',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'hostPath')
    ..aOS(2, _omitFieldNames ? '' : 'containerPath')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse_Result_Artifact clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse_Result_Artifact copyWith(
          void Function(ReplResponse_Result_Artifact) updates) =>
      super.copyWith(
              (message) => updates(message as ReplResponse_Result_Artifact))
          as ReplResponse_Result_Artifact;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReplResponse_Result_Artifact create() =>
      ReplResponse_Result_Artifact._();
  @$core.override
  ReplResponse_Result_Artifact createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReplResponse_Result_Artifact getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReplResponse_Result_Artifact>(create);
  static ReplResponse_Result_Artifact? _defaultInstance;

  /// The absolute path on the companion host (used for a same-filesystem
  /// move).
  @$pb.TagNumber(1)
  $core.String get hostPath => $_getSZ(0);
  @$pb.TagNumber(1)
  set hostPath($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasHostPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearHostPath() => $_clearField(1);

  /// The path relative to the AUXILLARY file container root (used to pull
  /// the file when the filesystem is not shared).
  @$pb.TagNumber(2)
  $core.String get containerPath => $_getSZ(1);
  @$pb.TagNumber(2)
  set containerPath($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasContainerPath() => $_has(1);
  @$pb.TagNumber(2)
  void clearContainerPath() => $_clearField(2);
}

/// The result of executing one Execute message.
class ReplResponse_Result extends $pb.GeneratedMessage {
  factory ReplResponse_Result({
    $core.bool? success,
    $core.String? output,
    $core.int? nextRunIndex,
    $core.Iterable<ReplResponse_Result_Artifact>? artifacts,
  }) {
    final result = create();
    if (success != null) result.success = success;
    if (output != null) result.output = output;
    if (nextRunIndex != null) result.nextRunIndex = nextRunIndex;
    if (artifacts != null) result.artifacts.addAll(artifacts);
    return result;
  }

  ReplResponse_Result._();

  factory ReplResponse_Result.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReplResponse_Result.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReplResponse.Result',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'success')
    ..aOS(2, _omitFieldNames ? '' : 'output')
    ..aI(3, _omitFieldNames ? '' : 'nextRunIndex')
    ..pPM<ReplResponse_Result_Artifact>(4, _omitFieldNames ? '' : 'artifacts',
        subBuilder: ReplResponse_Result_Artifact.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse_Result clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse_Result copyWith(void Function(ReplResponse_Result) updates) =>
      super.copyWith((message) => updates(message as ReplResponse_Result))
          as ReplResponse_Result;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReplResponse_Result create() => ReplResponse_Result._();
  @$core.override
  ReplResponse_Result createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReplResponse_Result getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReplResponse_Result>(create);
  static ReplResponse_Result? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get success => $_getBF(0);
  @$pb.TagNumber(1)
  set success($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSuccess() => $_has(0);
  @$pb.TagNumber(1)
  void clearSuccess() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get output => $_getSZ(1);
  @$pb.TagNumber(2)
  set output($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasOutput() => $_has(1);
  @$pb.TagNumber(2)
  void clearOutput() => $_clearField(2);

  /// The next index the driver should use for numbering a compiled module.
  /// A negative value signals the session has ended.
  @$pb.TagNumber(3)
  $core.int get nextRunIndex => $_getIZ(2);
  @$pb.TagNumber(3)
  set nextRunIndex($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNextRunIndex() => $_has(2);
  @$pb.TagNumber(3)
  void clearNextRunIndex() => $_clearField(3);

  @$pb.TagNumber(4)
  $pb.PbList<ReplResponse_Result_Artifact> get artifacts => $_getList(3);
}

/// The session has ended.
class ReplResponse_Stopped extends $pb.GeneratedMessage {
  factory ReplResponse_Stopped({
    $core.String? desc,
  }) {
    final result = create();
    if (desc != null) result.desc = desc;
    return result;
  }

  ReplResponse_Stopped._();

  factory ReplResponse_Stopped.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReplResponse_Stopped.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReplResponse.Stopped',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'desc')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse_Stopped clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse_Stopped copyWith(void Function(ReplResponse_Stopped) updates) =>
      super.copyWith((message) => updates(message as ReplResponse_Stopped))
          as ReplResponse_Stopped;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReplResponse_Stopped create() => ReplResponse_Stopped._();
  @$core.override
  ReplResponse_Stopped createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReplResponse_Stopped getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReplResponse_Stopped>(create);
  static ReplResponse_Stopped? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get desc => $_getSZ(0);
  @$pb.TagNumber(1)
  set desc($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDesc() => $_has(0);
  @$pb.TagNumber(1)
  void clearDesc() => $_clearField(1);
}

enum ReplResponse_Event { ready, result, stopped, notSet }

class ReplResponse extends $pb.GeneratedMessage {
  factory ReplResponse({
    ReplResponse_Ready? ready,
    ReplResponse_Result? result,
    ReplResponse_Stopped? stopped,
  }) {
    final result$ = create();
    if (ready != null) result$.ready = ready;
    if (result != null) result$.result = result;
    if (stopped != null) result$.stopped = stopped;
    return result$;
  }

  ReplResponse._();

  factory ReplResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReplResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ReplResponse_Event>
      _ReplResponse_EventByTag = {
    1: ReplResponse_Event.ready,
    2: ReplResponse_Event.result,
    3: ReplResponse_Event.stopped,
    0: ReplResponse_Event.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReplResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3])
    ..aOM<ReplResponse_Ready>(1, _omitFieldNames ? '' : 'ready',
        subBuilder: ReplResponse_Ready.create)
    ..aOM<ReplResponse_Result>(2, _omitFieldNames ? '' : 'result',
        subBuilder: ReplResponse_Result.create)
    ..aOM<ReplResponse_Stopped>(3, _omitFieldNames ? '' : 'stopped',
        subBuilder: ReplResponse_Stopped.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReplResponse copyWith(void Function(ReplResponse) updates) =>
      super.copyWith((message) => updates(message as ReplResponse))
          as ReplResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReplResponse create() => ReplResponse._();
  @$core.override
  ReplResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReplResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReplResponse>(create);
  static ReplResponse? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  ReplResponse_Event whichEvent() => _ReplResponse_EventByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearEvent() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  ReplResponse_Ready get ready => $_getN(0);
  @$pb.TagNumber(1)
  set ready(ReplResponse_Ready value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasReady() => $_has(0);
  @$pb.TagNumber(1)
  void clearReady() => $_clearField(1);
  @$pb.TagNumber(1)
  ReplResponse_Ready ensureReady() => $_ensure(0);

  @$pb.TagNumber(2)
  ReplResponse_Result get result => $_getN(1);
  @$pb.TagNumber(2)
  set result(ReplResponse_Result value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasResult() => $_has(1);
  @$pb.TagNumber(2)
  void clearResult() => $_clearField(2);
  @$pb.TagNumber(2)
  ReplResponse_Result ensureResult() => $_ensure(1);

  @$pb.TagNumber(3)
  ReplResponse_Stopped get stopped => $_getN(2);
  @$pb.TagNumber(3)
  set stopped(ReplResponse_Stopped value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasStopped() => $_has(2);
  @$pb.TagNumber(3)
  void clearStopped() => $_clearField(3);
  @$pb.TagNumber(3)
  ReplResponse_Stopped ensureStopped() => $_ensure(2);
}

class FileContainer extends $pb.GeneratedMessage {
  factory FileContainer({
    FileContainer_Kind? kind,
    $core.String? bundleId,
  }) {
    final result = create();
    if (kind != null) result.kind = kind;
    if (bundleId != null) result.bundleId = bundleId;
    return result;
  }

  FileContainer._();

  factory FileContainer.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FileContainer.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FileContainer',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aE<FileContainer_Kind>(1, _omitFieldNames ? '' : 'kind',
        enumValues: FileContainer_Kind.values)
    ..aOS(2, _omitFieldNames ? '' : 'bundleId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FileContainer clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FileContainer copyWith(void Function(FileContainer) updates) =>
      super.copyWith((message) => updates(message as FileContainer))
          as FileContainer;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FileContainer create() => FileContainer._();
  @$core.override
  FileContainer createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FileContainer getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FileContainer>(create);
  static FileContainer? _defaultInstance;

  @$pb.TagNumber(1)
  FileContainer_Kind get kind => $_getN(0);
  @$pb.TagNumber(1)
  set kind(FileContainer_Kind value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasKind() => $_has(0);
  @$pb.TagNumber(1)
  void clearKind() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get bundleId => $_getSZ(1);
  @$pb.TagNumber(2)
  set bundleId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBundleId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBundleId() => $_clearField(2);
}

class FileInfo extends $pb.GeneratedMessage {
  factory FileInfo({
    $core.String? path,
  }) {
    final result = create();
    if (path != null) result.path = path;
    return result;
  }

  FileInfo._();

  factory FileInfo.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FileInfo.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FileInfo',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'path')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FileInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FileInfo copyWith(void Function(FileInfo) updates) =>
      super.copyWith((message) => updates(message as FileInfo)) as FileInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FileInfo create() => FileInfo._();
  @$core.override
  FileInfo createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FileInfo getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<FileInfo>(create);
  static FileInfo? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(1)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearPath() => $_clearField(1);
}

class FileListing extends $pb.GeneratedMessage {
  factory FileListing({
    FileInfo? parent,
    $core.Iterable<FileInfo>? files,
  }) {
    final result = create();
    if (parent != null) result.parent = parent;
    if (files != null) result.files.addAll(files);
    return result;
  }

  FileListing._();

  factory FileListing.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FileListing.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FileListing',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<FileInfo>(1, _omitFieldNames ? '' : 'parent',
        subBuilder: FileInfo.create)
    ..pPM<FileInfo>(2, _omitFieldNames ? '' : 'files',
        subBuilder: FileInfo.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FileListing clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FileListing copyWith(void Function(FileListing) updates) =>
      super.copyWith((message) => updates(message as FileListing))
          as FileListing;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FileListing create() => FileListing._();
  @$core.override
  FileListing createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FileListing getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FileListing>(create);
  static FileListing? _defaultInstance;

  @$pb.TagNumber(1)
  FileInfo get parent => $_getN(0);
  @$pb.TagNumber(1)
  set parent(FileInfo value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasParent() => $_has(0);
  @$pb.TagNumber(1)
  void clearParent() => $_clearField(1);
  @$pb.TagNumber(1)
  FileInfo ensureParent() => $_ensure(0);

  @$pb.TagNumber(2)
  $pb.PbList<FileInfo> get files => $_getList(1);
}

class LsResponse extends $pb.GeneratedMessage {
  factory LsResponse({
    $core.Iterable<FileInfo>? files,
    $core.Iterable<FileListing>? listings,
  }) {
    final result = create();
    if (files != null) result.files.addAll(files);
    if (listings != null) result.listings.addAll(listings);
    return result;
  }

  LsResponse._();

  factory LsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory LsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LsResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPM<FileInfo>(1, _omitFieldNames ? '' : 'files',
        subBuilder: FileInfo.create)
    ..pPM<FileListing>(2, _omitFieldNames ? '' : 'listings',
        subBuilder: FileListing.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LsResponse copyWith(void Function(LsResponse) updates) =>
      super.copyWith((message) => updates(message as LsResponse)) as LsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LsResponse create() => LsResponse._();
  @$core.override
  LsResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static LsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LsResponse>(create);
  static LsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<FileInfo> get files => $_getList(0);

  @$pb.TagNumber(2)
  $pb.PbList<FileListing> get listings => $_getList(1);
}

class LsRequest extends $pb.GeneratedMessage {
  factory LsRequest({
    $core.String? path,
    FileContainer? container,
    $core.Iterable<$core.String>? paths,
  }) {
    final result = create();
    if (path != null) result.path = path;
    if (container != null) result.container = container;
    if (paths != null) result.paths.addAll(paths);
    return result;
  }

  LsRequest._();

  factory LsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory LsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LsRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(2, _omitFieldNames ? '' : 'path')
    ..aOM<FileContainer>(3, _omitFieldNames ? '' : 'container',
        subBuilder: FileContainer.create)
    ..pPS(4, _omitFieldNames ? '' : 'paths')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LsRequest copyWith(void Function(LsRequest) updates) =>
      super.copyWith((message) => updates(message as LsRequest)) as LsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LsRequest create() => LsRequest._();
  @$core.override
  LsRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static LsRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<LsRequest>(create);
  static LsRequest? _defaultInstance;

  @$pb.TagNumber(2)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(2)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(2)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(2)
  void clearPath() => $_clearField(2);

  @$pb.TagNumber(3)
  FileContainer get container => $_getN(1);
  @$pb.TagNumber(3)
  set container(FileContainer value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasContainer() => $_has(1);
  @$pb.TagNumber(3)
  void clearContainer() => $_clearField(3);
  @$pb.TagNumber(3)
  FileContainer ensureContainer() => $_ensure(1);

  @$pb.TagNumber(4)
  $pb.PbList<$core.String> get paths => $_getList(2);
}

class MkdirRequest extends $pb.GeneratedMessage {
  factory MkdirRequest({
    $core.String? path,
    FileContainer? container,
  }) {
    final result = create();
    if (path != null) result.path = path;
    if (container != null) result.container = container;
    return result;
  }

  MkdirRequest._();

  factory MkdirRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MkdirRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MkdirRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(2, _omitFieldNames ? '' : 'path')
    ..aOM<FileContainer>(3, _omitFieldNames ? '' : 'container',
        subBuilder: FileContainer.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MkdirRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MkdirRequest copyWith(void Function(MkdirRequest) updates) =>
      super.copyWith((message) => updates(message as MkdirRequest))
          as MkdirRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MkdirRequest create() => MkdirRequest._();
  @$core.override
  MkdirRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MkdirRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MkdirRequest>(create);
  static MkdirRequest? _defaultInstance;

  @$pb.TagNumber(2)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(2)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(2)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(2)
  void clearPath() => $_clearField(2);

  @$pb.TagNumber(3)
  FileContainer get container => $_getN(1);
  @$pb.TagNumber(3)
  set container(FileContainer value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasContainer() => $_has(1);
  @$pb.TagNumber(3)
  void clearContainer() => $_clearField(3);
  @$pb.TagNumber(3)
  FileContainer ensureContainer() => $_ensure(1);
}

class MkdirResponse extends $pb.GeneratedMessage {
  factory MkdirResponse() => create();

  MkdirResponse._();

  factory MkdirResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MkdirResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MkdirResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MkdirResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MkdirResponse copyWith(void Function(MkdirResponse) updates) =>
      super.copyWith((message) => updates(message as MkdirResponse))
          as MkdirResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MkdirResponse create() => MkdirResponse._();
  @$core.override
  MkdirResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MkdirResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MkdirResponse>(create);
  static MkdirResponse? _defaultInstance;
}

class MvRequest extends $pb.GeneratedMessage {
  factory MvRequest({
    $core.Iterable<$core.String>? srcPaths,
    $core.String? dstPath,
    FileContainer? container,
  }) {
    final result = create();
    if (srcPaths != null) result.srcPaths.addAll(srcPaths);
    if (dstPath != null) result.dstPath = dstPath;
    if (container != null) result.container = container;
    return result;
  }

  MvRequest._();

  factory MvRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MvRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MvRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPS(2, _omitFieldNames ? '' : 'srcPaths')
    ..aOS(3, _omitFieldNames ? '' : 'dstPath')
    ..aOM<FileContainer>(4, _omitFieldNames ? '' : 'container',
        subBuilder: FileContainer.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MvRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MvRequest copyWith(void Function(MvRequest) updates) =>
      super.copyWith((message) => updates(message as MvRequest)) as MvRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MvRequest create() => MvRequest._();
  @$core.override
  MvRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MvRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<MvRequest>(create);
  static MvRequest? _defaultInstance;

  @$pb.TagNumber(2)
  $pb.PbList<$core.String> get srcPaths => $_getList(0);

  @$pb.TagNumber(3)
  $core.String get dstPath => $_getSZ(1);
  @$pb.TagNumber(3)
  set dstPath($core.String value) => $_setString(1, value);
  @$pb.TagNumber(3)
  $core.bool hasDstPath() => $_has(1);
  @$pb.TagNumber(3)
  void clearDstPath() => $_clearField(3);

  @$pb.TagNumber(4)
  FileContainer get container => $_getN(2);
  @$pb.TagNumber(4)
  set container(FileContainer value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasContainer() => $_has(2);
  @$pb.TagNumber(4)
  void clearContainer() => $_clearField(4);
  @$pb.TagNumber(4)
  FileContainer ensureContainer() => $_ensure(2);
}

class MvResponse extends $pb.GeneratedMessage {
  factory MvResponse() => create();

  MvResponse._();

  factory MvResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MvResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MvResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MvResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MvResponse copyWith(void Function(MvResponse) updates) =>
      super.copyWith((message) => updates(message as MvResponse)) as MvResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MvResponse create() => MvResponse._();
  @$core.override
  MvResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MvResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MvResponse>(create);
  static MvResponse? _defaultInstance;
}

class RmRequest extends $pb.GeneratedMessage {
  factory RmRequest({
    $core.Iterable<$core.String>? paths,
    FileContainer? container,
  }) {
    final result = create();
    if (paths != null) result.paths.addAll(paths);
    if (container != null) result.container = container;
    return result;
  }

  RmRequest._();

  factory RmRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RmRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RmRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..pPS(2, _omitFieldNames ? '' : 'paths')
    ..aOM<FileContainer>(3, _omitFieldNames ? '' : 'container',
        subBuilder: FileContainer.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RmRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RmRequest copyWith(void Function(RmRequest) updates) =>
      super.copyWith((message) => updates(message as RmRequest)) as RmRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RmRequest create() => RmRequest._();
  @$core.override
  RmRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RmRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<RmRequest>(create);
  static RmRequest? _defaultInstance;

  @$pb.TagNumber(2)
  $pb.PbList<$core.String> get paths => $_getList(0);

  @$pb.TagNumber(3)
  FileContainer get container => $_getN(1);
  @$pb.TagNumber(3)
  set container(FileContainer value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasContainer() => $_has(1);
  @$pb.TagNumber(3)
  void clearContainer() => $_clearField(3);
  @$pb.TagNumber(3)
  FileContainer ensureContainer() => $_ensure(1);
}

class RmResponse extends $pb.GeneratedMessage {
  factory RmResponse() => create();

  RmResponse._();

  factory RmResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RmResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RmResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RmResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RmResponse copyWith(void Function(RmResponse) updates) =>
      super.copyWith((message) => updates(message as RmResponse)) as RmResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RmResponse create() => RmResponse._();
  @$core.override
  RmResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RmResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RmResponse>(create);
  static RmResponse? _defaultInstance;
}

class PushRequest_Inner extends $pb.GeneratedMessage {
  factory PushRequest_Inner({
    $core.String? dstPath,
    FileContainer? container,
  }) {
    final result = create();
    if (dstPath != null) result.dstPath = dstPath;
    if (container != null) result.container = container;
    return result;
  }

  PushRequest_Inner._();

  factory PushRequest_Inner.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PushRequest_Inner.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PushRequest.Inner',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(2, _omitFieldNames ? '' : 'dstPath')
    ..aOM<FileContainer>(3, _omitFieldNames ? '' : 'container',
        subBuilder: FileContainer.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PushRequest_Inner clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PushRequest_Inner copyWith(void Function(PushRequest_Inner) updates) =>
      super.copyWith((message) => updates(message as PushRequest_Inner))
          as PushRequest_Inner;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PushRequest_Inner create() => PushRequest_Inner._();
  @$core.override
  PushRequest_Inner createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PushRequest_Inner getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PushRequest_Inner>(create);
  static PushRequest_Inner? _defaultInstance;

  @$pb.TagNumber(2)
  $core.String get dstPath => $_getSZ(0);
  @$pb.TagNumber(2)
  set dstPath($core.String value) => $_setString(0, value);
  @$pb.TagNumber(2)
  $core.bool hasDstPath() => $_has(0);
  @$pb.TagNumber(2)
  void clearDstPath() => $_clearField(2);

  @$pb.TagNumber(3)
  FileContainer get container => $_getN(1);
  @$pb.TagNumber(3)
  set container(FileContainer value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasContainer() => $_has(1);
  @$pb.TagNumber(3)
  void clearContainer() => $_clearField(3);
  @$pb.TagNumber(3)
  FileContainer ensureContainer() => $_ensure(1);
}

enum PushRequest_Value { payload, inner, notSet }

class PushRequest extends $pb.GeneratedMessage {
  factory PushRequest({
    Payload? payload,
    PushRequest_Inner? inner,
  }) {
    final result = create();
    if (payload != null) result.payload = payload;
    if (inner != null) result.inner = inner;
    return result;
  }

  PushRequest._();

  factory PushRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PushRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, PushRequest_Value> _PushRequest_ValueByTag =
      {
    1: PushRequest_Value.payload,
    2: PushRequest_Value.inner,
    0: PushRequest_Value.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PushRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOM<Payload>(1, _omitFieldNames ? '' : 'payload',
        subBuilder: Payload.create)
    ..aOM<PushRequest_Inner>(2, _omitFieldNames ? '' : 'inner',
        subBuilder: PushRequest_Inner.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PushRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PushRequest copyWith(void Function(PushRequest) updates) =>
      super.copyWith((message) => updates(message as PushRequest))
          as PushRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PushRequest create() => PushRequest._();
  @$core.override
  PushRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PushRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PushRequest>(create);
  static PushRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  PushRequest_Value whichValue() => _PushRequest_ValueByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearValue() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  Payload get payload => $_getN(0);
  @$pb.TagNumber(1)
  set payload(Payload value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPayload() => $_has(0);
  @$pb.TagNumber(1)
  void clearPayload() => $_clearField(1);
  @$pb.TagNumber(1)
  Payload ensurePayload() => $_ensure(0);

  @$pb.TagNumber(2)
  PushRequest_Inner get inner => $_getN(1);
  @$pb.TagNumber(2)
  set inner(PushRequest_Inner value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasInner() => $_has(1);
  @$pb.TagNumber(2)
  void clearInner() => $_clearField(2);
  @$pb.TagNumber(2)
  PushRequest_Inner ensureInner() => $_ensure(1);
}

class PushResponse extends $pb.GeneratedMessage {
  factory PushResponse() => create();

  PushResponse._();

  factory PushResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PushResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PushResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PushResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PushResponse copyWith(void Function(PushResponse) updates) =>
      super.copyWith((message) => updates(message as PushResponse))
          as PushResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PushResponse create() => PushResponse._();
  @$core.override
  PushResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PushResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PushResponse>(create);
  static PushResponse? _defaultInstance;
}

class PullRequest extends $pb.GeneratedMessage {
  factory PullRequest({
    $core.String? srcPath,
    $core.String? dstPath,
    FileContainer? container,
  }) {
    final result = create();
    if (srcPath != null) result.srcPath = srcPath;
    if (dstPath != null) result.dstPath = dstPath;
    if (container != null) result.container = container;
    return result;
  }

  PullRequest._();

  factory PullRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PullRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PullRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(2, _omitFieldNames ? '' : 'srcPath')
    ..aOS(3, _omitFieldNames ? '' : 'dstPath')
    ..aOM<FileContainer>(4, _omitFieldNames ? '' : 'container',
        subBuilder: FileContainer.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PullRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PullRequest copyWith(void Function(PullRequest) updates) =>
      super.copyWith((message) => updates(message as PullRequest))
          as PullRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PullRequest create() => PullRequest._();
  @$core.override
  PullRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PullRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PullRequest>(create);
  static PullRequest? _defaultInstance;

  @$pb.TagNumber(2)
  $core.String get srcPath => $_getSZ(0);
  @$pb.TagNumber(2)
  set srcPath($core.String value) => $_setString(0, value);
  @$pb.TagNumber(2)
  $core.bool hasSrcPath() => $_has(0);
  @$pb.TagNumber(2)
  void clearSrcPath() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get dstPath => $_getSZ(1);
  @$pb.TagNumber(3)
  set dstPath($core.String value) => $_setString(1, value);
  @$pb.TagNumber(3)
  $core.bool hasDstPath() => $_has(1);
  @$pb.TagNumber(3)
  void clearDstPath() => $_clearField(3);

  @$pb.TagNumber(4)
  FileContainer get container => $_getN(2);
  @$pb.TagNumber(4)
  set container(FileContainer value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasContainer() => $_has(2);
  @$pb.TagNumber(4)
  void clearContainer() => $_clearField(4);
  @$pb.TagNumber(4)
  FileContainer ensureContainer() => $_ensure(2);
}

class PullResponse extends $pb.GeneratedMessage {
  factory PullResponse({
    Payload? payload,
  }) {
    final result = create();
    if (payload != null) result.payload = payload;
    return result;
  }

  PullResponse._();

  factory PullResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PullResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PullResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<Payload>(1, _omitFieldNames ? '' : 'payload',
        subBuilder: Payload.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PullResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PullResponse copyWith(void Function(PullResponse) updates) =>
      super.copyWith((message) => updates(message as PullResponse))
          as PullResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PullResponse create() => PullResponse._();
  @$core.override
  PullResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PullResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PullResponse>(create);
  static PullResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Payload get payload => $_getN(0);
  @$pb.TagNumber(1)
  set payload(Payload value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPayload() => $_has(0);
  @$pb.TagNumber(1)
  void clearPayload() => $_clearField(1);
  @$pb.TagNumber(1)
  Payload ensurePayload() => $_ensure(0);
}

class TailRequest_Start extends $pb.GeneratedMessage {
  factory TailRequest_Start({
    FileContainer? container,
    $core.String? path,
  }) {
    final result = create();
    if (container != null) result.container = container;
    if (path != null) result.path = path;
    return result;
  }

  TailRequest_Start._();

  factory TailRequest_Start.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TailRequest_Start.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TailRequest.Start',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOM<FileContainer>(1, _omitFieldNames ? '' : 'container',
        subBuilder: FileContainer.create)
    ..aOS(2, _omitFieldNames ? '' : 'path')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TailRequest_Start clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TailRequest_Start copyWith(void Function(TailRequest_Start) updates) =>
      super.copyWith((message) => updates(message as TailRequest_Start))
          as TailRequest_Start;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TailRequest_Start create() => TailRequest_Start._();
  @$core.override
  TailRequest_Start createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TailRequest_Start getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TailRequest_Start>(create);
  static TailRequest_Start? _defaultInstance;

  @$pb.TagNumber(1)
  FileContainer get container => $_getN(0);
  @$pb.TagNumber(1)
  set container(FileContainer value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasContainer() => $_has(0);
  @$pb.TagNumber(1)
  void clearContainer() => $_clearField(1);
  @$pb.TagNumber(1)
  FileContainer ensureContainer() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.String get path => $_getSZ(1);
  @$pb.TagNumber(2)
  set path($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPath() => $_has(1);
  @$pb.TagNumber(2)
  void clearPath() => $_clearField(2);
}

class TailRequest_Stop extends $pb.GeneratedMessage {
  factory TailRequest_Stop() => create();

  TailRequest_Stop._();

  factory TailRequest_Stop.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TailRequest_Stop.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TailRequest.Stop',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TailRequest_Stop clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TailRequest_Stop copyWith(void Function(TailRequest_Stop) updates) =>
      super.copyWith((message) => updates(message as TailRequest_Stop))
          as TailRequest_Stop;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TailRequest_Stop create() => TailRequest_Stop._();
  @$core.override
  TailRequest_Stop createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TailRequest_Stop getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TailRequest_Stop>(create);
  static TailRequest_Stop? _defaultInstance;
}

enum TailRequest_Control { start, stop, notSet }

class TailRequest extends $pb.GeneratedMessage {
  factory TailRequest({
    TailRequest_Start? start,
    TailRequest_Stop? stop,
  }) {
    final result = create();
    if (start != null) result.start = start;
    if (stop != null) result.stop = stop;
    return result;
  }

  TailRequest._();

  factory TailRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TailRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, TailRequest_Control>
      _TailRequest_ControlByTag = {
    1: TailRequest_Control.start,
    2: TailRequest_Control.stop,
    0: TailRequest_Control.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TailRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOM<TailRequest_Start>(1, _omitFieldNames ? '' : 'start',
        subBuilder: TailRequest_Start.create)
    ..aOM<TailRequest_Stop>(2, _omitFieldNames ? '' : 'stop',
        subBuilder: TailRequest_Stop.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TailRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TailRequest copyWith(void Function(TailRequest) updates) =>
      super.copyWith((message) => updates(message as TailRequest))
          as TailRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TailRequest create() => TailRequest._();
  @$core.override
  TailRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TailRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TailRequest>(create);
  static TailRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  TailRequest_Control whichControl() =>
      _TailRequest_ControlByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearControl() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  TailRequest_Start get start => $_getN(0);
  @$pb.TagNumber(1)
  set start(TailRequest_Start value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStart() => $_has(0);
  @$pb.TagNumber(1)
  void clearStart() => $_clearField(1);
  @$pb.TagNumber(1)
  TailRequest_Start ensureStart() => $_ensure(0);

  @$pb.TagNumber(2)
  TailRequest_Stop get stop => $_getN(1);
  @$pb.TagNumber(2)
  set stop(TailRequest_Stop value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStop() => $_has(1);
  @$pb.TagNumber(2)
  void clearStop() => $_clearField(2);
  @$pb.TagNumber(2)
  TailRequest_Stop ensureStop() => $_ensure(1);
}

class TailResponse extends $pb.GeneratedMessage {
  factory TailResponse({
    $core.List<$core.int>? data,
  }) {
    final result = create();
    if (data != null) result.data = data;
    return result;
  }

  TailResponse._();

  factory TailResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TailResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TailResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TailResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TailResponse copyWith(void Function(TailResponse) updates) =>
      super.copyWith((message) => updates(message as TailResponse))
          as TailResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TailResponse create() => TailResponse._();
  @$core.override
  TailResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TailResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TailResponse>(create);
  static TailResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get data => $_getN(0);
  @$pb.TagNumber(1)
  set data($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasData() => $_has(0);
  @$pb.TagNumber(1)
  void clearData() => $_clearField(1);
}

class DebuggerInfo extends $pb.GeneratedMessage {
  factory DebuggerInfo({
    $fixnum.Int64? pid,
    $core.String? host,
    $fixnum.Int64? port,
  }) {
    final result = create();
    if (pid != null) result.pid = pid;
    if (host != null) result.host = host;
    if (port != null) result.port = port;
    return result;
  }

  DebuggerInfo._();

  factory DebuggerInfo.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DebuggerInfo.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DebuggerInfo',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$fixnum.Int64>(1, _omitFieldNames ? '' : 'pid', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(2, _omitFieldNames ? '' : 'host')
    ..a<$fixnum.Int64>(3, _omitFieldNames ? '' : 'port', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebuggerInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DebuggerInfo copyWith(void Function(DebuggerInfo) updates) =>
      super.copyWith((message) => updates(message as DebuggerInfo))
          as DebuggerInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DebuggerInfo create() => DebuggerInfo._();
  @$core.override
  DebuggerInfo createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DebuggerInfo getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DebuggerInfo>(create);
  static DebuggerInfo? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get pid => $_getI64(0);
  @$pb.TagNumber(1)
  set pid($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPid() => $_has(0);
  @$pb.TagNumber(1)
  void clearPid() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get host => $_getSZ(1);
  @$pb.TagNumber(2)
  set host($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasHost() => $_has(1);
  @$pb.TagNumber(2)
  void clearHost() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get port => $_getI64(2);
  @$pb.TagNumber(3)
  set port($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPort() => $_has(2);
  @$pb.TagNumber(3)
  void clearPort() => $_clearField(3);
}

class SendNotificationRequest extends $pb.GeneratedMessage {
  factory SendNotificationRequest({
    $core.String? bundleId,
    $core.String? jsonPayload,
  }) {
    final result = create();
    if (bundleId != null) result.bundleId = bundleId;
    if (jsonPayload != null) result.jsonPayload = jsonPayload;
    return result;
  }

  SendNotificationRequest._();

  factory SendNotificationRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SendNotificationRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SendNotificationRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'bundleId')
    ..aOS(2, _omitFieldNames ? '' : 'jsonPayload')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SendNotificationRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SendNotificationRequest copyWith(
          void Function(SendNotificationRequest) updates) =>
      super.copyWith((message) => updates(message as SendNotificationRequest))
          as SendNotificationRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SendNotificationRequest create() => SendNotificationRequest._();
  @$core.override
  SendNotificationRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SendNotificationRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SendNotificationRequest>(create);
  static SendNotificationRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get bundleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set bundleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBundleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBundleId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get jsonPayload => $_getSZ(1);
  @$pb.TagNumber(2)
  set jsonPayload($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasJsonPayload() => $_has(1);
  @$pb.TagNumber(2)
  void clearJsonPayload() => $_clearField(2);
}

class SendNotificationResponse extends $pb.GeneratedMessage {
  factory SendNotificationResponse() => create();

  SendNotificationResponse._();

  factory SendNotificationResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SendNotificationResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SendNotificationResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SendNotificationResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SendNotificationResponse copyWith(
          void Function(SendNotificationResponse) updates) =>
      super.copyWith((message) => updates(message as SendNotificationResponse))
          as SendNotificationResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SendNotificationResponse create() => SendNotificationResponse._();
  @$core.override
  SendNotificationResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SendNotificationResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SendNotificationResponse>(create);
  static SendNotificationResponse? _defaultInstance;
}

class DapRequest_Start extends $pb.GeneratedMessage {
  factory DapRequest_Start({
    $core.String? debuggerPkgId,
  }) {
    final result = create();
    if (debuggerPkgId != null) result.debuggerPkgId = debuggerPkgId;
    return result;
  }

  DapRequest_Start._();

  factory DapRequest_Start.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DapRequest_Start.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DapRequest.Start',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'debuggerPkgId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapRequest_Start clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapRequest_Start copyWith(void Function(DapRequest_Start) updates) =>
      super.copyWith((message) => updates(message as DapRequest_Start))
          as DapRequest_Start;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DapRequest_Start create() => DapRequest_Start._();
  @$core.override
  DapRequest_Start createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DapRequest_Start getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DapRequest_Start>(create);
  static DapRequest_Start? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get debuggerPkgId => $_getSZ(0);
  @$pb.TagNumber(1)
  set debuggerPkgId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDebuggerPkgId() => $_has(0);
  @$pb.TagNumber(1)
  void clearDebuggerPkgId() => $_clearField(1);
}

class DapRequest_Pipe extends $pb.GeneratedMessage {
  factory DapRequest_Pipe({
    $core.List<$core.int>? data,
  }) {
    final result = create();
    if (data != null) result.data = data;
    return result;
  }

  DapRequest_Pipe._();

  factory DapRequest_Pipe.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DapRequest_Pipe.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DapRequest.Pipe',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapRequest_Pipe clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapRequest_Pipe copyWith(void Function(DapRequest_Pipe) updates) =>
      super.copyWith((message) => updates(message as DapRequest_Pipe))
          as DapRequest_Pipe;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DapRequest_Pipe create() => DapRequest_Pipe._();
  @$core.override
  DapRequest_Pipe createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DapRequest_Pipe getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DapRequest_Pipe>(create);
  static DapRequest_Pipe? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get data => $_getN(0);
  @$pb.TagNumber(1)
  set data($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasData() => $_has(0);
  @$pb.TagNumber(1)
  void clearData() => $_clearField(1);
}

class DapRequest_Stop extends $pb.GeneratedMessage {
  factory DapRequest_Stop() => create();

  DapRequest_Stop._();

  factory DapRequest_Stop.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DapRequest_Stop.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DapRequest.Stop',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapRequest_Stop clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapRequest_Stop copyWith(void Function(DapRequest_Stop) updates) =>
      super.copyWith((message) => updates(message as DapRequest_Stop))
          as DapRequest_Stop;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DapRequest_Stop create() => DapRequest_Stop._();
  @$core.override
  DapRequest_Stop createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DapRequest_Stop getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DapRequest_Stop>(create);
  static DapRequest_Stop? _defaultInstance;
}

enum DapRequest_Control { start, pipe, stop, notSet }

class DapRequest extends $pb.GeneratedMessage {
  factory DapRequest({
    DapRequest_Start? start,
    DapRequest_Pipe? pipe,
    DapRequest_Stop? stop,
  }) {
    final result = create();
    if (start != null) result.start = start;
    if (pipe != null) result.pipe = pipe;
    if (stop != null) result.stop = stop;
    return result;
  }

  DapRequest._();

  factory DapRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DapRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, DapRequest_Control>
      _DapRequest_ControlByTag = {
    1: DapRequest_Control.start,
    2: DapRequest_Control.pipe,
    3: DapRequest_Control.stop,
    0: DapRequest_Control.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DapRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3])
    ..aOM<DapRequest_Start>(1, _omitFieldNames ? '' : 'start',
        subBuilder: DapRequest_Start.create)
    ..aOM<DapRequest_Pipe>(2, _omitFieldNames ? '' : 'pipe',
        subBuilder: DapRequest_Pipe.create)
    ..aOM<DapRequest_Stop>(3, _omitFieldNames ? '' : 'stop',
        subBuilder: DapRequest_Stop.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapRequest copyWith(void Function(DapRequest) updates) =>
      super.copyWith((message) => updates(message as DapRequest)) as DapRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DapRequest create() => DapRequest._();
  @$core.override
  DapRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DapRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DapRequest>(create);
  static DapRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  DapRequest_Control whichControl() =>
      _DapRequest_ControlByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearControl() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  DapRequest_Start get start => $_getN(0);
  @$pb.TagNumber(1)
  set start(DapRequest_Start value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStart() => $_has(0);
  @$pb.TagNumber(1)
  void clearStart() => $_clearField(1);
  @$pb.TagNumber(1)
  DapRequest_Start ensureStart() => $_ensure(0);

  @$pb.TagNumber(2)
  DapRequest_Pipe get pipe => $_getN(1);
  @$pb.TagNumber(2)
  set pipe(DapRequest_Pipe value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPipe() => $_has(1);
  @$pb.TagNumber(2)
  void clearPipe() => $_clearField(2);
  @$pb.TagNumber(2)
  DapRequest_Pipe ensurePipe() => $_ensure(1);

  @$pb.TagNumber(3)
  DapRequest_Stop get stop => $_getN(2);
  @$pb.TagNumber(3)
  set stop(DapRequest_Stop value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasStop() => $_has(2);
  @$pb.TagNumber(3)
  void clearStop() => $_clearField(3);
  @$pb.TagNumber(3)
  DapRequest_Stop ensureStop() => $_ensure(2);
}

class DapResponse_Event extends $pb.GeneratedMessage {
  factory DapResponse_Event({
    $core.String? desc,
  }) {
    final result = create();
    if (desc != null) result.desc = desc;
    return result;
  }

  DapResponse_Event._();

  factory DapResponse_Event.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DapResponse_Event.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DapResponse.Event',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'desc')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapResponse_Event clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapResponse_Event copyWith(void Function(DapResponse_Event) updates) =>
      super.copyWith((message) => updates(message as DapResponse_Event))
          as DapResponse_Event;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DapResponse_Event create() => DapResponse_Event._();
  @$core.override
  DapResponse_Event createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DapResponse_Event getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DapResponse_Event>(create);
  static DapResponse_Event? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get desc => $_getSZ(0);
  @$pb.TagNumber(1)
  set desc($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDesc() => $_has(0);
  @$pb.TagNumber(1)
  void clearDesc() => $_clearField(1);
}

class DapResponse_Pipe extends $pb.GeneratedMessage {
  factory DapResponse_Pipe({
    $core.List<$core.int>? data,
  }) {
    final result = create();
    if (data != null) result.data = data;
    return result;
  }

  DapResponse_Pipe._();

  factory DapResponse_Pipe.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DapResponse_Pipe.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DapResponse.Pipe',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapResponse_Pipe clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapResponse_Pipe copyWith(void Function(DapResponse_Pipe) updates) =>
      super.copyWith((message) => updates(message as DapResponse_Pipe))
          as DapResponse_Pipe;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DapResponse_Pipe create() => DapResponse_Pipe._();
  @$core.override
  DapResponse_Pipe createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DapResponse_Pipe getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DapResponse_Pipe>(create);
  static DapResponse_Pipe? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get data => $_getN(0);
  @$pb.TagNumber(1)
  set data($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasData() => $_has(0);
  @$pb.TagNumber(1)
  void clearData() => $_clearField(1);
}

enum DapResponse_Event_ { started, stdout, stopped, notSet }

class DapResponse extends $pb.GeneratedMessage {
  factory DapResponse({
    DapResponse_Event? started,
    DapResponse_Pipe? stdout,
    DapResponse_Event? stopped,
  }) {
    final result = create();
    if (started != null) result.started = started;
    if (stdout != null) result.stdout = stdout;
    if (stopped != null) result.stopped = stopped;
    return result;
  }

  DapResponse._();

  factory DapResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DapResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, DapResponse_Event_>
      _DapResponse_Event_ByTag = {
    1: DapResponse_Event_.started,
    2: DapResponse_Event_.stdout,
    3: DapResponse_Event_.stopped,
    0: DapResponse_Event_.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DapResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3])
    ..aOM<DapResponse_Event>(1, _omitFieldNames ? '' : 'started',
        subBuilder: DapResponse_Event.create)
    ..aOM<DapResponse_Pipe>(2, _omitFieldNames ? '' : 'stdout',
        subBuilder: DapResponse_Pipe.create)
    ..aOM<DapResponse_Event>(3, _omitFieldNames ? '' : 'stopped',
        subBuilder: DapResponse_Event.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DapResponse copyWith(void Function(DapResponse) updates) =>
      super.copyWith((message) => updates(message as DapResponse))
          as DapResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DapResponse create() => DapResponse._();
  @$core.override
  DapResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DapResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DapResponse>(create);
  static DapResponse? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  DapResponse_Event_ whichEvent() => _DapResponse_Event_ByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearEvent() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  DapResponse_Event get started => $_getN(0);
  @$pb.TagNumber(1)
  set started(DapResponse_Event value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStarted() => $_has(0);
  @$pb.TagNumber(1)
  void clearStarted() => $_clearField(1);
  @$pb.TagNumber(1)
  DapResponse_Event ensureStarted() => $_ensure(0);

  @$pb.TagNumber(2)
  DapResponse_Pipe get stdout => $_getN(1);
  @$pb.TagNumber(2)
  set stdout(DapResponse_Pipe value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStdout() => $_has(1);
  @$pb.TagNumber(2)
  void clearStdout() => $_clearField(2);
  @$pb.TagNumber(2)
  DapResponse_Pipe ensureStdout() => $_ensure(1);

  @$pb.TagNumber(3)
  DapResponse_Event get stopped => $_getN(2);
  @$pb.TagNumber(3)
  set stopped(DapResponse_Event value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasStopped() => $_has(2);
  @$pb.TagNumber(3)
  void clearStopped() => $_clearField(3);
  @$pb.TagNumber(3)
  DapResponse_Event ensureStopped() => $_ensure(2);
}

class SimulateMemoryWarningRequest extends $pb.GeneratedMessage {
  factory SimulateMemoryWarningRequest() => create();

  SimulateMemoryWarningRequest._();

  factory SimulateMemoryWarningRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SimulateMemoryWarningRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SimulateMemoryWarningRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SimulateMemoryWarningRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SimulateMemoryWarningRequest copyWith(
          void Function(SimulateMemoryWarningRequest) updates) =>
      super.copyWith(
              (message) => updates(message as SimulateMemoryWarningRequest))
          as SimulateMemoryWarningRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SimulateMemoryWarningRequest create() =>
      SimulateMemoryWarningRequest._();
  @$core.override
  SimulateMemoryWarningRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SimulateMemoryWarningRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SimulateMemoryWarningRequest>(create);
  static SimulateMemoryWarningRequest? _defaultInstance;
}

class SimulateMemoryWarningResponse extends $pb.GeneratedMessage {
  factory SimulateMemoryWarningResponse() => create();

  SimulateMemoryWarningResponse._();

  factory SimulateMemoryWarningResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SimulateMemoryWarningResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SimulateMemoryWarningResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'idb'),
      createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SimulateMemoryWarningResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SimulateMemoryWarningResponse copyWith(
          void Function(SimulateMemoryWarningResponse) updates) =>
      super.copyWith(
              (message) => updates(message as SimulateMemoryWarningResponse))
          as SimulateMemoryWarningResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SimulateMemoryWarningResponse create() =>
      SimulateMemoryWarningResponse._();
  @$core.override
  SimulateMemoryWarningResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SimulateMemoryWarningResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SimulateMemoryWarningResponse>(create);
  static SimulateMemoryWarningResponse? _defaultInstance;
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
