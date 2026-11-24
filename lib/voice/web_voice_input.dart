import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'voice_input.dart';

/// Web 版語音辨識：使用瀏覽器內建的 Web Speech API（SpeechRecognition）。
///
/// - Chrome / Edge 支援，Firefox 不支援
/// - 頁面必須是 localhost 或 https，瀏覽器才會開放麥克風
/// - Chrome 會把聲音送到 Google 辨識，需要能連外網
class WebVoiceInput implements VoiceInput {
  final String language;

  WebVoiceInput({required this.language});

  bool _ready = false;
  String? _lastError;
  _SpeechRecognition? _rec;
  Completer<String?>? _result;
  final StringBuffer _text = StringBuffer();

  @override
  void Function(String text)? onPartial;

  @override
  void Function(double level)? onLevel;

  Timer? _levelTimer;

  void _startLevel() {
    final meter = _voiceLevel;
    if (meter == null) return;
    meter.start();
    _levelTimer?.cancel();
    _levelTimer = Timer.periodic(const Duration(milliseconds: 60),
        (_) => onLevel?.call(meter.level()));
  }

  void _stopLevel() {
    _levelTimer?.cancel();
    _levelTimer = null;
    _voiceLevel?.stop();
    onLevel?.call(0);
  }

  @override
  bool get isReady => _ready;

  @override
  String? get lastError => _lastError;

  static JSFunction? get _ctor {
    final c = globalContext['SpeechRecognition'] ??
        globalContext['webkitSpeechRecognition'];
    return c == null ? null : c as JSFunction;
  }

  @override
  Future<void> initialize() async {
    if (_ctor == null) {
      throw Exception('這個瀏覽器不支援語音辨識，請改用 Chrome 或 Edge');
    }
    _ready = true;
  }

  @override
  Future<void> startRecording() async {
    if (!_ready) return;
    _rec?.abort();
    _lastError = null;
    _text.clear();
    final done = _result = Completer<String?>();

    final rec = _ctor!.callAsConstructor<_SpeechRecognition>();
    rec
      ..lang = language
      ..continuous = false     // 停頓後自動結束，跟 Android 行為一致
      ..interimResults = true  // 邊說邊出字
      ..maxAlternatives = 1;

    rec.onresult = ((_ResultEvent e) {
      final results = e.results;
      _text.clear();
      for (var i = 0; i < results.length; i++) {
        _text.write(results.item(i).item(0).transcript);
      }
      onPartial?.call(_text.toString());
    }).toJS;

    rec.onerror = ((_ErrorEvent e) {
      _lastError = _describe(e.error);
    }).toJS;

    rec.onend = ((JSAny? _) {
      _stopLevel();
      final text = _text.toString().trim();
      if (!done.isCompleted) done.complete(text.isEmpty ? null : text);
      if (identical(_rec, rec)) _rec = null;
    }).toJS;

    _rec = rec;
    try {
      rec.start();
      _startLevel();
    } catch (e) {
      _lastError = '無法啟動語音辨識：$e';
      if (!done.isCompleted) done.complete(null);
    }
  }

  @override
  Future<void> stopListening() async {
    _rec?.stop(); // 停止收音，結果會在 onend 回傳
  }

  @override
  Future<String?> awaitResult() async {
    final f = _result?.future;
    if (f == null) return null;
    final r = await f;
    _result = null;
    return r;
  }

  @override
  Future<String?> stopAndTranscribe() async {
    await stopListening();
    return awaitResult();
  }

  @override
  Future<String?> recordOnce({
    Duration maxDuration = const Duration(seconds: 15),
  }) async {
    await startRecording();
    return awaitResult().timeout(maxDuration, onTimeout: () {
      _rec?.stop();
      return null;
    });
  }

  @override
  Future<void> dispose() async {
    _stopLevel();
    _rec?.abort();
    _rec = null;
  }

  static String _describe(String code) => switch (code) {
        'not-allowed' || 'service-not-allowed' =>
          '麥克風權限被拒絕，請在網址列左邊的圖示允許使用麥克風',
        'no-speech'     => '沒有聽到聲音，請再說一次',
        'audio-capture' => '找不到麥克風，請確認裝置有接上',
        'network'       => '語音辨識需要連網，請確認網路',
        'aborted'       => '語音辨識已中斷',
        _               => '語音辨識失敗（$code）',
      };
}

// ── 音量偵測（web/voice_level.js）──────────────────────
@JS('voiceLevel')
external _VoiceLevel? get _voiceLevel;

extension type _VoiceLevel._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> start();
  external double level();
  external void stop();
}

// ── Web Speech API 型別 ─────────────────────────────────
extension type _SpeechRecognition._(JSObject _) implements JSObject {
  external set lang(String v);
  external set continuous(bool v);
  external set interimResults(bool v);
  external set maxAlternatives(int v);
  external set onresult(JSFunction? f);
  external set onerror(JSFunction? f);
  external set onend(JSFunction? f);
  external void start();
  external void stop();
  external void abort();
}

extension type _ResultEvent._(JSObject _) implements JSObject {
  external _ResultList get results;
}

extension type _ResultList._(JSObject _) implements JSObject {
  external int get length;
  external _Result item(int index);
}

extension type _Result._(JSObject _) implements JSObject {
  external _Alternative item(int index);
}

extension type _Alternative._(JSObject _) implements JSObject {
  external String get transcript;
}

extension type _ErrorEvent._(JSObject _) implements JSObject {
  external String get error;
}
