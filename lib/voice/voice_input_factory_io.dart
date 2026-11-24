import 'mobile_voice_input.dart';
import 'voice_input.dart';

VoiceInput createVoiceInput({required String language}) =>
    MobileVoiceInput(language: language);
