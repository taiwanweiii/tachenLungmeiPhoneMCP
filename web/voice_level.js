// 麥克風音量偵測（給簡易模式的水波紋用）
// 瀏覽器的語音辨識不提供音量，這裡另外開一條麥克風串流，用 AnalyserNode 算音量。
window.voiceLevel = (function () {
  let ctx = null;
  let stream = null;
  let analyser = null;
  let data = null;
  let session = 0; // 避免 start 還沒完成就 stop 時，殘留麥克風

  function cleanup() {
    if (stream) stream.getTracks().forEach((t) => t.stop());
    if (ctx) ctx.close();
    ctx = stream = analyser = data = null;
  }

  return {
    async start() {
      const my = ++session;
      cleanup();
      try {
        const s = await navigator.mediaDevices.getUserMedia({ audio: true });
        if (my !== session) {
          s.getTracks().forEach((t) => t.stop());
          return;
        }
        stream = s;
        ctx = new (window.AudioContext || window.webkitAudioContext)();
        analyser = ctx.createAnalyser();
        analyser.fftSize = 512;
        data = new Uint8Array(analyser.fftSize);
        ctx.createMediaStreamSource(stream).connect(analyser);
      } catch (e) {
        cleanup();
      }
    },

    // 回傳 0 ~ 1 的音量
    level() {
      if (!analyser) return 0;
      analyser.getByteTimeDomainData(data);
      let sum = 0;
      for (let i = 0; i < data.length; i++) {
        const v = (data[i] - 128) / 128;
        sum += v * v;
      }
      return Math.min(1, Math.sqrt(sum / data.length) * 5);
    },

    stop() {
      session++;
      cleanup();
    },
  };
})();
