import 'dart:typed_data';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The browser the server drives over CDP (slice 3d), asked for. Every
/// answer comes when the browser has done it; a refusal ([DataRefused])
/// carries the browser taxonomy's own words.
class BrowserData {
  BrowserData(this._client);

  final DataClient _client;

  Future<R> _ask<R>(BrowserWorkRequest<R> request) async =>
      (await _client.send(request)).value;

  /// The browser as the server last told it.
  BrowserState get state => _client.browserState ?? const BrowserState();

  /// The browser moving, whoever moved it.
  Stream<BrowserState> get changes => _client.runsChanges
      .where((change) => change is BrowserStateChanged)
      .map((change) => (change as BrowserStateChanged).state);

  Future<BrowserState> refresh() => _ask(const BrowserStateGet());

  Future<BrowserState> connect({bool spawn = true, String? url}) =>
      _ask(BrowserConnect(spawn: spawn, url: url));

  Future<BrowserState> disconnect() => _ask(const BrowserDisconnect());

  Future<BrowserState> navigate(String url) => _ask(BrowserNavigate(url));

  Future<BrowserState> tabs() => _ask(const BrowserTabs());

  Future<BrowserState> selectTab(String targetId) =>
      _ask(BrowserSelectTab(targetId));

  Future<Uint8List> screenshot() => _ask(const BrowserScreenshot());

  Future<BrowserPick> pick() => _ask(const BrowserPickElement());

  Future<void> cancelPick() => _ask(const BrowserCancelPick());

  Future<String> evaluate(String expression) =>
      _ask(BrowserEvaluate(expression));

  Future<String> find({String? selector, String? text, int limit = 10}) =>
      _ask(BrowserFind(selector: selector, text: text, limit: limit));
}

final browserDataProvider = Provider<BrowserData>(
  (ref) => BrowserData(ref.watch(dataClientProvider)),
);
