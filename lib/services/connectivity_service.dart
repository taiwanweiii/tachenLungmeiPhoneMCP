import 'dart:async';
import 'package:flutter/foundation.dart';
import 'ollama_service.dart';
import '../core/config/app_config.dart';

enum ConnectionStatus { unknown, checking, connected, disconnected }

/// 定期 ping Ollama，廣播連線狀態
class ConnectivityService extends ChangeNotifier {
  final OllamaService _ollama;
  final AppConfig     _config;

  ConnectionStatus _status = ConnectionStatus.unknown;
  Timer?           _timer;
  bool             _disposed = false;

  ConnectivityService(this._ollama, this._config) {
    _config.addListener(_onEndpointChanged);
  }

  ConnectionStatus get status => _status;

  bool get isConnected => _status == ConnectionStatus.connected;

  // ── 啟動 / 停止 ───────────────────────────────────────

  void start() {
    if (_timer != null) return; // 已經在跑
    _checkNow();
    _timer = Timer.periodic(
      const Duration(seconds: 30),
          (_) => _checkNow(),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 手動觸發立即檢查（不回傳結果，供外部呼叫）
  Future<void> checkNow() => _checkNow();

  /// 手動觸發並回傳是否連線成功（供 SettingsPage 測試連線用）
  Future<bool> checkAndReturn() async {
    if (_disposed) return false;
    _setStatus(ConnectionStatus.checking);
    final ok = await _ollama.isAvailableAsync();
    if (_disposed) return false;
    _setStatus(ok
        ? ConnectionStatus.connected
        : ConnectionStatus.disconnected);
    return ok;
  }

  // ── 內部 ──────────────────────────────────────────────

  void _onEndpointChanged() {
    _setStatus(ConnectionStatus.checking);
    _checkNow();
  }

  Future<void> _checkNow() async {
    if (_disposed) return;
    _setStatus(ConnectionStatus.checking);
    final ok = await _ollama.isAvailableAsync();
    if (_disposed) return;
    _setStatus(ok
        ? ConnectionStatus.connected
        : ConnectionStatus.disconnected);
  }

  void _setStatus(ConnectionStatus s) {
    if (_status == s) return;
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    _config.removeListener(_onEndpointChanged);
    super.dispose();
  }
}