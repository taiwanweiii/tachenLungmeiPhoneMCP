import 'package:flutter/material.dart';
import '../../models/skill_model.dart';

/// Skill 唯讀查看頁（內建 Skill 不能直接編輯，用這頁看完整內容）
class SkillViewPage extends StatelessWidget {
  final SkillModel skill;
  final VoidCallback onCopy;

  const SkillViewPage({super.key, required this.skill, required this.onCopy});

  String get _toolScope {
    if (skill.isNoToolsMode) return '🚫 不使用工具（純對話）';
    if (skill.isAllToolsAllowed) return '🔓 全部開放（MCP Server 的所有工具）';
    return '🔧 自訂：${skill.allowedTools.join('、')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;

    Widget section(String label, Widget child) => Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: cs.outline)),
              const SizedBox(height: 6),
              child,
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('查看 Skill')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(children: [
            Text(skill.icon, style: const TextStyle(fontSize: 36)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(skill.name,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  if (skill.isBuiltIn)
                    Text('內建 Skill・唯讀',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.outline)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 24),
          if (skill.description.isNotEmpty)
            section('說明', Text(skill.description)),
          section('工具權限', Text(_toolScope)),
          section(
            '系統提示詞',
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                skill.systemPrompt.isEmpty ? '（空白）' : skill.systemPrompt,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
              ),
            ),
          ),
          Text(
            '實際送給 AI 時，系統還會在後面自動加上【可用工具清單】與【行為規範】。'
            '可在聊天訊息的「推理過程」裡看到完整內容。',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
        ],
      ),
      bottomNavigationBar: skill.isBuiltIn
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    onCopy();
                  },
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('複製並編輯'),
                ),
              ),
            )
          : null,
    );
  }
}
