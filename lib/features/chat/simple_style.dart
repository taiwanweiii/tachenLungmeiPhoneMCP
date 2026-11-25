import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 簡易模式的畫面風格。選一個風格會換掉整個簡易模式畫面（背景、狀態卡、文字對話、
/// 已選清單、底部按鈕、麥克風），不是只換麥克風。設計稿：畫布「底部按鈕風格」A～D。
/// [classic]：傳統（原本的兩張大卡片＋最下面一排），完全不變，也是預設。
enum SimpleStyle { classic, neon, wave, orb, hud }

/// 麥克風（底部大按鈕）目前的狀態
enum MicPhase { idle, listening, thinking, speaking }

class SimpleStyleSpec {
  const SimpleStyleSpec({
    required this.id,
    required this.name,
    required this.desc,
    required this.bg,
    required this.card,
    required this.cardBorder,
    required this.chipBg,
    required this.text,
    required this.muted,
    required this.primary,
    required this.onPrimary,
    required this.radius,
    required this.accents,
    this.mono = false,
  });

  final SimpleStyle id;
  final String name;
  final String desc;
  final Color bg, card, cardBorder, chipBg, text, muted, primary, onPrimary;
  final double radius;

  /// 每個狀態的漸層色（第一個是主色）
  final Map<MicPhase, List<Color>> accents;

  /// 科技字（等寬英文小標）
  final bool mono;

  Color accent(MicPhase p) => accents[p]!.first;

  /// 新版面的四個風格（傳統不在這裡，它用原本的版面）
  static const all = [neon, wave, orb, hud];

  static SimpleStyleSpec of(SimpleStyle s) => switch (s) {
        SimpleStyle.classic => classic,
        SimpleStyle.neon => neon,
        SimpleStyle.wave => wave,
        SimpleStyle.orb => orb,
        SimpleStyle.hud => hud,
      };

  /// 傳統：原本的版面與 App 主題（這份只用在設定裡的預覽和名稱）
  static const classic = SimpleStyleSpec(
    id: SimpleStyle.classic,
    name: '傳統',
    desc: '原本的樣子',
    bg: Color(0xFF111318),
    card: Color(0xFF1D2024),
    cardBorder: Color(0xFF44474E),
    chipBg: Color(0xFF33353A),
    text: Color(0xFFE2E2E9),
    muted: Color(0xFFC4C6D0),
    primary: Color(0xFFA8C8FF),
    onPrimary: Color(0xFF0A305F),
    radius: 20,
    accents: {
      MicPhase.idle: [Color(0xFFA8C8FF)],
      MicPhase.listening: [Color(0xFFFFB4AB)],
      MicPhase.thinking: [Color(0xFFA8C8FF)],
      MicPhase.speaking: [Color(0xFFA8C8FF)],
    },
  );

  static const neon = SimpleStyleSpec(
    id: SimpleStyle.neon,
    name: 'A・霓虹光環',
    desc: '旋轉漸層光圈',
    bg: Color(0xFF0B0D12),
    card: Color(0xFF151922),
    cardBorder: Color(0x38A8C8FF),
    chipBg: Color(0xFF232838),
    text: Color(0xFFE6ECF7),
    muted: Color(0xFFAEB6C6),
    primary: Color(0xFF7FD8FF),
    onPrimary: Color(0xFF04132B),
    radius: 20,
    accents: {
      MicPhase.idle: [Color(0xFF00E5FF), Color(0xFF5B8CFF), Color(0xFFB26BFF)],
      MicPhase.listening: [Color(0xFFFF5F6D), Color(0xFFFFB347), Color(0xFFFF2E93)],
      MicPhase.thinking: [Color(0xFF5B8CFF), Color(0xFF1D2A4A), Color(0xFF5B8CFF)],
      MicPhase.speaking: [Color(0xFF00FFA3), Color(0xFF00E5FF), Color(0xFF5B8CFF)],
    },
  );

  static const wave = SimpleStyleSpec(
    id: SimpleStyle.wave,
    name: 'B・聲波膠囊',
    desc: '膠囊底座＋聲波',
    bg: Color(0xFF0B0D12),
    card: Color(0xFF1A1E27),
    cardBorder: Color(0x1FFFFFFF),
    chipBg: Color(0xFF262B36),
    text: Color(0xFFE6E9F0),
    muted: Color(0xFFADB3BF),
    primary: Color(0xFF8FB4FF),
    onPrimary: Color(0xFF04132B),
    radius: 26,
    accents: {
      MicPhase.idle: [Color(0xFF00E5FF), Color(0xFF5B8CFF), Color(0xFF9B6BFF)],
      MicPhase.listening: [Color(0xFFFF9966), Color(0xFFFF5E62)],
      MicPhase.thinking: [Color(0xFF7FA6FF), Color(0xFF2A3350)],
      MicPhase.speaking: [Color(0xFF00E5FF), Color(0xFF5B8CFF)],
    },
  );

  static const orb = SimpleStyleSpec(
    id: SimpleStyle.orb,
    name: 'C・全息光球',
    desc: '會呼吸的光球',
    bg: Color(0xFF07080C),
    card: Color(0xFF12141A),
    cardBorder: Color(0x14FFFFFF),
    chipBg: Color(0xFF1E2128),
    text: Color(0xFFE4E6EC),
    muted: Color(0xFFA9AEBA),
    primary: Color(0xFF9DB4FF),
    onPrimary: Color(0xFF0A1440),
    radius: 26,
    accents: {
      MicPhase.idle: [Color(0xFF2F7BFF), Color(0xFF8A5CFF), Color(0xFFC9F6FF), Color(0xFF0C1D52)],
      MicPhase.listening: [Color(0xFFFF7A4D), Color(0xFFFF3D77), Color(0xFFFFE1D6), Color(0xFF5A0F2A)],
      MicPhase.thinking: [Color(0xFF3A4A7A), Color(0xFF6F82C0), Color(0xFFDFE7FF), Color(0xFF10152A)],
      MicPhase.speaking: [Color(0xFF00D9A6), Color(0xFF00B3FF), Color(0xFFD8FFF4), Color(0xFF03324A)],
    },
  );

  static const hud = SimpleStyleSpec(
    id: SimpleStyle.hud,
    name: 'D・科幻 HUD',
    desc: '八角框＋掃描線',
    bg: Color(0xFF05080C),
    card: Color(0xFF08121A),
    cardBorder: Color(0x5900E5FF),
    chipBg: Color(0xFF0E2230),
    text: Color(0xFFDDF8FF),
    muted: Color(0xFF8FB3BD),
    primary: Color(0xFF00E5FF),
    onPrimary: Color(0xFF001318),
    radius: 4,
    mono: true,
    accents: {
      MicPhase.idle: [Color(0xFF00E5FF)],
      MicPhase.listening: [Color(0xFFFF4D6D)],
      MicPhase.thinking: [Color(0xFFFFD166)],
      MicPhase.speaking: [Color(0xFF7CFFB2)],
    },
  );

  // ── 存在手機上 ──────────────────────────────────────────
  static const _k = 'simple_style';

  static Future<SimpleStyle> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(_k);
      return SimpleStyle.values.firstWhere((s) => s.name == v,
          orElse: () => SimpleStyle.classic);
    } catch (_) {
      return SimpleStyle.classic;
    }
  }

  static Future<void> save(SimpleStyle s) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_k, s.name);
    } catch (_) {}
  }

  /// 套到簡易模式整個畫面：深色、這個風格的顏色與圓角。
  /// 保留 App 原本的按鈕、輸入框等設定，只換顏色。
  ThemeData apply(ThemeData base) {
    final cs = ColorScheme.fromSeed(seedColor: primary, brightness: Brightness.dark).copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: Color.lerp(bg, primary, 0.28),
      onPrimaryContainer: text,
      secondaryContainer: Color.lerp(card, primary, 0.18),
      onSecondaryContainer: text,
      surface: bg,
      onSurface: text,
      onSurfaceVariant: muted,
      surfaceContainerLowest: bg,
      surfaceContainerLow: card,
      surfaceContainer: card,
      surfaceContainerHigh: Color.lerp(card, Colors.white, 0.05),
      surfaceContainerHighest: chipBg,
      outline: muted,
      outlineVariant: cardBorder,
    );
    final text0 = base.textTheme.apply(bodyColor: text, displayColor: text);
    return ThemeData.from(colorScheme: cs, textTheme: text0, useMaterial3: true).copyWith(
      scaffoldBackgroundColor: bg,
      filledButtonTheme: base.filledButtonTheme,
      outlinedButtonTheme: base.outlinedButtonTheme,
      textButtonTheme: base.textButtonTheme,
      inputDecorationTheme: base.inputDecorationTheme,
      dividerColor: cardBorder,
    );
  }

  /// 卡片外框（狀態卡、文字對話、已選清單共用）
  BoxDecoration cardDecoration({Color? borderColor, bool glow = false}) => BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? cardBorder, width: id == SimpleStyle.hud ? 1 : 1.2),
        boxShadow: glow && borderColor != null
            ? [BoxShadow(color: borderColor.withValues(alpha: 0.35), blurRadius: 18)]
            : const [],
      );

  TextStyle monoLabel(Color color) => TextStyle(
        fontFamily: 'monospace',
        fontSize: 10.5,
        letterSpacing: 1.4,
        fontWeight: FontWeight.w700,
        color: color,
      );
}

/// 簡易模式的背景：HUD 有網格，光球有地板反光
class SimpleBackdrop extends StatelessWidget {
  const SimpleBackdrop({super.key, required this.spec, required this.child});
  final SimpleStyleSpec spec;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: spec.bg,
      child: Stack(children: [
        if (spec.id == SimpleStyle.hud)
          Positioned.fill(child: CustomPaint(painter: _GridPainter(spec.primary))),
        if (spec.id == SimpleStyle.orb)
          Positioned(
            left: 0,
            right: 0,
            bottom: -80,
            height: 220,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(colors: [
                    spec.accent(MicPhase.idle).withValues(alpha: 0.22),
                    spec.bg.withValues(alpha: 0),
                  ]),
                ),
              ),
            ),
          ),
        Positioned.fill(child: child),
      ]),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color.withValues(alpha: 0.05)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (var y = 0.0; y < size.height; y += 22) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

// ══════════════════════════════════════════════════════════════
// 底部：目錄／麥克風／打字
// ══════════════════════════════════════════════════════════════

/// 底部三顆按鈕。麥克風：點一下說話、說到一半點一下送出、AI 講話時點一下打斷、長按開設定
class SimpleDock extends StatefulWidget {
  const SimpleDock({
    super.key,
    required this.spec,
    required this.phase,
    required this.level,
    required this.continuous,
    required this.onMicTap,
    this.onMicLongPress,
    required this.onCatalog,
    required this.onKeyboard,
    this.sideEnabled = true,
  });

  final SimpleStyleSpec spec;
  final MicPhase phase;
  final ValueListenable<double> level;
  final bool continuous;
  final VoidCallback? onMicTap;
  final VoidCallback? onMicLongPress;
  final VoidCallback onCatalog, onKeyboard;
  final bool sideEnabled;

  static String labelOf(MicPhase p) => switch (p) {
        MicPhase.idle => '點一下說話・長按設定',
        MicPhase.listening => '聆聽中・點一下送出',
        MicPhase.thinking => 'AI 思考中…',
        MicPhase.speaking => 'AI 回答中・點一下打斷',
      };

  @override
  State<SimpleDock> createState() => _SimpleDockState();
}

class _SimpleDockState extends State<SimpleDock> with SingleTickerProviderStateMixin {
  late final AnimationController _t =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  DateTime? _listenStart;

  @override
  void didUpdateWidget(SimpleDock old) {
    super.didUpdateWidget(old);
    if (widget.phase == MicPhase.listening && old.phase != MicPhase.listening) {
      _listenStart = DateTime.now();
    }
    if (widget.phase != MicPhase.listening) _listenStart = null;
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.spec;
    final mic = _MicButton(
      spec: s,
      phase: widget.phase,
      t: _t,
      level: widget.level,
      continuous: widget.continuous,
      onTap: widget.onMicTap,
      onLongPress: widget.onMicLongPress,
    );
    final label = Text(
      SimpleDock.labelOf(widget.phase),
      style: TextStyle(fontSize: 12.5, color: s.muted),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    if (s.id == SimpleStyle.wave) return _waveDock(mic, label);

    final side = widget.sideEnabled ? 1.0 : 0.4;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Opacity(
          opacity: side,
          child: _SideButton(
              spec: s,
              icon: Icons.view_list_rounded,
              label: '目錄',
              code: 'CATALOG',
              leftSide: true,
              onTap: widget.sideEnabled ? widget.onCatalog : null),
        ),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            mic,
            const SizedBox(height: 8),
            if (s.id == SimpleStyle.hud)
              AnimatedBuilder(
                animation: _t,
                builder: (_, __) => Text(_hudCode(), style: s.monoLabel(s.accent(widget.phase))),
              ),
            label,
          ]),
        ),
        Opacity(
          opacity: side,
          child: _SideButton(
              spec: s,
              icon: Icons.keyboard_alt_outlined,
              label: '打字',
              code: 'KEYBOARD',
              leftSide: false,
              onTap: widget.sideEnabled ? widget.onKeyboard : null),
        ),
      ]),
    );
  }

  String _hudCode() {
    switch (widget.phase) {
      case MicPhase.listening:
        final sec = _listenStart == null
            ? 0
            : DateTime.now().difference(_listenStart!).inSeconds;
        return '● REC 00:${sec.toString().padLeft(2, '0')}';
      case MicPhase.thinking:
        return 'PROCESSING';
      case MicPhase.speaking:
        return '◀ AI OUTPUT';
      case MicPhase.idle:
        return 'READY';
    }
  }

  /// B：整條膠囊，兩側聲波，麥克風浮在中間
  Widget _waveDock(Widget mic, Widget label) {
    final s = widget.spec;
    Widget side(IconData icon, String tip, VoidCallback onTap) => Opacity(
          opacity: widget.sideEnabled ? 1 : 0.4,
          child: Tooltip(
            message: tip,
            child: Material(
              color: Colors.white.withValues(alpha: 0.05),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.sideEnabled ? onTap : null,
                child: SizedBox(
                    width: 48, height: 48, child: Icon(icon, color: s.primary, size: 22)),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 30, 14, 14),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          height: 68,
          child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(34),
                gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF1E222C), Color(0xFF13161D)]),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                boxShadow: const [
                  BoxShadow(color: Color(0x80000000), blurRadius: 28, offset: Offset(0, 10)),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                side(Icons.view_list_rounded, '從目錄挑選', widget.onCatalog),
                Expanded(child: _bars(mirror: false)),
                const SizedBox(width: 88),
                Expanded(child: _bars(mirror: true)),
                side(Icons.keyboard_alt_outlined, '打字（聊天模式）', widget.onKeyboard),
              ]),
            ),
            Positioned(top: -24, child: mic),
          ]),
        ),
        const SizedBox(height: 10),
        label,
      ]),
    );
  }

  static const _heights = [10.0, 18.0, 28.0, 16.0, 34.0, 22.0, 12.0, 26.0];

  Widget _bars({required bool mirror}) {
    final s = widget.spec;
    final p = widget.phase;
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: Listenable.merge([_t, widget.level]),
        builder: (_, __) {
          final t = _t.value * 2 * math.pi * 4;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(_heights.length, (i0) {
              final i = mirror ? _heights.length - 1 - i0 : i0;
              final wobble = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(t + i * 0.9));
              double h;
              Color c;
              double op = 1;
              switch (p) {
                case MicPhase.listening:
                  // 跟著你的音量
                  final lv = widget.level.value.clamp(0.15, 1.0);
                  h = _heights[i] * wobble * lv + 4;
                  c = s.accents[p]!.last;
                case MicPhase.speaking:
                  h = _heights[i] * wobble + 3;
                  c = s.accents[p]!.first;
                case MicPhase.thinking:
                  h = 6;
                  c = s.accents[p]!.first;
                  op = 0.25 + 0.75 * (0.5 + 0.5 * math.sin(t * 0.6 + i * 0.7));
                case MicPhase.idle:
                  h = 4;
                  c = const Color(0xFF3A4150);
              }
              return Opacity(
                opacity: op,
                child: Container(
                  width: 4,
                  height: h,
                  decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

/// 兩側的小按鈕，依風格長得不一樣
class _SideButton extends StatelessWidget {
  const _SideButton({
    required this.spec,
    required this.icon,
    required this.label,
    required this.code,
    required this.leftSide,
    required this.onTap,
  });

  final SimpleStyleSpec spec;
  final IconData icon;
  final String label, code;
  final bool leftSide;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = spec;
    switch (s.id) {
      case SimpleStyle.orb:
        // 最低調：文字 + 小圖示
        return TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: s.muted,
            minimumSize: const Size(72, 48),
            textStyle: const TextStyle(fontSize: 13.5),
          ),
          onPressed: onTap,
          icon: Icon(icon, size: 20),
          label: Text(label),
        );
      case SimpleStyle.hud:
        // 斜角標籤 + 英文小字
        return Semantics(
          button: true,
          label: label,
          child: GestureDetector(
            onTap: onTap,
            child: CustomPaint(
              painter: _TabPainter(s.primary, leftSide: leftSide),
              child: SizedBox(
                width: 84,
                height: 52,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700, color: s.text)),
                  Text(code, style: s.monoLabel(s.primary.withValues(alpha: 0.8))),
                ]),
              ),
            ),
          ),
        );
      case SimpleStyle.classic:
      case SimpleStyle.neon:
      case SimpleStyle.wave:
        // 圓圈和下面的字整顆都能按
        return Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 68,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: s.primary.withValues(alpha: 0.07),
                      border: Border.all(color: s.primary.withValues(alpha: 0.35)),
                    ),
                    child: Icon(icon, color: s.primary, size: 22),
                  ),
                  const SizedBox(height: 6),
                  Text(label, style: TextStyle(fontSize: 12, color: s.muted)),
                ]),
              ),
            ),
          ),
        );
    }
  }
}

class _TabPainter extends CustomPainter {
  _TabPainter(this.color, {required this.leftSide});
  final Color color;
  final bool leftSide;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, k = w * 0.14;
    final path = leftSide
        ? (Path()
          ..moveTo(k, 0)
          ..lineTo(w, 0)
          ..lineTo(w - k, h)
          ..lineTo(0, h)
          ..close())
        : (Path()
          ..moveTo(0, 0)
          ..lineTo(w - k, 0)
          ..lineTo(w, h)
          ..lineTo(k, h)
          ..close());
    canvas.drawPath(path, Paint()..color = const Color(0xFF08121A));
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.45));
  }

  @override
  bool shouldRepaint(_TabPainter old) => old.color != color;
}

// ══════════════════════════════════════════════════════════════
// 麥克風本體
// ══════════════════════════════════════════════════════════════
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.spec,
    required this.phase,
    required this.t,
    required this.level,
    required this.continuous,
    required this.onTap,
    required this.onLongPress,
  });

  final SimpleStyleSpec spec;
  final MicPhase phase;
  final Animation<double> t;
  final ValueListenable<double> level;
  final bool continuous;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  double get _size => switch (spec.id) {
        SimpleStyle.classic || SimpleStyle.neon => 88,
        SimpleStyle.wave => 80,
        SimpleStyle.orb => 96,
        SimpleStyle.hud => 92,
      };

  @override
  Widget build(BuildContext context) {
    final size = _size;
    return Semantics(
      button: true,
      label: SimpleDock.labelOf(phase),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox(
          width: size + 28,
          height: size + 16,
          child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            AnimatedBuilder(
              animation: Listenable.merge([t, level]),
              builder: (_, __) => SizedBox(
                width: size,
                height: size,
                child: switch (spec.id) {
                  SimpleStyle.classic || SimpleStyle.neon => _neon(size),
                  SimpleStyle.wave => _wave(size),
                  SimpleStyle.orb => _orb(size),
                  SimpleStyle.hud => _hud(size),
                },
              ),
            ),
            if (continuous)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: spec.chipBg,
                    borderRadius: BorderRadius.circular(spec.id == SimpleStyle.hud ? 2 : 999),
                    border: Border.all(color: spec.cardBorder),
                  ),
                  child: Text('連續',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700, color: spec.text)),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  double get _v => t.value; // 0~1，4 秒一圈

  Widget _icon(Color color, double sz) =>
      Icon(Icons.mic_rounded, color: color, size: sz);

  Widget _eq(List<Color> colors, {double h = 26, double w = 4, int n = 5}) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(n, (i) {
          final k = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(_v * 2 * math.pi * 5 + i * 0.9));
          return Container(
            margin: EdgeInsets.symmetric(horizontal: w * 0.5),
            width: w,
            height: h * k,
            decoration: BoxDecoration(
                color: colors[i % colors.length], borderRadius: BorderRadius.circular(2)),
          );
        }),
      );

  Widget _dots(Color c) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final o = 0.25 + 0.75 * (0.5 + 0.5 * math.sin(_v * 2 * math.pi * 3 - i * 0.9));
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c.withValues(alpha: o), shape: BoxShape.circle),
          );
        }),
      );

  /// A：旋轉漸層光圈
  Widget _neon(double size) {
    final c = spec.accents[phase]!;
    final speed = switch (phase) {
      MicPhase.idle => 1.0,
      MicPhase.listening => 3.0,
      MicPhase.thinking => 6.0,
      MicPhase.speaking => 2.0,
    };
    final halo = phase == MicPhase.listening;
    final lv = level.value;
    return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
      if (halo)
        for (final ph in [0.0, 0.5])
          Builder(builder: (_) {
            final p = (_v * 3 + ph) % 1;
            final grow = 1 + p * (0.35 + lv * 0.3);
            return Container(
              width: size * grow,
              height: size * grow,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: c.first.withValues(alpha: (1 - p) * 0.7), width: 2),
              ),
            );
          }),
      Transform.rotate(
        angle: _v * 2 * math.pi * speed,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(colors: [...c, c.first]),
            boxShadow: [
              BoxShadow(color: c.first.withValues(alpha: 0.45), blurRadius: 26),
              BoxShadow(color: c.first.withValues(alpha: 0.18), blurRadius: 60),
            ],
          ),
        ),
      ),
      Container(
        width: size - 8,
        height: size - 8,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: Alignment(0, -0.4),
            colors: [Color(0xFF1F2738), Color(0xFF0B0E14)],
          ),
        ),
        child: switch (phase) {
          MicPhase.thinking => _dots(const Color(0xFF8FB4FF)),
          MicPhase.speaking => _eq(c),
          _ => _icon(const Color(0xFFEAF6FF), 34),
        },
      ),
    ]);
  }

  /// B：漸層圓鈕（聲波在膠囊上）
  Widget _wave(double size) {
    final c = spec.accents[phase]!;
    return Stack(alignment: Alignment.center, children: [
      if (phase == MicPhase.thinking)
        SizedBox(
          width: size + 10,
          height: size + 10,
          child: CircularProgressIndicator(strokeWidth: 3, color: c.first),
        ),
      Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: c.length > 1 ? c : [c.first, c.first]),
          border: Border.all(color: spec.bg, width: 3),
          boxShadow: [
            if (phase == MicPhase.listening || phase == MicPhase.speaking)
              BoxShadow(color: c.first.withValues(alpha: 0.18), spreadRadius: 6),
            BoxShadow(color: c.first.withValues(alpha: 0.45), blurRadius: 26, offset: const Offset(0, 8)),
          ],
        ),
        child: phase == MicPhase.speaking
            ? const Icon(Icons.stop_rounded, color: Color(0xFF04132B), size: 30)
            : _icon(phase == MicPhase.thinking ? const Color(0xFF9FB6E6) : const Color(0xFF04132B), 32),
      ),
    ]);
  }

  /// C：會呼吸、會變形的光球
  Widget _orb(double size) {
    final c = spec.accents[phase]!; // [主色, 次色, 亮點, 深色]
    final rate = switch (phase) {
      MicPhase.listening => 4.0,
      MicPhase.speaking => 5.0,
      _ => 1.0,
    };
    final a = _v * 2 * math.pi * rate;
    final lv = phase == MicPhase.listening ? level.value * 0.12 : 0.0;
    final sx = 1 + 0.04 * math.sin(a) + lv;
    final sy = 1 + 0.04 * math.cos(a * 1.3) + lv;
    return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
      Container(
        width: size * 1.45,
        height: size * 1.45,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [
            c.first.withValues(alpha: 0.4 + 0.15 * math.sin(a)),
            c.first.withValues(alpha: 0),
          ]),
        ),
      ),
      if (phase == MicPhase.thinking)
        Transform.rotate(
          angle: _v * 2 * math.pi * 4,
          child: CustomPaint(
            size: Size.square(size + 14),
            painter: _ArcPainter(c[2]),
          ),
        ),
      Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(sx, sy, 1),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.35, -0.4),
              radius: 1.0,
              colors: [c[2], c.first, c[1], c[3]],
              stops: const [0.0, 0.35, 0.7, 1.0],
            ),
            boxShadow: [BoxShadow(color: c.first.withValues(alpha: 0.55), blurRadius: 30)],
          ),
          child: phase == MicPhase.speaking
              ? const Icon(Icons.stop_rounded, color: Colors.white, size: 28)
              : _icon(Colors.white, 30),
        ),
      ),
    ]);
  }

  /// D：八角框、四角瞄準框、掃描線
  Widget _hud(double size) {
    final a = spec.accent(phase);
    return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
      if (phase == MicPhase.thinking)
        Transform.rotate(
          angle: _v * 2 * math.pi,
          child: CustomPaint(size: Size.square(size + 30), painter: _DashCirclePainter(a)),
        ),
      CustomPaint(
        size: Size.square(size + 16),
        painter: _BracketPainter(a),
      ),
      Opacity(
        opacity: phase == MicPhase.listening ? 0.55 + 0.45 * (0.5 + 0.5 * math.sin(_v * 2 * math.pi * 4)) : 1,
        child: CustomPaint(
          size: Size.square(size),
          painter: _OctagonPainter(a),
        ),
      ),
      ClipPath(
        clipper: _OctagonClipper(),
        child: SizedBox(
          width: size - 6,
          height: size - 6,
          child: Stack(alignment: Alignment.center, children: [
            if (phase == MicPhase.listening)
              Positioned(
                left: 6,
                right: 6,
                top: (size - 6) * (0.08 + 0.84 * (0.5 + 0.5 * math.sin(_v * 2 * math.pi * 3))),
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(color: a, boxShadow: [BoxShadow(color: a, blurRadius: 8)]),
                ),
              ),
            if (phase == MicPhase.speaking)
              _eq([a], h: 24, w: 3, n: 6)
            else
              Icon(Icons.mic_none_rounded, color: a, size: 32),
          ]),
        ),
      ),
    ]);
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawArc(
        r.deflate(2),
        0,
        math.pi * 0.8,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(colors: [color.withValues(alpha: 0), color]).createShader(r));
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}

Path _octagon(Size s) {
  final w = s.width, h = s.height;
  return Path()
    ..moveTo(w * 0.3, 0)
    ..lineTo(w * 0.7, 0)
    ..lineTo(w, h * 0.3)
    ..lineTo(w, h * 0.7)
    ..lineTo(w * 0.7, h)
    ..lineTo(w * 0.3, h)
    ..lineTo(0, h * 0.7)
    ..lineTo(0, h * 0.3)
    ..close();
}

class _OctagonClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) => _octagon(size);
  @override
  bool shouldReclip(_OctagonClipper old) => false;
}

class _OctagonPainter extends CustomPainter {
  _OctagonPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = _octagon(size);
    canvas.drawPath(p, Paint()..color = const Color(0xFF060A0F));
    canvas.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color
          ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4));
  }

  @override
  bool shouldRepaint(_OctagonPainter old) => old.color != color;
}

class _BracketPainter extends CustomPainter {
  _BracketPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const l = 14.0;
    final w = size.width, h = size.height;
    for (final (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (w, 0.0, -1.0, 1.0), (0.0, h, 1.0, -1.0), (w, h, -1.0, -1.0)]) {
      canvas.drawLine(Offset(x, y), Offset(x + l * dx, y), p);
      canvas.drawLine(Offset(x, y), Offset(x, y + l * dy), p);
    }
  }

  @override
  bool shouldRepaint(_BracketPainter old) => old.color != color;
}

class _DashCirclePainter extends CustomPainter {
  _DashCirclePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final r = Offset.zero & size;
    const n = 36;
    for (var i = 0; i < n; i += 2) {
      canvas.drawArc(r.deflate(1), i * 2 * math.pi / n, math.pi / n, false, p);
    }
  }

  @override
  bool shouldRepaint(_DashCirclePainter old) => old.color != color;
}

// ══════════════════════════════════════════════════════════════
// 上方兩張狀態卡（只顯示，不用按；AI 回答時點 AI 卡可以打斷）
// ══════════════════════════════════════════════════════════════
class SimpleStatusCards extends StatelessWidget {
  const SimpleStatusCards({
    super.key,
    required this.spec,
    required this.phase,
    required this.aiText,
    required this.userText,
    this.onAiTap,
  });

  final SimpleStyleSpec spec;
  final MicPhase phase;
  final String aiText, userText;
  final VoidCallback? onAiTap;

  @override
  Widget build(BuildContext context) {
    final s = spec;
    final aiActive = phase == MicPhase.thinking || phase == MicPhase.speaking;
    final youActive = phase == MicPhase.listening;
    final aiState = switch (phase) {
      MicPhase.thinking => s.mono ? 'AI · PROCESSING' : 'AI 助理・思考中',
      MicPhase.speaking => s.mono ? 'AI · OUTPUT' : 'AI 助理・回答中',
      _ => s.mono ? 'AI · STANDBY' : 'AI 助理・待命',
    };
    final youState = youActive ? (s.mono ? 'YOU · REC' : '你・聆聽中') : (s.mono ? 'YOU' : '你');

    Widget card({
      required bool active,
      required Color activeColor,
      required Widget avatar,
      required String state,
      required String text,
      VoidCallback? onTap,
    }) =>
        Expanded(
          child: Semantics(
            button: onTap != null,
            child: GestureDetector(
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                // 高度跟著內容（字型、字級不同也不會被切掉），兩張卡由外層撐成一樣高
                constraints: const BoxConstraints(minHeight: 76),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: s.cardDecoration(
                    borderColor: active ? activeColor : null, glow: active),
                child: Row(children: [
                  avatar,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(state,
                            style: s.mono
                                ? s.monoLabel(active ? activeColor : s.muted)
                                : TextStyle(fontSize: 11.5, color: active ? activeColor : s.muted)),
                        const SizedBox(height: 2),
                        Text(text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, height: 1.35, color: s.text)),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );

    final aiColor = s.accent(phase == MicPhase.listening || phase == MicPhase.idle
        ? MicPhase.speaking
        : phase);
    return IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      card(
        active: aiActive,
        activeColor: aiColor,
        avatar: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: s.id == SimpleStyle.hud ? BoxShape.rectangle : BoxShape.circle,
            gradient: s.id == SimpleStyle.hud
                ? null
                : RadialGradient(
                    center: const Alignment(-0.3, -0.4),
                    colors: [s.accents[MicPhase.idle]!.last, s.accents[MicPhase.idle]!.first]),
            color: s.id == SimpleStyle.hud ? s.card : null,
            border: s.id == SimpleStyle.hud ? Border.all(color: s.primary) : null,
          ),
          child: Icon(Icons.auto_awesome_rounded,
              size: 16, color: s.id == SimpleStyle.hud ? s.primary : Colors.white),
        ),
        state: aiState,
        text: aiText,
        onTap: onAiTap,
      ),
      const SizedBox(width: 8),
      card(
        active: youActive,
        activeColor: s.accent(MicPhase.listening),
        avatar: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: s.id == SimpleStyle.hud ? BoxShape.rectangle : BoxShape.circle,
            color: s.chipBg,
            border: s.id == SimpleStyle.hud ? Border.all(color: s.cardBorder) : null,
          ),
          child: Text('你',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: s.text)),
        ),
        state: youState,
        text: userText,
      ),
    ]));
  }
}

/// 設定裡選風格用的小預覽：這個風格的麥克風縮圖 + 名稱
class SimpleStyleSwatch extends StatelessWidget {
  const SimpleStyleSwatch({super.key, required this.spec, required this.selected, required this.onTap});
  final SimpleStyleSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = spec;
    final c = s.accents[MicPhase.idle]!;
    final Widget mini = switch (s.id) {
      SimpleStyle.classic => Container(
          width: 34,
          height: 34,
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF284777)),
          child: const Icon(Icons.mic_rounded, size: 18, color: Color(0xFFD6E3FF)),
        ),
      SimpleStyle.neon => Container(
          width: 34,
          height: 34,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(shape: BoxShape.circle, gradient: SweepGradient(colors: [...c, c.first])),
          child: Container(
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF0B0E14)),
              child: const Icon(Icons.mic_rounded, size: 16, color: Colors.white)),
        ),
      SimpleStyle.wave => Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: c)),
          child: Icon(Icons.mic_rounded, size: 18, color: s.onPrimary),
        ),
      SimpleStyle.orb => Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(center: const Alignment(-0.35, -0.4), colors: [c[2], c[0], c[1], c[3]]),
            boxShadow: [BoxShadow(color: c[0].withValues(alpha: 0.5), blurRadius: 10)],
          ),
          child: const Icon(Icons.mic_rounded, size: 16, color: Colors.white),
        ),
      SimpleStyle.hud => CustomPaint(
          size: const Size.square(34),
          painter: _OctagonPainter(s.primary),
          child: SizedBox(
              width: 34, height: 34, child: Icon(Icons.mic_none_rounded, size: 16, color: s.primary)),
        ),
    };
    return Semantics(
      button: true,
      selected: selected,
      label: s.name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 76,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: s.bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: selected ? s.primary : Colors.white.withValues(alpha: 0.12),
                width: selected ? 2 : 1),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            mini,
            const SizedBox(height: 6),
            Text(s.name.split('・').last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: s.text)),
          ]),
        ),
      ),
    );
  }
}
