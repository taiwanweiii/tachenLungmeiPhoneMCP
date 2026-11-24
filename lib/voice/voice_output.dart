abstract class VoiceOutput {
  Future<void> speak(String text);
  Future<void> stop();
  bool get isSpeaking;
}
