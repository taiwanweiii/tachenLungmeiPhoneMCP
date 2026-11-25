import UIKit
import Flutter
import Speech
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()
  private var pendingResult: FlutterResult?
  private var channel: FlutterMethodChannel?

  // 自動結束：說完後安靜一陣子就收音（對齊 Android 的 1.5 秒）
  private var sessionId = 0
  private var lastText = ""
  private var lastChange = Date()
  private var startedAt = Date()
  private var silenceTimer: Timer?
  // 這兩個時間由 Dart 每次開始聽時帶進來（使用者在語音設定裡調整）
  private var silenceAfterSpeech: TimeInterval = 1.5
  private var silenceBeforeSpeech: TimeInterval = 8.0
  // false：不會因為安靜自動結束（AI 講話時邊聽邊找插話關鍵字），由 armAutoStop／cancelListening 結束
  private var autoStop = true

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // 使用 SceneDelegate 時，啟動當下 window 還是 nil，
  // 所以 channel 要等 Flutter engine 建好後在這裡註冊（不可再用 window?.rootViewController as!）
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "curtain_mcp_stt") else { return }
    let channel = FlutterMethodChannel(
      name: "curtain_mcp/stt",
      binaryMessenger: registrar.messenger()
    )
    self.channel = channel

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "isAvailable":
        // 語音辨識 + 麥克風權限都在這裡原生申請（不靠 permission_handler，
        // 它在沒設定 PERMISSION_MICROPHONE 巨集時永遠回傳未授權）
        self.requestPermissions { granted in result(granted) }

      case "startListening":
        let args = call.arguments as? [String: Any] ?? [:]
        self.silenceAfterSpeech = (args["endSilence"] as? NSNumber)?.doubleValue ?? 1.5
        self.silenceBeforeSpeech = (args["idleTimeout"] as? NSNumber)?.doubleValue ?? 8.0
        self.autoStop = (args["autoStop"] as? Bool) ?? true
        self.startListening(result: result)

      case "stopListening":
        self.stopListening()
        result(nil)

      case "cancelListening":
        // 馬上停、丟掉聽到的內容（AI 講完了，邊聽邊找關鍵字的這次不要了）
        self.lastText = ""
        self.finish(error: nil)
        result(nil)

      case "armAutoStop":
        // 聽到插話關鍵字：接著聽使用者講完，停頓就收音
        let args = call.arguments as? [String: Any] ?? [:]
        self.silenceAfterSpeech = (args["endSilence"] as? NSNumber)?.doubleValue ?? self.silenceAfterSpeech
        self.autoStop = true
        self.lastChange = Date()
        self.startedAt = Date()
        self.startSilenceTimer()
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // ── 權限 ──────────────────────────────────────────────
  private func requestPermissions(_ done: @escaping (Bool) -> Void) {
    SFSpeechRecognizer.requestAuthorization { status in
      guard status == .authorized else {
        DispatchQueue.main.async { done(false) }
        return
      }
      let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { done(ok) } }
      if #available(iOS 17.0, *) {
        AVAudioApplication.requestRecordPermission { finish($0) }
      } else {
        AVAudioSession.sharedInstance().requestRecordPermission { finish($0) }
      }
    }
  }

  // ── 開始錄音辨識 ──────────────────────────────────────
  private func startListening(result: @escaping FlutterResult) {
    requestPermissions { [weak self] granted in
      guard let self = self else { return }
      guard granted else {
        result(FlutterError(
          code: "PERMISSION_DENIED",
          message: "語音辨識或麥克風權限未開啟（請到 設定 › 隆美 開啟）",
          details: nil
        ))
        return
      }
      do {
        try self.startRecognition(result: result)
      } catch {
        result(FlutterError(
          code: "STT_ERROR",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }

  /// 只回覆一次；有聽到字就回字，沒有才回錯誤
  private func finish(error: Error?) {
    guard let reply = pendingResult else { return }
    pendingResult = nil
    silenceTimer?.invalidate()
    silenceTimer = nil
    stopAudioEngine()
    if !lastText.isEmpty {
      reply(lastText)
    } else if let error = error {
      reply(FlutterError(code: "STT_ERROR", message: error.localizedDescription, details: nil))
    } else {
      reply("")
    }
  }

  private func startRecognition(result: @escaping FlutterResult) throws {
    // 清除上一次（上一次還沒回覆的話先回空字串，不要讓 Dart 永遠等）
    if let old = pendingResult {
      pendingResult = nil
      old("")
    }
    recognitionTask?.cancel()
    recognitionTask = nil
    stopAudioEngine()
    pendingResult = result
    sessionId += 1
    lastText = ""
    lastChange = Date()
    startedAt = Date()

    // 錄音和朗讀共用同一個 Session：用 playAndRecord + 預設走喇叭，
    // 不然錄過音之後 TTS 會變成沒聲音（舊版設成 .record 就不會有輸出）
    let audioSession = AVAudioSession.sharedInstance()
    // AI 正在講話時開始聽（找插話關鍵字）：TTS 已經把 Session 設成 playAndRecord，
    // 這時再設一次可能讓正在唸的聲音頓一下，所以已經是 playAndRecord 就不重設
    if autoStop || audioSession.category != .playAndRecord {
      try audioSession.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker, .allowBluetooth]
      )
    }
    try audioSession.setActive(true)

    speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    guard let recognizer = speechRecognizer, recognizer.isAvailable else {
      pendingResult = nil
      throw NSError(domain: "stt", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "此裝置目前無法使用語音辨識"])
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    recognitionRequest = request
    request.shouldReportPartialResults = true

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] taskResult, error in
      guard let self = self else { return }
      if let text = taskResult?.bestTranscription.formattedString, !text.isEmpty {
        if text != self.lastText {
          self.lastText = text
          self.lastChange = Date()
          self.channel?.invokeMethod("onPartial", arguments: text)
        }
      }
      if taskResult?.isFinal == true || error != nil {
        DispatchQueue.main.async { self.finish(error: error) }
      }
    }

    // 接麥克風輸入，同時算音量給水波紋動畫
    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) {
      [weak self] buffer, _ in
      guard let self = self else { return }
      self.recognitionRequest?.append(buffer)
      if let ch = buffer.floatChannelData?[0] {
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = n > 0 ? sqrt(sum / Float(n)) : 0
        let db = 20 * log10(max(rms, 0.000_01))        // 約 -80 ~ 0 dB
        let level = Double(min(max((db + 50) / 40, 0), 1))
        DispatchQueue.main.async { self.channel?.invokeMethod("onLevel", arguments: level) }
      }
    }

    audioEngine.prepare()
    try audioEngine.start()

    silenceTimer?.invalidate()
    silenceTimer = nil
    if autoStop { startSilenceTimer() }
  }

  /// 自動結束：說完停頓 silenceAfterSpeech 秒就收音；一直沒開口 silenceBeforeSpeech 秒也收音
  private func startSilenceTimer() {
    silenceTimer?.invalidate()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      let now = Date()
      if !self.lastText.isEmpty {
        if now.timeIntervalSince(self.lastChange) >= self.silenceAfterSpeech { self.stopListening() }
      } else if now.timeIntervalSince(self.startedAt) >= self.silenceBeforeSpeech {
        self.stopListening()
      }
    }
  }

  // ── 停止錄音 ──────────────────────────────────────────
  // 只通知辨識器「音訊結束」，最後結果會經由辨識回呼 → finish() 回傳給 Dart
  private func stopListening() {
    silenceTimer?.invalidate()
    silenceTimer = nil
    recognitionRequest?.endAudio()
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    // 保險：endAudio 後 2 秒還沒有最後結果，就用目前聽到的字回覆
    let mySession = sessionId
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      guard let self = self, self.sessionId == mySession, self.pendingResult != nil else { return }
      self.finish(error: nil)
    }
  }

  private func stopAudioEngine() {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    recognitionTask?.cancel()
    recognitionTask = nil
  }
}
