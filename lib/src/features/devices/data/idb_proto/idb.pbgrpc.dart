// This is a generated file - do not edit.
//
// Generated from idb.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import 'idb.pb.dart' as $0;

export 'idb.pb.dart';

/// The idb companion service definition.
@$pb.GrpcServiceName('idb.CompanionService')
class CompanionServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  CompanionServiceClient(super.channel, {super.options, super.interceptors});

  /// Management
  $grpc.ResponseFuture<$0.ConnectResponse> connect(
    $0.ConnectRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$connect, request, options: options);
  }

  $grpc.ResponseStream<$0.DebugServerResponse> debugserver(
    $async.Stream<$0.DebugServerRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$debugserver, request, options: options);
  }

  $grpc.ResponseStream<$0.DapResponse> dap(
    $async.Stream<$0.DapRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$dap, request, options: options);
  }

  $grpc.ResponseFuture<$0.TargetDescriptionResponse> describe(
    $0.TargetDescriptionRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$describe, request, options: options);
  }

  $grpc.ResponseStream<$0.InstallResponse> install(
    $async.Stream<$0.InstallRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$install, request, options: options);
  }

  $grpc.ResponseStream<$0.InstrumentsRunResponse> instruments_run(
    $async.Stream<$0.InstrumentsRunRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$instruments_run, request, options: options);
  }

  $grpc.ResponseStream<$0.LogResponse> log(
    $0.LogRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$log, $async.Stream.fromIterable([request]),
        options: options);
  }

  $grpc.ResponseStream<$0.XctraceRecordResponse> xctrace_record(
    $async.Stream<$0.XctraceRecordRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$xctrace_record, request, options: options);
  }

  /// Interaction
  $grpc.ResponseFuture<$0.AccessibilityInfoResponse> accessibility_info(
    $0.AccessibilityInfoRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$accessibility_info, request, options: options);
  }

  $grpc.ResponseFuture<$0.AccessibilityActionResponse> accessibility_action(
    $0.AccessibilityActionRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$accessibility_action, request, options: options);
  }

  $grpc.ResponseFuture<$0.FocusResponse> focus(
    $0.FocusRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$focus, request, options: options);
  }

  $grpc.ResponseFuture<$0.HIDResponse> hid(
    $async.Stream<$0.HIDEvent> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$hid, request, options: options).single;
  }

  $grpc.ResponseFuture<$0.OpenUrlRequest> open_url(
    $0.OpenUrlRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$open_url, request, options: options);
  }

  $grpc.ResponseFuture<$0.SetLocationResponse> set_location(
    $0.SetLocationRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$set_location, request, options: options);
  }

  $grpc.ResponseFuture<$0.SendNotificationResponse> send_notification(
    $0.SendNotificationRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$send_notification, request, options: options);
  }

  $grpc.ResponseFuture<$0.SimulateMemoryWarningResponse>
      simulate_memory_warning(
    $0.SimulateMemoryWarningRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$simulate_memory_warning, request,
        options: options);
  }

  /// Settings
  $grpc.ResponseFuture<$0.ApproveResponse> approve(
    $0.ApproveRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$approve, request, options: options);
  }

  $grpc.ResponseFuture<$0.RevokeResponse> revoke(
    $0.RevokeRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$revoke, request, options: options);
  }

  $grpc.ResponseFuture<$0.ClearKeychainResponse> clear_keychain(
    $0.ClearKeychainRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$clear_keychain, request, options: options);
  }

  $grpc.ResponseFuture<$0.ContactsUpdateResponse> contacts_update(
    $0.ContactsUpdateRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$contacts_update, request, options: options);
  }

  $grpc.ResponseFuture<$0.ContactsClearResponse> contacts_clear(
    $0.ContactsClearRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$contacts_clear, request, options: options);
  }

  $grpc.ResponseFuture<$0.PhotosClearResponse> photos_clear(
    $0.PhotosClearRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$photos_clear, request, options: options);
  }

  $grpc.ResponseFuture<$0.SettingResponse> setting(
    $0.SettingRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$setting, request, options: options);
  }

  $grpc.ResponseFuture<$0.GetSettingResponse> get_setting(
    $0.GetSettingRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$get_setting, request, options: options);
  }

  $grpc.ResponseFuture<$0.ListSettingResponse> list_settings(
    $0.ListSettingRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$list_settings, request, options: options);
  }

  /// App
  $grpc.ResponseStream<$0.LaunchResponse> launch(
    $async.Stream<$0.LaunchRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$launch, request, options: options);
  }

  $grpc.ResponseFuture<$0.ListAppsResponse> list_apps(
    $0.ListAppsRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$list_apps, request, options: options);
  }

  $grpc.ResponseFuture<$0.TerminateResponse> terminate(
    $0.TerminateRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$terminate, request, options: options);
  }

  $grpc.ResponseFuture<$0.UninstallResponse> uninstall(
    $0.UninstallRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$uninstall, request, options: options);
  }

  /// Video/Audio
  $grpc.ResponseFuture<$0.AddMediaResponse> add_media(
    $async.Stream<$0.AddMediaRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$add_media, request, options: options).single;
  }

  $grpc.ResponseStream<$0.RecordResponse> record(
    $async.Stream<$0.RecordRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$record, request, options: options);
  }

  $grpc.ResponseFuture<$0.ScreenshotResponse> screenshot(
    $0.ScreenshotRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$screenshot, request, options: options);
  }

  $grpc.ResponseStream<$0.VideoStreamResponse> video_stream(
    $async.Stream<$0.VideoStreamRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$video_stream, request, options: options);
  }

  /// Crash Operations
  $grpc.ResponseFuture<$0.CrashLogResponse> crash_delete(
    $0.CrashLogQuery request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$crash_delete, request, options: options);
  }

  $grpc.ResponseFuture<$0.CrashLogResponse> crash_list(
    $0.CrashLogQuery request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$crash_list, request, options: options);
  }

  $grpc.ResponseFuture<$0.CrashShowResponse> crash_show(
    $0.CrashShowRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$crash_show, request, options: options);
  }

  /// xctest operations
  $grpc.ResponseFuture<$0.XctestListBundlesResponse> xctest_list_bundles(
    $0.XctestListBundlesRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$xctest_list_bundles, request, options: options);
  }

  $grpc.ResponseFuture<$0.XctestListTestsResponse> xctest_list_tests(
    $0.XctestListTestsRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$xctest_list_tests, request, options: options);
  }

  $grpc.ResponseStream<$0.XctestRunResponse> xctest_run(
    $0.XctestRunRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(
        _$xctest_run, $async.Stream.fromIterable([request]),
        options: options);
  }

  $grpc.ResponseStream<$0.ReplResponse> repl(
    $async.Stream<$0.ReplRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$repl, request, options: options);
  }

  /// File Operations
  $grpc.ResponseFuture<$0.LsResponse> ls(
    $0.LsRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$ls, request, options: options);
  }

  $grpc.ResponseFuture<$0.MkdirResponse> mkdir(
    $0.MkdirRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$mkdir, request, options: options);
  }

  $grpc.ResponseFuture<$0.MvResponse> mv(
    $0.MvRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$mv, request, options: options);
  }

  $grpc.ResponseFuture<$0.RmResponse> rm(
    $0.RmRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$rm, request, options: options);
  }

  $grpc.ResponseStream<$0.PullResponse> pull(
    $0.PullRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$pull, $async.Stream.fromIterable([request]),
        options: options);
  }

  $grpc.ResponseFuture<$0.PushResponse> push(
    $async.Stream<$0.PushRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$push, request, options: options).single;
  }

  $grpc.ResponseStream<$0.TailResponse> tail(
    $async.Stream<$0.TailRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$tail, request, options: options);
  }

  // method descriptors

  static final _$connect =
      $grpc.ClientMethod<$0.ConnectRequest, $0.ConnectResponse>(
          '/idb.CompanionService/connect',
          ($0.ConnectRequest value) => value.writeToBuffer(),
          $0.ConnectResponse.fromBuffer);
  static final _$debugserver =
      $grpc.ClientMethod<$0.DebugServerRequest, $0.DebugServerResponse>(
          '/idb.CompanionService/debugserver',
          ($0.DebugServerRequest value) => value.writeToBuffer(),
          $0.DebugServerResponse.fromBuffer);
  static final _$dap = $grpc.ClientMethod<$0.DapRequest, $0.DapResponse>(
      '/idb.CompanionService/dap',
      ($0.DapRequest value) => value.writeToBuffer(),
      $0.DapResponse.fromBuffer);
  static final _$describe = $grpc.ClientMethod<$0.TargetDescriptionRequest,
          $0.TargetDescriptionResponse>(
      '/idb.CompanionService/describe',
      ($0.TargetDescriptionRequest value) => value.writeToBuffer(),
      $0.TargetDescriptionResponse.fromBuffer);
  static final _$install =
      $grpc.ClientMethod<$0.InstallRequest, $0.InstallResponse>(
          '/idb.CompanionService/install',
          ($0.InstallRequest value) => value.writeToBuffer(),
          $0.InstallResponse.fromBuffer);
  static final _$instruments_run =
      $grpc.ClientMethod<$0.InstrumentsRunRequest, $0.InstrumentsRunResponse>(
          '/idb.CompanionService/instruments_run',
          ($0.InstrumentsRunRequest value) => value.writeToBuffer(),
          $0.InstrumentsRunResponse.fromBuffer);
  static final _$log = $grpc.ClientMethod<$0.LogRequest, $0.LogResponse>(
      '/idb.CompanionService/log',
      ($0.LogRequest value) => value.writeToBuffer(),
      $0.LogResponse.fromBuffer);
  static final _$xctrace_record =
      $grpc.ClientMethod<$0.XctraceRecordRequest, $0.XctraceRecordResponse>(
          '/idb.CompanionService/xctrace_record',
          ($0.XctraceRecordRequest value) => value.writeToBuffer(),
          $0.XctraceRecordResponse.fromBuffer);
  static final _$accessibility_info = $grpc.ClientMethod<
          $0.AccessibilityInfoRequest, $0.AccessibilityInfoResponse>(
      '/idb.CompanionService/accessibility_info',
      ($0.AccessibilityInfoRequest value) => value.writeToBuffer(),
      $0.AccessibilityInfoResponse.fromBuffer);
  static final _$accessibility_action = $grpc.ClientMethod<
          $0.AccessibilityActionRequest, $0.AccessibilityActionResponse>(
      '/idb.CompanionService/accessibility_action',
      ($0.AccessibilityActionRequest value) => value.writeToBuffer(),
      $0.AccessibilityActionResponse.fromBuffer);
  static final _$focus = $grpc.ClientMethod<$0.FocusRequest, $0.FocusResponse>(
      '/idb.CompanionService/focus',
      ($0.FocusRequest value) => value.writeToBuffer(),
      $0.FocusResponse.fromBuffer);
  static final _$hid = $grpc.ClientMethod<$0.HIDEvent, $0.HIDResponse>(
      '/idb.CompanionService/hid',
      ($0.HIDEvent value) => value.writeToBuffer(),
      $0.HIDResponse.fromBuffer);
  static final _$open_url =
      $grpc.ClientMethod<$0.OpenUrlRequest, $0.OpenUrlRequest>(
          '/idb.CompanionService/open_url',
          ($0.OpenUrlRequest value) => value.writeToBuffer(),
          $0.OpenUrlRequest.fromBuffer);
  static final _$set_location =
      $grpc.ClientMethod<$0.SetLocationRequest, $0.SetLocationResponse>(
          '/idb.CompanionService/set_location',
          ($0.SetLocationRequest value) => value.writeToBuffer(),
          $0.SetLocationResponse.fromBuffer);
  static final _$send_notification = $grpc.ClientMethod<
          $0.SendNotificationRequest, $0.SendNotificationResponse>(
      '/idb.CompanionService/send_notification',
      ($0.SendNotificationRequest value) => value.writeToBuffer(),
      $0.SendNotificationResponse.fromBuffer);
  static final _$simulate_memory_warning = $grpc.ClientMethod<
          $0.SimulateMemoryWarningRequest, $0.SimulateMemoryWarningResponse>(
      '/idb.CompanionService/simulate_memory_warning',
      ($0.SimulateMemoryWarningRequest value) => value.writeToBuffer(),
      $0.SimulateMemoryWarningResponse.fromBuffer);
  static final _$approve =
      $grpc.ClientMethod<$0.ApproveRequest, $0.ApproveResponse>(
          '/idb.CompanionService/approve',
          ($0.ApproveRequest value) => value.writeToBuffer(),
          $0.ApproveResponse.fromBuffer);
  static final _$revoke =
      $grpc.ClientMethod<$0.RevokeRequest, $0.RevokeResponse>(
          '/idb.CompanionService/revoke',
          ($0.RevokeRequest value) => value.writeToBuffer(),
          $0.RevokeResponse.fromBuffer);
  static final _$clear_keychain =
      $grpc.ClientMethod<$0.ClearKeychainRequest, $0.ClearKeychainResponse>(
          '/idb.CompanionService/clear_keychain',
          ($0.ClearKeychainRequest value) => value.writeToBuffer(),
          $0.ClearKeychainResponse.fromBuffer);
  static final _$contacts_update =
      $grpc.ClientMethod<$0.ContactsUpdateRequest, $0.ContactsUpdateResponse>(
          '/idb.CompanionService/contacts_update',
          ($0.ContactsUpdateRequest value) => value.writeToBuffer(),
          $0.ContactsUpdateResponse.fromBuffer);
  static final _$contacts_clear =
      $grpc.ClientMethod<$0.ContactsClearRequest, $0.ContactsClearResponse>(
          '/idb.CompanionService/contacts_clear',
          ($0.ContactsClearRequest value) => value.writeToBuffer(),
          $0.ContactsClearResponse.fromBuffer);
  static final _$photos_clear =
      $grpc.ClientMethod<$0.PhotosClearRequest, $0.PhotosClearResponse>(
          '/idb.CompanionService/photos_clear',
          ($0.PhotosClearRequest value) => value.writeToBuffer(),
          $0.PhotosClearResponse.fromBuffer);
  static final _$setting =
      $grpc.ClientMethod<$0.SettingRequest, $0.SettingResponse>(
          '/idb.CompanionService/setting',
          ($0.SettingRequest value) => value.writeToBuffer(),
          $0.SettingResponse.fromBuffer);
  static final _$get_setting =
      $grpc.ClientMethod<$0.GetSettingRequest, $0.GetSettingResponse>(
          '/idb.CompanionService/get_setting',
          ($0.GetSettingRequest value) => value.writeToBuffer(),
          $0.GetSettingResponse.fromBuffer);
  static final _$list_settings =
      $grpc.ClientMethod<$0.ListSettingRequest, $0.ListSettingResponse>(
          '/idb.CompanionService/list_settings',
          ($0.ListSettingRequest value) => value.writeToBuffer(),
          $0.ListSettingResponse.fromBuffer);
  static final _$launch =
      $grpc.ClientMethod<$0.LaunchRequest, $0.LaunchResponse>(
          '/idb.CompanionService/launch',
          ($0.LaunchRequest value) => value.writeToBuffer(),
          $0.LaunchResponse.fromBuffer);
  static final _$list_apps =
      $grpc.ClientMethod<$0.ListAppsRequest, $0.ListAppsResponse>(
          '/idb.CompanionService/list_apps',
          ($0.ListAppsRequest value) => value.writeToBuffer(),
          $0.ListAppsResponse.fromBuffer);
  static final _$terminate =
      $grpc.ClientMethod<$0.TerminateRequest, $0.TerminateResponse>(
          '/idb.CompanionService/terminate',
          ($0.TerminateRequest value) => value.writeToBuffer(),
          $0.TerminateResponse.fromBuffer);
  static final _$uninstall =
      $grpc.ClientMethod<$0.UninstallRequest, $0.UninstallResponse>(
          '/idb.CompanionService/uninstall',
          ($0.UninstallRequest value) => value.writeToBuffer(),
          $0.UninstallResponse.fromBuffer);
  static final _$add_media =
      $grpc.ClientMethod<$0.AddMediaRequest, $0.AddMediaResponse>(
          '/idb.CompanionService/add_media',
          ($0.AddMediaRequest value) => value.writeToBuffer(),
          $0.AddMediaResponse.fromBuffer);
  static final _$record =
      $grpc.ClientMethod<$0.RecordRequest, $0.RecordResponse>(
          '/idb.CompanionService/record',
          ($0.RecordRequest value) => value.writeToBuffer(),
          $0.RecordResponse.fromBuffer);
  static final _$screenshot =
      $grpc.ClientMethod<$0.ScreenshotRequest, $0.ScreenshotResponse>(
          '/idb.CompanionService/screenshot',
          ($0.ScreenshotRequest value) => value.writeToBuffer(),
          $0.ScreenshotResponse.fromBuffer);
  static final _$video_stream =
      $grpc.ClientMethod<$0.VideoStreamRequest, $0.VideoStreamResponse>(
          '/idb.CompanionService/video_stream',
          ($0.VideoStreamRequest value) => value.writeToBuffer(),
          $0.VideoStreamResponse.fromBuffer);
  static final _$crash_delete =
      $grpc.ClientMethod<$0.CrashLogQuery, $0.CrashLogResponse>(
          '/idb.CompanionService/crash_delete',
          ($0.CrashLogQuery value) => value.writeToBuffer(),
          $0.CrashLogResponse.fromBuffer);
  static final _$crash_list =
      $grpc.ClientMethod<$0.CrashLogQuery, $0.CrashLogResponse>(
          '/idb.CompanionService/crash_list',
          ($0.CrashLogQuery value) => value.writeToBuffer(),
          $0.CrashLogResponse.fromBuffer);
  static final _$crash_show =
      $grpc.ClientMethod<$0.CrashShowRequest, $0.CrashShowResponse>(
          '/idb.CompanionService/crash_show',
          ($0.CrashShowRequest value) => value.writeToBuffer(),
          $0.CrashShowResponse.fromBuffer);
  static final _$xctest_list_bundles = $grpc.ClientMethod<
          $0.XctestListBundlesRequest, $0.XctestListBundlesResponse>(
      '/idb.CompanionService/xctest_list_bundles',
      ($0.XctestListBundlesRequest value) => value.writeToBuffer(),
      $0.XctestListBundlesResponse.fromBuffer);
  static final _$xctest_list_tests =
      $grpc.ClientMethod<$0.XctestListTestsRequest, $0.XctestListTestsResponse>(
          '/idb.CompanionService/xctest_list_tests',
          ($0.XctestListTestsRequest value) => value.writeToBuffer(),
          $0.XctestListTestsResponse.fromBuffer);
  static final _$xctest_run =
      $grpc.ClientMethod<$0.XctestRunRequest, $0.XctestRunResponse>(
          '/idb.CompanionService/xctest_run',
          ($0.XctestRunRequest value) => value.writeToBuffer(),
          $0.XctestRunResponse.fromBuffer);
  static final _$repl = $grpc.ClientMethod<$0.ReplRequest, $0.ReplResponse>(
      '/idb.CompanionService/repl',
      ($0.ReplRequest value) => value.writeToBuffer(),
      $0.ReplResponse.fromBuffer);
  static final _$ls = $grpc.ClientMethod<$0.LsRequest, $0.LsResponse>(
      '/idb.CompanionService/ls',
      ($0.LsRequest value) => value.writeToBuffer(),
      $0.LsResponse.fromBuffer);
  static final _$mkdir = $grpc.ClientMethod<$0.MkdirRequest, $0.MkdirResponse>(
      '/idb.CompanionService/mkdir',
      ($0.MkdirRequest value) => value.writeToBuffer(),
      $0.MkdirResponse.fromBuffer);
  static final _$mv = $grpc.ClientMethod<$0.MvRequest, $0.MvResponse>(
      '/idb.CompanionService/mv',
      ($0.MvRequest value) => value.writeToBuffer(),
      $0.MvResponse.fromBuffer);
  static final _$rm = $grpc.ClientMethod<$0.RmRequest, $0.RmResponse>(
      '/idb.CompanionService/rm',
      ($0.RmRequest value) => value.writeToBuffer(),
      $0.RmResponse.fromBuffer);
  static final _$pull = $grpc.ClientMethod<$0.PullRequest, $0.PullResponse>(
      '/idb.CompanionService/pull',
      ($0.PullRequest value) => value.writeToBuffer(),
      $0.PullResponse.fromBuffer);
  static final _$push = $grpc.ClientMethod<$0.PushRequest, $0.PushResponse>(
      '/idb.CompanionService/push',
      ($0.PushRequest value) => value.writeToBuffer(),
      $0.PushResponse.fromBuffer);
  static final _$tail = $grpc.ClientMethod<$0.TailRequest, $0.TailResponse>(
      '/idb.CompanionService/tail',
      ($0.TailRequest value) => value.writeToBuffer(),
      $0.TailResponse.fromBuffer);
}

@$pb.GrpcServiceName('idb.CompanionService')
abstract class CompanionServiceBase extends $grpc.Service {
  $core.String get $name => 'idb.CompanionService';

  CompanionServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.ConnectRequest, $0.ConnectResponse>(
        'connect',
        connect_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ConnectRequest.fromBuffer(value),
        ($0.ConnectResponse value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.DebugServerRequest, $0.DebugServerResponse>(
            'debugserver',
            debugserver,
            true,
            true,
            ($core.List<$core.int> value) =>
                $0.DebugServerRequest.fromBuffer(value),
            ($0.DebugServerResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.DapRequest, $0.DapResponse>(
        'dap',
        dap,
        true,
        true,
        ($core.List<$core.int> value) => $0.DapRequest.fromBuffer(value),
        ($0.DapResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.TargetDescriptionRequest,
            $0.TargetDescriptionResponse>(
        'describe',
        describe_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.TargetDescriptionRequest.fromBuffer(value),
        ($0.TargetDescriptionResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.InstallRequest, $0.InstallResponse>(
        'install',
        install,
        true,
        true,
        ($core.List<$core.int> value) => $0.InstallRequest.fromBuffer(value),
        ($0.InstallResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.InstrumentsRunRequest,
            $0.InstrumentsRunResponse>(
        'instruments_run',
        instruments_run,
        true,
        true,
        ($core.List<$core.int> value) =>
            $0.InstrumentsRunRequest.fromBuffer(value),
        ($0.InstrumentsRunResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.LogRequest, $0.LogResponse>(
        'log',
        log_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $0.LogRequest.fromBuffer(value),
        ($0.LogResponse value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.XctraceRecordRequest, $0.XctraceRecordResponse>(
            'xctrace_record',
            xctrace_record,
            true,
            true,
            ($core.List<$core.int> value) =>
                $0.XctraceRecordRequest.fromBuffer(value),
            ($0.XctraceRecordResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.AccessibilityInfoRequest,
            $0.AccessibilityInfoResponse>(
        'accessibility_info',
        accessibility_info_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.AccessibilityInfoRequest.fromBuffer(value),
        ($0.AccessibilityInfoResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.AccessibilityActionRequest,
            $0.AccessibilityActionResponse>(
        'accessibility_action',
        accessibility_action_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.AccessibilityActionRequest.fromBuffer(value),
        ($0.AccessibilityActionResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.FocusRequest, $0.FocusResponse>(
        'focus',
        focus_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.FocusRequest.fromBuffer(value),
        ($0.FocusResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.HIDEvent, $0.HIDResponse>(
        'hid',
        hid,
        true,
        false,
        ($core.List<$core.int> value) => $0.HIDEvent.fromBuffer(value),
        ($0.HIDResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.OpenUrlRequest, $0.OpenUrlRequest>(
        'open_url',
        open_url_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.OpenUrlRequest.fromBuffer(value),
        ($0.OpenUrlRequest value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.SetLocationRequest, $0.SetLocationResponse>(
            'set_location',
            set_location_Pre,
            false,
            false,
            ($core.List<$core.int> value) =>
                $0.SetLocationRequest.fromBuffer(value),
            ($0.SetLocationResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.SendNotificationRequest,
            $0.SendNotificationResponse>(
        'send_notification',
        send_notification_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.SendNotificationRequest.fromBuffer(value),
        ($0.SendNotificationResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.SimulateMemoryWarningRequest,
            $0.SimulateMemoryWarningResponse>(
        'simulate_memory_warning',
        simulate_memory_warning_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.SimulateMemoryWarningRequest.fromBuffer(value),
        ($0.SimulateMemoryWarningResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ApproveRequest, $0.ApproveResponse>(
        'approve',
        approve_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ApproveRequest.fromBuffer(value),
        ($0.ApproveResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.RevokeRequest, $0.RevokeResponse>(
        'revoke',
        revoke_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.RevokeRequest.fromBuffer(value),
        ($0.RevokeResponse value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.ClearKeychainRequest, $0.ClearKeychainResponse>(
            'clear_keychain',
            clear_keychain_Pre,
            false,
            false,
            ($core.List<$core.int> value) =>
                $0.ClearKeychainRequest.fromBuffer(value),
            ($0.ClearKeychainResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ContactsUpdateRequest,
            $0.ContactsUpdateResponse>(
        'contacts_update',
        contacts_update_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.ContactsUpdateRequest.fromBuffer(value),
        ($0.ContactsUpdateResponse value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.ContactsClearRequest, $0.ContactsClearResponse>(
            'contacts_clear',
            contacts_clear_Pre,
            false,
            false,
            ($core.List<$core.int> value) =>
                $0.ContactsClearRequest.fromBuffer(value),
            ($0.ContactsClearResponse value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.PhotosClearRequest, $0.PhotosClearResponse>(
            'photos_clear',
            photos_clear_Pre,
            false,
            false,
            ($core.List<$core.int> value) =>
                $0.PhotosClearRequest.fromBuffer(value),
            ($0.PhotosClearResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.SettingRequest, $0.SettingResponse>(
        'setting',
        setting_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.SettingRequest.fromBuffer(value),
        ($0.SettingResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.GetSettingRequest, $0.GetSettingResponse>(
        'get_setting',
        get_setting_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.GetSettingRequest.fromBuffer(value),
        ($0.GetSettingResponse value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.ListSettingRequest, $0.ListSettingResponse>(
            'list_settings',
            list_settings_Pre,
            false,
            false,
            ($core.List<$core.int> value) =>
                $0.ListSettingRequest.fromBuffer(value),
            ($0.ListSettingResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.LaunchRequest, $0.LaunchResponse>(
        'launch',
        launch,
        true,
        true,
        ($core.List<$core.int> value) => $0.LaunchRequest.fromBuffer(value),
        ($0.LaunchResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ListAppsRequest, $0.ListAppsResponse>(
        'list_apps',
        list_apps_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ListAppsRequest.fromBuffer(value),
        ($0.ListAppsResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.TerminateRequest, $0.TerminateResponse>(
        'terminate',
        terminate_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.TerminateRequest.fromBuffer(value),
        ($0.TerminateResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.UninstallRequest, $0.UninstallResponse>(
        'uninstall',
        uninstall_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.UninstallRequest.fromBuffer(value),
        ($0.UninstallResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.AddMediaRequest, $0.AddMediaResponse>(
        'add_media',
        add_media,
        true,
        false,
        ($core.List<$core.int> value) => $0.AddMediaRequest.fromBuffer(value),
        ($0.AddMediaResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.RecordRequest, $0.RecordResponse>(
        'record',
        record,
        true,
        true,
        ($core.List<$core.int> value) => $0.RecordRequest.fromBuffer(value),
        ($0.RecordResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ScreenshotRequest, $0.ScreenshotResponse>(
        'screenshot',
        screenshot_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ScreenshotRequest.fromBuffer(value),
        ($0.ScreenshotResponse value) => value.writeToBuffer()));
    $addMethod(
        $grpc.ServiceMethod<$0.VideoStreamRequest, $0.VideoStreamResponse>(
            'video_stream',
            video_stream,
            true,
            true,
            ($core.List<$core.int> value) =>
                $0.VideoStreamRequest.fromBuffer(value),
            ($0.VideoStreamResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.CrashLogQuery, $0.CrashLogResponse>(
        'crash_delete',
        crash_delete_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.CrashLogQuery.fromBuffer(value),
        ($0.CrashLogResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.CrashLogQuery, $0.CrashLogResponse>(
        'crash_list',
        crash_list_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.CrashLogQuery.fromBuffer(value),
        ($0.CrashLogResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.CrashShowRequest, $0.CrashShowResponse>(
        'crash_show',
        crash_show_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.CrashShowRequest.fromBuffer(value),
        ($0.CrashShowResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.XctestListBundlesRequest,
            $0.XctestListBundlesResponse>(
        'xctest_list_bundles',
        xctest_list_bundles_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.XctestListBundlesRequest.fromBuffer(value),
        ($0.XctestListBundlesResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.XctestListTestsRequest,
            $0.XctestListTestsResponse>(
        'xctest_list_tests',
        xctest_list_tests_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.XctestListTestsRequest.fromBuffer(value),
        ($0.XctestListTestsResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.XctestRunRequest, $0.XctestRunResponse>(
        'xctest_run',
        xctest_run_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $0.XctestRunRequest.fromBuffer(value),
        ($0.XctestRunResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ReplRequest, $0.ReplResponse>(
        'repl',
        repl,
        true,
        true,
        ($core.List<$core.int> value) => $0.ReplRequest.fromBuffer(value),
        ($0.ReplResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.LsRequest, $0.LsResponse>(
        'ls',
        ls_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.LsRequest.fromBuffer(value),
        ($0.LsResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.MkdirRequest, $0.MkdirResponse>(
        'mkdir',
        mkdir_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.MkdirRequest.fromBuffer(value),
        ($0.MkdirResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.MvRequest, $0.MvResponse>(
        'mv',
        mv_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.MvRequest.fromBuffer(value),
        ($0.MvResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.RmRequest, $0.RmResponse>(
        'rm',
        rm_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.RmRequest.fromBuffer(value),
        ($0.RmResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.PullRequest, $0.PullResponse>(
        'pull',
        pull_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $0.PullRequest.fromBuffer(value),
        ($0.PullResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.PushRequest, $0.PushResponse>(
        'push',
        push,
        true,
        false,
        ($core.List<$core.int> value) => $0.PushRequest.fromBuffer(value),
        ($0.PushResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.TailRequest, $0.TailResponse>(
        'tail',
        tail,
        true,
        true,
        ($core.List<$core.int> value) => $0.TailRequest.fromBuffer(value),
        ($0.TailResponse value) => value.writeToBuffer()));
  }

  $async.Future<$0.ConnectResponse> connect_Pre($grpc.ServiceCall $call,
      $async.Future<$0.ConnectRequest> $request) async {
    return connect($call, await $request);
  }

  $async.Future<$0.ConnectResponse> connect(
      $grpc.ServiceCall call, $0.ConnectRequest request);

  $async.Stream<$0.DebugServerResponse> debugserver(
      $grpc.ServiceCall call, $async.Stream<$0.DebugServerRequest> request);

  $async.Stream<$0.DapResponse> dap(
      $grpc.ServiceCall call, $async.Stream<$0.DapRequest> request);

  $async.Future<$0.TargetDescriptionResponse> describe_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.TargetDescriptionRequest> $request) async {
    return describe($call, await $request);
  }

  $async.Future<$0.TargetDescriptionResponse> describe(
      $grpc.ServiceCall call, $0.TargetDescriptionRequest request);

  $async.Stream<$0.InstallResponse> install(
      $grpc.ServiceCall call, $async.Stream<$0.InstallRequest> request);

  $async.Stream<$0.InstrumentsRunResponse> instruments_run(
      $grpc.ServiceCall call, $async.Stream<$0.InstrumentsRunRequest> request);

  $async.Stream<$0.LogResponse> log_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.LogRequest> $request) async* {
    yield* log($call, await $request);
  }

  $async.Stream<$0.LogResponse> log(
      $grpc.ServiceCall call, $0.LogRequest request);

  $async.Stream<$0.XctraceRecordResponse> xctrace_record(
      $grpc.ServiceCall call, $async.Stream<$0.XctraceRecordRequest> request);

  $async.Future<$0.AccessibilityInfoResponse> accessibility_info_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.AccessibilityInfoRequest> $request) async {
    return accessibility_info($call, await $request);
  }

  $async.Future<$0.AccessibilityInfoResponse> accessibility_info(
      $grpc.ServiceCall call, $0.AccessibilityInfoRequest request);

  $async.Future<$0.AccessibilityActionResponse> accessibility_action_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.AccessibilityActionRequest> $request) async {
    return accessibility_action($call, await $request);
  }

  $async.Future<$0.AccessibilityActionResponse> accessibility_action(
      $grpc.ServiceCall call, $0.AccessibilityActionRequest request);

  $async.Future<$0.FocusResponse> focus_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.FocusRequest> $request) async {
    return focus($call, await $request);
  }

  $async.Future<$0.FocusResponse> focus(
      $grpc.ServiceCall call, $0.FocusRequest request);

  $async.Future<$0.HIDResponse> hid(
      $grpc.ServiceCall call, $async.Stream<$0.HIDEvent> request);

  $async.Future<$0.OpenUrlRequest> open_url_Pre($grpc.ServiceCall $call,
      $async.Future<$0.OpenUrlRequest> $request) async {
    return open_url($call, await $request);
  }

  $async.Future<$0.OpenUrlRequest> open_url(
      $grpc.ServiceCall call, $0.OpenUrlRequest request);

  $async.Future<$0.SetLocationResponse> set_location_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.SetLocationRequest> $request) async {
    return set_location($call, await $request);
  }

  $async.Future<$0.SetLocationResponse> set_location(
      $grpc.ServiceCall call, $0.SetLocationRequest request);

  $async.Future<$0.SendNotificationResponse> send_notification_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.SendNotificationRequest> $request) async {
    return send_notification($call, await $request);
  }

  $async.Future<$0.SendNotificationResponse> send_notification(
      $grpc.ServiceCall call, $0.SendNotificationRequest request);

  $async.Future<$0.SimulateMemoryWarningResponse> simulate_memory_warning_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.SimulateMemoryWarningRequest> $request) async {
    return simulate_memory_warning($call, await $request);
  }

  $async.Future<$0.SimulateMemoryWarningResponse> simulate_memory_warning(
      $grpc.ServiceCall call, $0.SimulateMemoryWarningRequest request);

  $async.Future<$0.ApproveResponse> approve_Pre($grpc.ServiceCall $call,
      $async.Future<$0.ApproveRequest> $request) async {
    return approve($call, await $request);
  }

  $async.Future<$0.ApproveResponse> approve(
      $grpc.ServiceCall call, $0.ApproveRequest request);

  $async.Future<$0.RevokeResponse> revoke_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.RevokeRequest> $request) async {
    return revoke($call, await $request);
  }

  $async.Future<$0.RevokeResponse> revoke(
      $grpc.ServiceCall call, $0.RevokeRequest request);

  $async.Future<$0.ClearKeychainResponse> clear_keychain_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.ClearKeychainRequest> $request) async {
    return clear_keychain($call, await $request);
  }

  $async.Future<$0.ClearKeychainResponse> clear_keychain(
      $grpc.ServiceCall call, $0.ClearKeychainRequest request);

  $async.Future<$0.ContactsUpdateResponse> contacts_update_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.ContactsUpdateRequest> $request) async {
    return contacts_update($call, await $request);
  }

  $async.Future<$0.ContactsUpdateResponse> contacts_update(
      $grpc.ServiceCall call, $0.ContactsUpdateRequest request);

  $async.Future<$0.ContactsClearResponse> contacts_clear_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.ContactsClearRequest> $request) async {
    return contacts_clear($call, await $request);
  }

  $async.Future<$0.ContactsClearResponse> contacts_clear(
      $grpc.ServiceCall call, $0.ContactsClearRequest request);

  $async.Future<$0.PhotosClearResponse> photos_clear_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.PhotosClearRequest> $request) async {
    return photos_clear($call, await $request);
  }

  $async.Future<$0.PhotosClearResponse> photos_clear(
      $grpc.ServiceCall call, $0.PhotosClearRequest request);

  $async.Future<$0.SettingResponse> setting_Pre($grpc.ServiceCall $call,
      $async.Future<$0.SettingRequest> $request) async {
    return setting($call, await $request);
  }

  $async.Future<$0.SettingResponse> setting(
      $grpc.ServiceCall call, $0.SettingRequest request);

  $async.Future<$0.GetSettingResponse> get_setting_Pre($grpc.ServiceCall $call,
      $async.Future<$0.GetSettingRequest> $request) async {
    return get_setting($call, await $request);
  }

  $async.Future<$0.GetSettingResponse> get_setting(
      $grpc.ServiceCall call, $0.GetSettingRequest request);

  $async.Future<$0.ListSettingResponse> list_settings_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.ListSettingRequest> $request) async {
    return list_settings($call, await $request);
  }

  $async.Future<$0.ListSettingResponse> list_settings(
      $grpc.ServiceCall call, $0.ListSettingRequest request);

  $async.Stream<$0.LaunchResponse> launch(
      $grpc.ServiceCall call, $async.Stream<$0.LaunchRequest> request);

  $async.Future<$0.ListAppsResponse> list_apps_Pre($grpc.ServiceCall $call,
      $async.Future<$0.ListAppsRequest> $request) async {
    return list_apps($call, await $request);
  }

  $async.Future<$0.ListAppsResponse> list_apps(
      $grpc.ServiceCall call, $0.ListAppsRequest request);

  $async.Future<$0.TerminateResponse> terminate_Pre($grpc.ServiceCall $call,
      $async.Future<$0.TerminateRequest> $request) async {
    return terminate($call, await $request);
  }

  $async.Future<$0.TerminateResponse> terminate(
      $grpc.ServiceCall call, $0.TerminateRequest request);

  $async.Future<$0.UninstallResponse> uninstall_Pre($grpc.ServiceCall $call,
      $async.Future<$0.UninstallRequest> $request) async {
    return uninstall($call, await $request);
  }

  $async.Future<$0.UninstallResponse> uninstall(
      $grpc.ServiceCall call, $0.UninstallRequest request);

  $async.Future<$0.AddMediaResponse> add_media(
      $grpc.ServiceCall call, $async.Stream<$0.AddMediaRequest> request);

  $async.Stream<$0.RecordResponse> record(
      $grpc.ServiceCall call, $async.Stream<$0.RecordRequest> request);

  $async.Future<$0.ScreenshotResponse> screenshot_Pre($grpc.ServiceCall $call,
      $async.Future<$0.ScreenshotRequest> $request) async {
    return screenshot($call, await $request);
  }

  $async.Future<$0.ScreenshotResponse> screenshot(
      $grpc.ServiceCall call, $0.ScreenshotRequest request);

  $async.Stream<$0.VideoStreamResponse> video_stream(
      $grpc.ServiceCall call, $async.Stream<$0.VideoStreamRequest> request);

  $async.Future<$0.CrashLogResponse> crash_delete_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.CrashLogQuery> $request) async {
    return crash_delete($call, await $request);
  }

  $async.Future<$0.CrashLogResponse> crash_delete(
      $grpc.ServiceCall call, $0.CrashLogQuery request);

  $async.Future<$0.CrashLogResponse> crash_list_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.CrashLogQuery> $request) async {
    return crash_list($call, await $request);
  }

  $async.Future<$0.CrashLogResponse> crash_list(
      $grpc.ServiceCall call, $0.CrashLogQuery request);

  $async.Future<$0.CrashShowResponse> crash_show_Pre($grpc.ServiceCall $call,
      $async.Future<$0.CrashShowRequest> $request) async {
    return crash_show($call, await $request);
  }

  $async.Future<$0.CrashShowResponse> crash_show(
      $grpc.ServiceCall call, $0.CrashShowRequest request);

  $async.Future<$0.XctestListBundlesResponse> xctest_list_bundles_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.XctestListBundlesRequest> $request) async {
    return xctest_list_bundles($call, await $request);
  }

  $async.Future<$0.XctestListBundlesResponse> xctest_list_bundles(
      $grpc.ServiceCall call, $0.XctestListBundlesRequest request);

  $async.Future<$0.XctestListTestsResponse> xctest_list_tests_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.XctestListTestsRequest> $request) async {
    return xctest_list_tests($call, await $request);
  }

  $async.Future<$0.XctestListTestsResponse> xctest_list_tests(
      $grpc.ServiceCall call, $0.XctestListTestsRequest request);

  $async.Stream<$0.XctestRunResponse> xctest_run_Pre($grpc.ServiceCall $call,
      $async.Future<$0.XctestRunRequest> $request) async* {
    yield* xctest_run($call, await $request);
  }

  $async.Stream<$0.XctestRunResponse> xctest_run(
      $grpc.ServiceCall call, $0.XctestRunRequest request);

  $async.Stream<$0.ReplResponse> repl(
      $grpc.ServiceCall call, $async.Stream<$0.ReplRequest> request);

  $async.Future<$0.LsResponse> ls_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.LsRequest> $request) async {
    return ls($call, await $request);
  }

  $async.Future<$0.LsResponse> ls($grpc.ServiceCall call, $0.LsRequest request);

  $async.Future<$0.MkdirResponse> mkdir_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.MkdirRequest> $request) async {
    return mkdir($call, await $request);
  }

  $async.Future<$0.MkdirResponse> mkdir(
      $grpc.ServiceCall call, $0.MkdirRequest request);

  $async.Future<$0.MvResponse> mv_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.MvRequest> $request) async {
    return mv($call, await $request);
  }

  $async.Future<$0.MvResponse> mv($grpc.ServiceCall call, $0.MvRequest request);

  $async.Future<$0.RmResponse> rm_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.RmRequest> $request) async {
    return rm($call, await $request);
  }

  $async.Future<$0.RmResponse> rm($grpc.ServiceCall call, $0.RmRequest request);

  $async.Stream<$0.PullResponse> pull_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.PullRequest> $request) async* {
    yield* pull($call, await $request);
  }

  $async.Stream<$0.PullResponse> pull(
      $grpc.ServiceCall call, $0.PullRequest request);

  $async.Future<$0.PushResponse> push(
      $grpc.ServiceCall call, $async.Stream<$0.PushRequest> request);

  $async.Stream<$0.TailResponse> tail(
      $grpc.ServiceCall call, $async.Stream<$0.TailRequest> request);
}
