// lib/features/skills/skill_select_page.dart
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import '../../models/skill_model.dart';
import '../../services/skill_store.dart';
import 'skill_editor_page.dart'; // ← kSkillTemplates 也從這裡來
import 'skill_view_page.dart';

/// 完整 Skill 管理頁（從設定進入）
class SkillSelectPage extends StatefulWidget {
  const SkillSelectPage({super.key});

  @override
  State<SkillSelectPage> createState() => _SkillSelectPageState();
}

class _SkillSelectPageState extends State<SkillSelectPage> {
  late final SkillStore _store;

  @override
  void initState() {
    super.initState();
    _store = GetIt.instance<SkillStore>();
    _store.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _store.removeListener(_onChanged);
    super.dispose();
  }

  // ✅ 點「+」先彈出範本選擇器
  Future<void> _openAddWithTemplatePicker() async {
    final result = await showModalBottomSheet<SkillTemplate?>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _TemplatePickerSheet(),
    );

    // null = 使用者關閉（沒選）
    // result 是 SkillTemplate 或 _kBlankSentinel（空白）
    if (!mounted) return;

    // 使用者點了「從空白開始」時回傳 _kBlankSentinel，其他回傳實際範本
    if (result == _kBlankSentinel) {
      // 空白，不預填
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const SkillEditorPage()));
    } else if (result != null) {
      // 選了某個範本
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SkillEditorPage(initialTemplate: result),
        ),
      );
    }
    // result == null → 使用者關閉 Bottom Sheet，不動作
  }

  // ✅ 複製並編輯
  void _copyAndEdit(SkillModel original) {
    final copied = SkillModel(
      id:           'custom_${DateTime.now().millisecondsSinceEpoch}',
      name:         '${original.name}（複製）',
      icon:         original.icon,
      description:  original.description,
      systemPrompt: original.systemPrompt,
      allowedTools: List.from(original.allowedTools),
      // isBuiltIn 預設 false
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SkillEditorPage(skill: copied),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('助理模式管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新增 Skill',
            onPressed: _openAddWithTemplatePicker, // ✅ 改這裡
          ),
        ],
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.1,
        ),
        itemCount: _store.skills.length,
        itemBuilder: (context, index) {
          final skill    = _store.skills[index];
          final isActive = skill.id == _store.activeSkill.id;
          return _SkillCard(
            skill: skill,
            isActive: isActive,
            onTap: () async {
              await _store.setActiveSkill(skill);
              if (context.mounted) Navigator.pop(context);
            },
            onEdit: skill.isBuiltIn
                ? null
                : () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SkillEditorPage(skill: skill),
              ),
            ),
            onDelete: skill.isBuiltIn
                ? null
                : () => _confirmDelete(context, skill),
            onCopy: () => _copyAndEdit(skill), // ✅ 新增
            onView: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SkillViewPage(
                  skill: skill,
                  onCopy: () => _copyAndEdit(skill),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, SkillModel skill) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded,
            size: 36, color: Colors.red),
        title: const Text('刪除 Skill'),
        content: Text('確定要刪除「${skill.icon} ${skill.name}」嗎？\n此操作無法復原。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _store.deleteSkill(skill.id);
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 用來代表「從空白開始」的哨兵物件
// ══════════════════════════════════════════════════════════════════════════════

final _kBlankSentinel = SkillTemplate(
  icon: '', name: '', description: '', systemPrompt: '', allowedTools: [],
);

// ══════════════════════════════════════════════════════════════════════════════
// 範本選擇器 Bottom Sheet
// ══════════════════════════════════════════════════════════════════════════════

class _TemplatePickerSheet extends StatelessWidget {
  const _TemplatePickerSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖曳把手
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            Text('選擇範本',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('選一個接近的範本再修改，或從空白開始',
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.outline)),
            const SizedBox(height: 12),

            // 從空白開始
            ListTile(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              tileColor: theme.colorScheme.surfaceContainerHighest,
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(Icons.edit_note_rounded,
                    color: theme.colorScheme.onPrimaryContainer),
              ),
              title: const Text('從空白開始',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('自行填寫所有欄位'),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
              onTap: () => Navigator.pop(context, _kBlankSentinel),
            ),
            const Divider(height: 20),

            // 範本列表
            ...kSkillTemplates.map((t) => ListTile(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              leading: Text(t.icon,
                  style: const TextStyle(fontSize: 28)),
              title: Text(t.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(t.description,
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.outline)),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
              onTap: () => Navigator.pop(context, t),
            )),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Skill 卡片
// ══════════════════════════════════════════════════════════════════════════════

class _SkillCard extends StatelessWidget {
  final SkillModel skill;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback onCopy; // ✅ 新增
  final VoidCallback onView; // 內建 Skill 唯讀查看

  const _SkillCard({
    required this.skill,
    required this.isActive,
    required this.onTap,
    this.onEdit,
    this.onDelete,
    required this.onCopy, // ✅ 新增
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isActive ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: isActive
              ? Border.all(color: cs.primary, width: 2)
              : Border.all(color: cs.outlineVariant),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 頂部：icon + 操作按鈕 ──────────────────
            Row(children: [
              Text(skill.icon, style: const TextStyle(fontSize: 26)),
              const Spacer(),
              if (isActive)
                Icon(Icons.check_circle_rounded,
                    color: cs.primary, size: 18),

              // ✅ 內建 Skill：查看 + 複製
              if (skill.isBuiltIn) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: '查看內容',
                  child: GestureDetector(
                    onTap: onView,
                    child: Icon(Icons.visibility_outlined,
                        size: 16, color: cs.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: onCopy,
                  child: Icon(Icons.copy_outlined,
                      size: 16, color: cs.onSurfaceVariant),
                ),
              ],

              // ✅ 自訂 Skill：編輯 + 複製 + 刪除
              if (!skill.isBuiltIn) ...[
                if (onEdit != null) ...[
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: onEdit,
                    child: Icon(Icons.edit_outlined,
                        size: 16, color: cs.onSurfaceVariant),
                  ),
                ],
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: onCopy,
                  child: Icon(Icons.copy_outlined,
                      size: 16, color: cs.onSurfaceVariant),
                ),
                if (onDelete != null) ...[
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: onDelete,
                    child: const Icon(Icons.delete_outline,
                        size: 16, color: Colors.red),
                  ),
                ],
              ],
            ]),
            const SizedBox(height: 8),

            // ── 名稱 ──────────────────────────────────
            Text(
              skill.name,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: isActive ? cs.onPrimaryContainer : cs.onSurface,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),

            // ── 說明 ──────────────────────────────────
            Expanded(
              child: Text(
                skill.description.isEmpty ? '（無說明）' : skill.description,
                style: TextStyle(
                  fontSize: 11,
                  color: isActive
                      ? cs.onPrimaryContainer.withOpacity(0.75)
                      : cs.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 6),

            // ── 工具標籤 ──────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isActive
                    ? cs.primary.withOpacity(0.15)
                    : cs.outline.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                skill.isAllToolsAllowed
                    ? '🔓 全部工具'
                    : skill.isNoToolsMode
                    ? '🚫 不使用工具'
                    : '🔧 ${skill.allowedTools.length} 個工具',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: isActive ? cs.primary : cs.outline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
