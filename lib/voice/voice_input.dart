/// 這一次聽的方式
class ListenOptions {
  /// 講完停頓幾秒就收音（null = 用平台預設 1.5 秒）
  final double? endSilenceSeconds;

  /// 一直沒開口幾秒就收音（null = 用平台預設 8 秒）
  final int? idleSeconds;

  /// false = 不會因為安靜自動結束（AI 講話時邊聽邊找插話關鍵字用），
  /// 由 [VoiceInput.armAutoStop] 或 [VoiceInput.cancel] 結束
  final bool autoStop;

  const ListenOptions({this.endSilenceSeconds, this.idleSeconds, this.autoStop = true});

  Map<String, dynamic> toMap() => {
        if (endSilenceSeconds != null) 'endSilence': endSilenceSeconds,
        if (idleSeconds != null) 'idleTimeout': idleSeconds,
        'autoStop': autoStop,
      };
}

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
  Future<void> startRecording({ListenOptions options = const ListenOptions()});

  /// 馬上停止並丟掉這次聽到的內容（[awaitResult] 回 null），不等辨識結果
  Future<void> cancel();

  /// 原本不會自動結束的這次聽（autoStop=false）改成「講完停頓 [endSilenceSeconds] 秒就收音」。
  /// 插話關鍵字出現後呼叫：接著聽使用者把話講完。
  Future<void> armAutoStop(double endSilenceSeconds);

  /// 只通知停止錄音，結果由 [awaitResult] 取得
  Future<void> stopListening();

  /// 等待這次辨識結果：使用者停頓後會自動結束，或呼叫 [stopListening]
  Future<String?> awaitResult();

  /// 停止錄音並等待辨識結果（按住說話用）
  Future<String?> stopAndTranscribe();

  Future<String?> recordOnce({Duration maxDuration = const Duration(seconds: 15)});
  Future<void> dispose();
}
