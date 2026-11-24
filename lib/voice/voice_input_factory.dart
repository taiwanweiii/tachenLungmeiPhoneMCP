import 'voice_input.dart';
import 'voice_input_factory_io.dart'
    if (dart.library.js_interop) 'voice_input_factory_web.dart' as impl;

/// 依平台建立語音輸入：Web 用瀏覽器 Web Speech API，其餘用 Android 原生辨識
VoiceInput createVoiceInput({required String language}) =>
    impl.createVoiceInput(language: language);
