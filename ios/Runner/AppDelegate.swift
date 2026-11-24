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

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "isAvailable":
        result(SFSpeechRecognizer.authorizationStatus() != .denied)

      case "startListening":
        self.startListening(result: result)

      case "stopListening":
        self.stopListening()
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // ── 開始錄音辨識 ──────────────────────────────────────
  private func startListening(result: @escaping FlutterResult) {
    // 先申請權限
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self = self else { return }

        guard status == .authorized else {
          result(FlutterError(
            code: "PERMISSION_DENIED",
            message: "語音辨識權限未開啟",
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
  }

  private func startRecognition(result: @escaping FlutterResult) throws {
    // 清除上一次
    recognitionTask?.cancel()
    recognitionTask = nil
    pendingResult = result

    // 設定音訊 Session
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

    speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let recognitionRequest = recognitionRequest else { return }
    recognitionRequest.shouldReportPartialResults = false

    // 開始辨識
    recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) {
      [weak self] taskResult, error in
      guard let self = self else { return }

      if let error = error {
        self.pendingResult?(FlutterError(
          code: "STT_ERROR",
          message: error.localizedDescription,
          details: nil
        ))
        self.pendingResult = nil
        self.stopAudioEngine()
        return
      }

      if let text = taskResult?.bestTranscription.formattedString,
         taskResult?.isFinal == true {
        self.pendingResult?(text)
        self.pendingResult = nil
        self.stopAudioEngine()
      }
    }

    // 接麥克風輸入
    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) {
      [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }

    audioEngine.prepare()
    try audioEngine.start()
  }

  // ── 停止錄音 ──────────────────────────────────────────
  private func stopListening() {
    recognitionRequest?.endAudio()
    stopAudioEngine()
  }

  private func stopAudioEngine() {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    recognitionTask?.cancel()
    recognitionTask = nil
  }
}