import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'voice_input.dart';

class MobileVoiceInput implements VoiceInput {
  static const _channel = MethodChannel('curtain_mcp/stt');

  final String language;
  bool _ready = false;
  String? _lastError;

  // ✅ 關鍵修復：保存 startListening 的 Future
  Future<String?>? _listeningFuture;

  MobileVoiceInput({
    required this.language,
    String? sttMode,
    String? sttBackendUrl,
  }) {
    // 原生端邊說邊送回目前辨識到的文字
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLevel') {
        onLevel?.call((call.arguments as num?)?.toDouble() ?? 0);
        return;
      }
      if (call.method == 'onPartial') {
        final text = call.arguments as String?;
        if (text != null && text.isNotEmpty) onPartial?.call(text);
      }
    });
  }

  @override
  void Function(String text)? onPartial;

  @override
  void Function(double level)? onLevel;

  @override
  bool get isReady => _ready;

  @override
  String? get lastError => _lastError;

  @override
  Future<void> initialize() async {
    // Step 1：麥克風權限。iOS 由原生端的 isAvailable 一併申請（語音辨識 + 麥克風），
    // permission_handler 在 iOS 沒設定 PERMISSION_MICROPHONE 巨集時永遠回傳未授權
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      var status = await Permission.microphone.status;
      if (!status.isGranted) {
        status = await Permission.microphone.request();
      }
      if (!status.isGranted) {
        throw Exception('麥克風權限未開啟，語音功能無法使用');
      }
    }

    // Step 2：確認裝置支援 STT（iOS 在這裡跳出權限詢問）
    // iOS 沒給權限時原生端回 false，給明確的說法
    final available =
        await _channel.invokeMethod<bool>('isAvailable') ?? false;
    if (!available) {
      throw Exception(defaultTargetPlatform == TargetPlatform.iOS
          ? '語音辨識或麥克風權限未開啟，請到「設定」開啟'
          : '此裝置不支援語音辨識');
    }

    _ready = true;
  }

  /// 開始錄音，保存 Future 等待辨識結果
  @override
  Future<void> startRecording({ListenOptions options = const ListenOptions()}) async {
    if (!_ready) return;

    // ✅ 修復重點：用變數保存 Future，不能丟棄
    _lastError = null;
    _listeningFuture = _channel
        .invokeMethod<String>('startListening', options.toMap())
        .then((v) => v)
        .catchError((e) {
      if (e is PlatformException) {
        _lastError = e.message;
        return null;
      }
      throw e;
    });
  }

  /// 停止錄音，等待辨識結果
  @override
  Future<String?> stopAndTranscribe() async {
    try {
      // ✅ Step 1：通知 Android 停止錄音（讓它送出剩餘音訊給 STT）
      await _channel.invokeMethod<void>('stopListening');

      // ✅ Step 2：等待 startListening 回傳真正的辨識結果
      final result = await _listeningFuture;
      _listeningFuture = null;

      if (result == null || result.trim().isEmpty) return null;
      return result.trim();

    } on PlatformException catch (e) {
      _listeningFuture = null;
      if (e.code == 'STT_ERROR') return null;
      rethrow;
    }
  }

  /// 只通知停止錄音，結果由 [awaitResult] 取得
  @override
  Future<void> stopListening() async {
    try {
      await _channel.invokeMethod<void>('stopListening');
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancelListening');
    } catch (_) {
      // 舊版原生端沒有 cancelListening：退回一般停止
      await stopListening();
    }
  }

  @override
  Future<void> armAutoStop(double endSilenceSeconds) async {
    try {
      await _channel.invokeMethod<void>(
          'armAutoStop', {'endSilence': endSilenceSeconds});
    } catch (_) {}
  }

  /// 等待這次辨識結果：使用者停頓後系統會自動結束，或呼叫 [stopListening]
  @override
  Future<String?> awaitResult() async {
    try {
      final result = await _listeningFuture;
      return (result == null || result.trim().isEmpty) ? null : result.trim();
    } on PlatformException {
      return null;
    } finally {
      _listeningFuture = null;
    }
  }

  @override
  Future<String?> recordOnce({
    Duration maxDuration = const Duration(seconds: 15),
  }) async {
    if (!_ready) return null;
    try {
      final result = await _channel
          .invokeMethod<String>('startListening')
          .timeout(maxDuration, onTimeout: () => null);
      return result;
    } on PlatformException catch (e) {
      if (e.code == 'STT_ERROR') return null;
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    _listeningFuture = null;
    try {
      await _channel.invokeMethod<void>('stopListening');
    } catch (_) {}
  }
}