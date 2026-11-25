package com.curtainmcp.curtain_mcp_flutter

import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "curtain_mcp/stt"
    private var speechRecognizer: SpeechRecognizer? = null
    private var pendingResult: MethodChannel.Result? = null
    private var isListening = false
    private var channel: MethodChannel? = null

    private var endSilenceMs = 1500L
    private var idleMs = 8000L
    private var autoStop = true
    private var gotSpeech = false
    // 一直沒開口 idleMs 就結束（Android 本身沒有這個設定）
    private val idleHandler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    // 時間由 Dart 帶進來（使用者在語音設定裡調整）
                    endSilenceMs = (((call.argument<Number>("endSilence"))?.toDouble() ?: 1.5) * 1000).toLong()
                    idleMs = (((call.argument<Number>("idleTimeout"))?.toDouble() ?: 8.0) * 1000).toLong()
                    autoStop = call.argument<Boolean>("autoStop") ?: true
                    startListening(result)
                }
                "stopListening"  -> stopListening(result)
                // 馬上停、丟掉聽到的內容
                "cancelListening" -> {
                    idleHandler.removeCallbacksAndMessages(null)
                    speechRecognizer?.cancel()
                    isListening = false
                    pendingResult?.success("")
                    pendingResult = null
                    result.success(null)
                }
                // Android 的辨識器停頓後會自己結束，聽到插話關鍵字後不用另外設定
                "armAutoStop" -> result.success(null)
                "isAvailable"    -> result.success(
                    SpeechRecognizer.isRecognitionAvailable(this)
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun startListening(result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.error("UNAVAILABLE", "此裝置不支援語音辨識", null)
            return
        }

        // 若上一個還在跑，先清掉（上一個還沒回覆的話先回空字串，不要讓 Dart 永遠等）
        idleHandler.removeCallbacksAndMessages(null)
        speechRecognizer?.destroy()
        speechRecognizer = null
        pendingResult?.success("")
        pendingResult = result
        isListening = true
        gotSpeech = false
        if (autoStop) {
            idleHandler.postDelayed({
                if (!gotSpeech && pendingResult != null) {
                    speechRecognizer?.cancel()
                    isListening = false
                    pendingResult?.success("")
                    pendingResult = null
                }
            }, idleMs)
        }

        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this)
        speechRecognizer?.setRecognitionListener(object : RecognitionListener {

            override fun onResults(bundle: Bundle?) {
                isListening = false
                idleHandler.removeCallbacksAndMessages(null)
                val matches = bundle
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = matches?.firstOrNull() ?: ""
                pendingResult?.success(text)
                pendingResult = null
            }

            override fun onError(errorCode: Int) {
                isListening = false
                idleHandler.removeCallbacksAndMessages(null)
                val msg = sttErrorMessage(errorCode)
                pendingResult?.error("STT_ERROR", msg, errorCode)
                pendingResult = null
            }

            // ✅ 修復：stopListening 後系統會觸發 onResults
            // 若沒有觸發，在 onEndOfSpeech 不做任何事，等 onResults 自然回傳
            override fun onEndOfSpeech() {
                // 不要在這裡回傳結果，等 onResults
            }

            override fun onReadyForSpeech(p0: Bundle?) {}
            override fun onBeginningOfSpeech() { gotSpeech = true }
            // 音量（約 -2 ~ 10 dB）換算成 0 ~ 1，給水波紋動畫用
            override fun onRmsChanged(rmsdB: Float) {
                val level = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f)
                channel?.invokeMethod("onLevel", level.toDouble())
            }
            override fun onBufferReceived(p0: ByteArray?) {}
            // 邊說邊把目前辨識到的文字送回 Flutter
            override fun onPartialResults(bundle: Bundle?) {
                val text = bundle
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                if (!text.isNullOrBlank()) {
                    gotSpeech = true
                    channel?.invokeMethod("onPartial", text)
                }
            }
            override fun onEvent(p0: Int, p1: Bundle?) {}
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-TW")
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            // ✅ 讓系統等待足夠時間，避免太快截斷
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                endSilenceMs
            )
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                endSilenceMs
            )
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS,
                2000L
            )
        }
        speechRecognizer?.startListening(intent)
    }

    // ✅ 修復：stopListening 不直接回傳，等 onResults 回傳結果
    private fun stopListening(result: MethodChannel.Result) {
        if (isListening) {
            // 告訴系統停止錄音，但繼續等待 onResults 回傳辨識結果
            speechRecognizer?.stopListening()
            // 不呼叫 result.success()，讓 onResults 去處理 pendingResult
        }
        // 這個 result 直接回傳 null（stopListening 本身的 callback）
        result.success(null)
    }

    private fun sttErrorMessage(code: Int) = when (code) {
        SpeechRecognizer.ERROR_AUDIO                    -> "錄音錯誤"
        SpeechRecognizer.ERROR_CLIENT                   -> "客戶端錯誤"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "缺少麥克風權限"
        SpeechRecognizer.ERROR_NETWORK                  -> "網路錯誤"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT          -> "網路逾時"
        SpeechRecognizer.ERROR_NO_MATCH                 -> "未辨識到語音"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY          -> "辨識器忙碌中"
        SpeechRecognizer.ERROR_SERVER                   -> "伺服器錯誤"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT           -> "等待語音逾時"
        else                                            -> "未知錯誤($code)"
    }

    override fun onDestroy() {
        speechRecognizer?.destroy()
        super.onDestroy()
    }
}