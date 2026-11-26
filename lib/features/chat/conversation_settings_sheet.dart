import 'package:flutter/material.dart';

import '../../voice/voice_settings.dart';
import 'simple_style.dart';

/// 長按麥克風（或右上角選單）打開：畫面風格、連續對話、停頓秒數、插話關鍵字。
/// 每次改動就呼叫 [onChanged]／[onStyleChanged]（呼叫端負責存檔、套用）。
class ConversationSettingsSheet extends StatefulWidget {
  const ConversationSettingsSheet({
    super.key,
    required this.initial,
    required this.onChanged,
    this.initialStyle = SimpleStyle.classic,
    this.onStyleChanged,
    this.initialMode = StyleMode.system,
    this.onModeChanged,
  });

  final VoiceConversationSettings initial;
  final void Function(VoiceConversationSettings) onChanged;
  final SimpleStyle initialStyle;
  final void Function(SimpleStyle)? onStyleChanged;
  final StyleMode initialMode;
  final void Function(StyleMode)? onModeChanged;

  @override
  State<ConversationSettingsSheet> createState() => _ConversationSettingsSheetState();
}

class _ConversationSettingsSheetState extends State<ConversationSettingsSheet> {
  late bool _continuous = widget.initial.continuous;
  late double _idle = widget.initial.idleSeconds.toDouble();
  late double _endSilence = widget.initial.endSilenceSeconds;
  late final List<String> _keywords = List.of(widget.initial.keywords);
  late SimpleStyle _style = widget.initialStyle;
  late StyleMode _mode = widget.initialMode;
  final _kwCtrl = TextEditingController();

  @override
  void dispose() {
    _kwCtrl.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(VoiceConversationSettings(
        continuous: _continuous,
        idleSeconds: _idle.round(),
        endSilenceSeconds: double.parse(_endSilence.toStringAsFixed(1)),
        keywords: List.of(_keywords),
      ));

  void _addKeyword() {
    final k = _kwCtrl.text.trim();
    if (k.isEmpty) return;
    if (!_keywords.contains(k)) setState(() => _keywords.add(k));
    _kwCtrl.clear();
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final muted = TextStyle(fontSize: 13, color: cs.onSurfaceVariant, height: 1.45);

    return Padding(
      // 鍵盤打開時整個往上推，輸入關鍵字時看得到
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // 標題列固定在上面（往下捲也看得到）：左邊「返回」關掉設定回到上一頁
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 20, 4),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: '返回',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 4),
              Expanded(child: Text('對話設定', style: theme.textTheme.titleLarge)),
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('完成'),
              ),
            ]),
          ),
          Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('每次改動會馬上存起來', style: muted),
              const SizedBox(height: 14),

              if (widget.onStyleChanged != null) ...[
                Text('畫面風格', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('整個 App 一起換（聊天、簡易模式、設定頁、按鈕、麥克風）；「傳統」是原本的樣子。',
                    style: muted),
                const SizedBox(height: 10),
                StylePicker(
                  style: _style,
                  mode: _mode,
                  onStyle: (s) {
                    setState(() => _style = s);
                    widget.onStyleChanged?.call(s);
                  },
                  onMode: (m) {
                    setState(() => _mode = m);
                    widget.onModeChanged?.call(m);
                  },
                ),
                const Divider(height: 28),
              ],

              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('連續對話'),
                subtitle: const Text('AI 講完自動再聽，不用每句都再按一次'),
                value: _continuous,
                onChanged: (v) {
                  setState(() => _continuous = v);
                  _emit();
                },
              ),
              const Divider(),

              _sliderTitle('幾秒沒講話自動暫停', '${_idle.round()} 秒'),
              Slider(
                value: _idle,
                min: VoiceConversationSettings.minIdle.toDouble(),
                max: VoiceConversationSettings.maxIdle.toDouble(),
                divisions: VoiceConversationSettings.maxIdle - VoiceConversationSettings.minIdle,
                label: '${_idle.round()} 秒',
                onChanged: (v) => setState(() => _idle = v),
                onChangeEnd: (_) => _emit(),
              ),
              Text('開始聽之後一直沒開口，麥克風就停下來。', style: muted),
              const SizedBox(height: 12),

              _sliderTitle('講完停頓多久算一句', '${_endSilence.toStringAsFixed(1)} 秒'),
              Slider(
                value: _endSilence,
                min: VoiceConversationSettings.minEndSilence,
                max: VoiceConversationSettings.maxEndSilence,
                divisions: ((VoiceConversationSettings.maxEndSilence -
                            VoiceConversationSettings.minEndSilence) *
                        10)
                    .round(),
                label: '${_endSilence.toStringAsFixed(1)} 秒',
                onChanged: (v) => setState(() => _endSilence = v),
                onChangeEnd: (_) => _emit(),
              ),
              Text('講到一半常被送出去，就調長一點。', style: muted),
              const Divider(height: 28),

              Text('插話關鍵字', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                _continuous
                    ? 'AI 講話時說出關鍵字，AI 會馬上停下來改聽你說；'
                        '也可以一口氣說「停一下，改成兩個」。'
                    : '要先開「連續對話」才會作用。',
                style: muted,
              ),
              const SizedBox(height: 4),
              Text(
                '請選 AI 回答裡不常出現的詞。3 個字以下要說得一字不差，'
                '常被聽錯的寫法可以另外加一個。用喇叭時 AI 的聲音也會被收到，戴耳機最準。',
                style: muted,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final k in _keywords)
                    InputChip(
                      label: Text(k),
                      onDeleted: () {
                        setState(() => _keywords.remove(k));
                        _emit();
                      },
                      deleteButtonTooltipMessage: '刪除「$k」',
                    ),
                  if (_keywords.isEmpty)
                    Text('（沒有關鍵字：不能插話）', style: muted),
                ],
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _kwCtrl,
                    decoration: const InputDecoration(
                      labelText: '新增關鍵字',
                      hintText: '例如：停一下、小隆',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _addKeyword(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  // App 主題的 FilledButton 預設滿版寬，放在 Row 裡要指定寬度
                  style: FilledButton.styleFrom(minimumSize: const Size(72, 48)),
                  onPressed: _addKeyword,
                  child: const Text('加入'),
                ),
              ]),
            ],
          ),
        ),
          ),
        ]),
      ),
    );
  }

  Widget _sliderTitle(String title, String value) => Row(children: [
        Expanded(child: Text(title, style: const TextStyle(fontSize: 16))),
        Text(value,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary)),
      ]);
}
