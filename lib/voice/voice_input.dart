/// 語音輸入（語音辨識）介面：Android 用原生 SpeechRecognizer，
/// Web 用瀏覽器的 Web Speech API。由 voice_input_factory.dart 依平台挑選。
abstract class VoiceInput {
  Future<void> initialize();
  bool get isReady;

  /// 邊說邊回傳目前辨識到的文字（說完前可能還會變）
  abstract void Function(String text)? onPartial;

  /// 說話音量 0 ~ 1（錄音中約每 50~100ms 一次），給水波紋動畫用
  abstract void Function(double level)? onLevel;

  /// 最近一次辨識失敗的原因（可直接顯示給使用者），沒有則為 null
  String? get lastError;

  /// 開始錄音；結果用 [awaitResult] 或 [stopAndTranscribe] 取得
  Future<void> startRecording();

  /// 只通知停止錄音，結果由 [awaitResult] 取得
  Future<void> stopListening();

  /// 等待這次辨識結果：使用者停頓後會自動結束，或呼叫 [stopListening]
  Future<String?> awaitResult();

  /// 停止錄音並等待辨識結果（按住說話用）
  Future<String?> stopAndTranscribe();

  Future<String?> recordOnce({Duration maxDuration = const Duration(seconds: 15)});
  Future<void> dispose();
}
