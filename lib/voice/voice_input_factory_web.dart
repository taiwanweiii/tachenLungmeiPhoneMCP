import 'voice_input.dart';
import 'web_voice_input.dart';

VoiceInput createVoiceInput({required String language}) =>
    WebVoiceInput(language: language);
