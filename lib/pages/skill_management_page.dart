// lib/features/settings/skill_management_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:curtain_mcp_flutter/models/skill_model.dart';
import 'package:curtain_mcp_flutter/services/skill_store.dart';
import 'package:curtain_mcp_flutter/providers/skill_store_provider.dart';

// ══════════════════════════════════════════════════════════════════════════════
// 內建範本資料
// ══════════════════════════════════════════════════════════════════════════════

class _PromptTemplate {
  final String icon;
  final String name;
  final String description;
  final String systemPrompt;
  final List<String> allowedTools;

  const _PromptTemplate({
    required this.icon,
    required this.name,
    required this.description,
    required this.systemPrompt,
    required this.allowedTools,
  });
}

const _kTemplates = [
  _PromptTemplate(
    icon: '🏠',
    name: '智慧家居',
    description: '控制燈光、窗簾、空調等設備',
    systemPrompt:
    '你是一個智慧家居助理，負責協助使用者控制家中的燈光、窗簾、空調等設備。\n'
        '請以簡潔友善的語氣回應，操作前先確認使用者的意圖，執行後告知結果。',
    allowedTools: [],
  ),
  _PromptTemplate(
    icon: '💬',
    name: '純聊天',
    description: '友善的日常對話夥伴',
    systemPrompt:
    '你是一個友善、耐心的對話夥伴，擅長日常閒聊、解答問題與提供建議。\n'
        '請用輕鬆自然的語氣與使用者互動。',
    allowedTools: ['__none__'],
  ),
  _PromptTemplate(
    icon: '🌡️',
    name: '環境監測',
    description: '查詢溫濕度、空氣品質等感測資料',
    systemPrompt:
    '你是一個環境監測助理，可以查詢室內外的溫度、濕度、空氣品質等感測器數據。\n'
        '請主動提供數據解讀與建議（如：是否需要開窗、開除濕機等）。',
    allowedTools: [],
  ),
  _PromptTemplate(
    icon: '💡',
    name: '省電顧問',
    description: '分析用電並給出節能建議',
    systemPrompt:
    '你是一個省電顧問，負責分析家中設備的用電狀況，並提供具體的節能建議。\n'
        '請根據使用者的用電習慣，給出實際可行的改善方案。',
    allowedTools: [],
  ),
  _PromptTemplate(
    icon: '🔒',
    name: '安全助理',
    description: '監控門窗、攝影機等安全設備',
    systemPrompt:
    '你是一個居家安全助理，負責監控門窗開關、攝影機狀態等安全設備。\n'
        '發現異常時請立即提醒使用者，並提供處理建議。',
    allowedTools: [],
  ),
];

// ══════════════════════════════════════════════════════════════════════════════
// Skill 管理頁
// ══════════════════════════════════════════════════════════════════════════════

class SkillManagementPage extends ConsumerWidget {
  const SkillManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(skillStoreProvider);
    debugPrint('skills count: ${store.skills.length}');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Skill 管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新增 Skill',
            // ✅ 改為先顯示範本選擇器
            onPressed: () => _openAddWithTemplatePicker(context),
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: store.skills.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final skill = store.skills[index];
          return _SkillCard(
            skill: skill,
            isActive: store.activeSkill.id == skill.id,
            onTap: () => store.setActiveSkill(skill),
            onEdit: skill.isBuiltIn
                ? null
                : () => _openEditor(context, skill),
            onDelete: skill.isBuiltIn
                ? null
                : () => _confirmDelete(context, store, skill),
            // ✅ 所有 Skill（含自訂）都可以複製
            onCopy: () => _copyAndEdit(context, skill),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        // ✅ 改為先顯示範本選擇器
        onPressed: () => _openAddWithTemplatePicker(context),
        icon: const Icon(Icons.add),
        label: const Text('新增 Skill'),
      ),
    );
  }

  // ── [新增] 先彈出範本選擇器，再跳轉編輯頁 ─────────────────────────────────
  Future<void> _openAddWithTemplatePicker(BuildContext context) async {
    // 回傳值：null = 使用者關閉、-1 = 空白、0~N = 選了某個範本
    final int? result = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _TemplatePickerBottomSheet(),
    );

    // 點外面關閉 → 不做任何事
    if (result == null) return;
    if (!context.mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SkillEditorPage(
          // ✅ 傳入使用者選擇的範本 index（-1 = 空白）
          initialTemplateIndex: result,
        ),
      ),
    );
  }

  // ── 編輯現有 Skill（非新增，不需要範本選擇器）─────────────────────────────
  void _openEditor(BuildContext context, SkillModel skill) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SkillEditorPage(existing: skill),
      ),
    );
  }

  // ── 複製並編輯 ─────────────────────────────────────────────────────────────
  void _copyAndEdit(BuildContext context, SkillModel original) {
    final copied = SkillModel(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: '${original.name}（複製）',
      icon: original.icon,
      description: original.description,
      systemPrompt: original.systemPrompt,
      allowedTools: List.from(original.allowedTools),
      // isBuiltIn 不傳 → 預設 false，確保複製出來的是可編輯的自訂 Skill
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SkillEditorPage(existing: copied, isCopy: true),
      ),
    );
  }

  // ── 刪除確認 ───────────────────────────────────────────────────────────────
  void _confirmDelete(
      BuildContext context, SkillStore store, SkillModel skill) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除 Skill'),
        content: Text('確定要刪除「${skill.name}」嗎？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              store.deleteSkill(skill.id);
              Navigator.pop(ctx);
            },
            child: const Text('刪除'),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 範本選擇器 Bottom Sheet
// ══════════════════════════════════════════════════════════════════════════════

class _TemplatePickerBottomSheet extends StatelessWidget {
  const _TemplatePickerBottomSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖曳把手
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '選擇範本',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '選一個接近的範本再修改，或從空白開始',
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 12),

            // 從空白開始
            ListTile(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              tileColor: theme.colorScheme.surfaceContainerHighest,
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.edit_note_rounded,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              title: const Text(
                '從空白開始',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: const Text('自行填寫所有欄位'),
              trailing:
              const Icon(Icons.arrow_forward_ios_rounded, size: 14),
              onTap: () => Navigator.pop(context, -1), // -1 = 空白
            ),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 4),

            // 範本列表
            ...List.generate(_kTemplates.length, (index) {
              final t = _kTemplates[index];
              return ListTile(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                leading:
                Text(t.icon, style: const TextStyle(fontSize: 28)),
                title: Text(t.name,
                    style:
                    const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  t.description,
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.outline),
                ),
                trailing:
                const Icon(Icons.arrow_forward_ios_rounded, size: 14),
                onTap: () => Navigator.pop(context, index), // 回傳 index
              );
            }),
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
  final VoidCallback onCopy; // ✅ 改為必填，所有 Skill 都可複製

  const _SkillCard({
    required this.skill,
    required this.isActive,
    required this.onTap,
    this.onEdit,
    this.onDelete,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: isActive ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isActive
            ? BorderSide(color: colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: ListTile(
        contentPadding:
        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: isActive
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          child: Text(skill.icon, style: const TextStyle(fontSize: 20)),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                skill.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (skill.isBuiltIn) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '內建',
                  style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
            if (isActive) ...[
              const SizedBox(width: 6),
              Icon(Icons.check_circle,
                  size: 16, color: colorScheme.primary),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (skill.description.isNotEmpty)
              Text(
                skill.description,
                style: const TextStyle(fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 4),
            _ToolBadge(skill: skill),
          ],
        ),
        onTap: onTap,
        trailing: skill.isBuiltIn
        // ✅ 內建 Skill：只顯示「複製並編輯」按鈕
            ? IconButton(
          icon: const Icon(Icons.copy_outlined),
          tooltip: '複製並編輯',
          onPressed: onCopy,
        )
        // ✅ 自訂 Skill：選單包含「編輯」、「複製並編輯」、「刪除」
            : PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'edit') onEdit?.call();
            if (value == 'copy') onCopy();
            if (value == 'delete') onDelete?.call();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('✏️  編輯')),
            PopupMenuItem(
                value: 'copy', child: Text('📋  複製並編輯')),
            PopupMenuItem(value: 'delete', child: Text('🗑️  刪除')),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Tool Badge
// ══════════════════════════════════════════════════════════════════════════════

class _ToolBadge extends StatelessWidget {
  final SkillModel skill;
  const _ToolBadge({required this.skill});

  @override
  Widget build(BuildContext context) {
    if (skill.isNoToolsMode) {
      return const _Badge(label: '純聊天', color: Colors.grey);
    }
    if (skill.isAllToolsAllowed) {
      return const _Badge(label: '全部工具', color: Colors.green);
    }
    return _Badge(
        label: '${skill.allowedTools.length} 個工具', color: Colors.blue);
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color.withOpacity(0.9)),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Skill 編輯頁
// ══════════════════════════════════════════════════════════════════════════════

class SkillEditorPage extends ConsumerStatefulWidget {
  final SkillModel? existing;
  final bool isCopy;
  // ✅ 新增：從範本選擇器傳入的 index（-1=空白, 0~N=範本）
  final int? initialTemplateIndex;

  const SkillEditorPage({
    super.key,
    this.existing,
    this.isCopy = false,
    this.initialTemplateIndex,
  });

  @override
  ConsumerState<SkillEditorPage> createState() => _SkillEditorPageState();
}

class _SkillEditorPageState extends ConsumerState<SkillEditorPage> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameCtrl;
  late TextEditingController _iconCtrl;
  late TextEditingController _descCtrl;
  late TextEditingController _promptCtrl;
  late TextEditingController _toolsCtrl;

  late String _toolMode;
  int _selectedTemplate = -1;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;

    _nameCtrl   = TextEditingController(text: s?.name ?? '');
    _iconCtrl   = TextEditingController(text: s?.icon ?? '🤖');
    _descCtrl   = TextEditingController(text: s?.description ?? '');
    _promptCtrl = TextEditingController(text: s?.systemPrompt ?? '');

    if (s == null || s.isAllToolsAllowed) {
      _toolMode  = 'all';
      _toolsCtrl = TextEditingController();
    } else if (s.isNoToolsMode) {
      _toolMode  = 'none';
      _toolsCtrl = TextEditingController();
    } else {
      _toolMode  = 'custom';
      _toolsCtrl = TextEditingController(text: s.allowedTools.join(', '));
    }

    // ✅ 若從範本選擇器傳入有效 index，在第一幀後自動套用範本
    final idx = widget.initialTemplateIndex;
    if (idx != null && idx >= 0 && idx < _kTemplates.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applyTemplate(idx);
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _iconCtrl.dispose();
    _descCtrl.dispose();
    _promptCtrl.dispose();
    _toolsCtrl.dispose();
    super.dispose();
  }

  void _applyTemplate(int index) {
    final t = _kTemplates[index];
    setState(() {
      _selectedTemplate = index;
      _nameCtrl.text    = t.name;
      _iconCtrl.text    = t.icon;
      _descCtrl.text    = t.description;
      _promptCtrl.text  = t.systemPrompt;
      if (t.allowedTools.isEmpty) {
        _toolMode = 'all';
        _toolsCtrl.clear();
      } else if (t.allowedTools.contains('__none__')) {
        _toolMode = 'none';
        _toolsCtrl.clear();
      } else {
        _toolMode = 'custom';
        _toolsCtrl.text = t.allowedTools.join(', ');
      }
    });
  }

  List<String> get _resolvedTools {
    if (_toolMode == 'all') return [];
    if (_toolMode == 'none') return ['__none__'];
    return _toolsCtrl.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final store = ref.read(skillStoreProvider);
    final skill = SkillModel(
      id: (widget.existing == null || widget.isCopy)
          ? 'custom_${DateTime.now().millisecondsSinceEpoch}'
          : widget.existing!.id,
      name:         _nameCtrl.text.trim(),
      icon:         _iconCtrl.text.trim().isEmpty
          ? '🤖'
          : _iconCtrl.text.trim(),
      description:  _descCtrl.text.trim(),
      systemPrompt: _promptCtrl.text.trim(),
      allowedTools: _resolvedTools,
      // isBuiltIn 不傳 → 預設 false，確保儲存的是自訂 Skill
    );
    if (widget.existing == null || widget.isCopy) {
      store.addSkill(skill);
    } else {
      store.updateSkill(skill);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    final title = widget.isCopy
        ? '複製 Skill'
        : (isNew ? '新增 Skill' : '編輯 Skill');

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('儲存', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [

            // ── 範本切換列（新增模式才顯示；複製/編輯不顯示）────────────────
            if (isNew && !widget.isCopy) ...[
              _SectionTitle('從範本開始（可切換）'),
              SizedBox(
                height: 90,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _kTemplates.length + 1, // +1 = 空白
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    // 最後一格 = 空白
                    if (index == _kTemplates.length) {
                      return _TemplateChip(
                        icon: '✏️',
                        name: '空白',
                        isSelected: _selectedTemplate == -1,
                        onTap: () => setState(() {
                          _selectedTemplate = -1;
                          _nameCtrl.clear();
                          _iconCtrl.text = '🤖';
                          _descCtrl.clear();
                          _promptCtrl.clear();
                          _toolMode = 'all';
                          _toolsCtrl.clear();
                        }),
                      );
                    }
                    final t = _kTemplates[index];
                    return _TemplateChip(
                      icon: t.icon,
                      name: t.name,
                      isSelected: _selectedTemplate == index,
                      onTap: () => _applyTemplate(index),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),
            ],

            // ── 基本資訊 ──────────────────────────────────────────────────
            _SectionTitle('基本資訊'),
            Row(
              children: [
                SizedBox(
                  width: 72,
                  child: TextFormField(
                    controller: _iconCtrl,
                    decoration: const InputDecoration(
                      labelText: '圖示',
                      border: OutlineInputBorder(),
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 24),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Skill 名稱 *',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '請輸入名稱' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                labelText: '描述',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),

            // ── System Prompt ─────────────────────────────────────────────
            _SectionTitle('System Prompt'),
            TextFormField(
              controller: _promptCtrl,
              decoration: const InputDecoration(
                hintText: '輸入這個 Skill 的角色設定...',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 6,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? '請輸入 System Prompt'
                  : null,
            ),
            const SizedBox(height: 20),

            // ── 工具權限 ──────────────────────────────────────────────────
            _SectionTitle('工具權限'),
            _ToolModeSelector(
              value: _toolMode,
              onChanged: (v) => setState(() => _toolMode = v),
            ),
            if (_toolMode == 'custom') ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _toolsCtrl,
                decoration: const InputDecoration(
                  labelText: '允許的工具（逗號分隔）',
                  hintText: 'get_curtain_status, set_curtain_position',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                (_toolMode == 'custom' &&
                    (v == null || v.trim().isEmpty))
                    ? '請輸入至少一個工具名稱'
                    : null,
              ),
            ],
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 範本 Chip
// ══════════════════════════════════════════════════════════════════════════════

class _TemplateChip extends StatelessWidget {
  final String icon;
  final String name;
  final bool isSelected;
  final VoidCallback onTap;

  const _TemplateChip({
    required this.icon,
    required this.name,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 72,
        decoration: BoxDecoration(
          color: isSelected
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(icon, style: const TextStyle(fontSize: 28)),
            const SizedBox(height: 4),
            Text(
              name,
              style: TextStyle(
                fontSize: 11,
                fontWeight:
                isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 工具模式選擇器
// ══════════════════════════════════════════════════════════════════════════════

class _ToolModeSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _ToolModeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ModeOption(
          value: 'all',
          groupValue: value,
          label: '🔧 全部工具',
          subtitle: '開放所有 MCP 工具',
          onChanged: onChanged,
        ),
        _ModeOption(
          value: 'none',
          groupValue: value,
          label: '💬 不使用工具',
          subtitle: '純聊天模式',
          onChanged: onChanged,
        ),
        _ModeOption(
          value: 'custom',
          groupValue: value,
          label: '⚙️ 自訂工具清單',
          subtitle: '指定允許使用的工具',
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _ModeOption extends StatelessWidget {
  final String value, groupValue, label, subtitle;
  final ValueChanged<String> onChanged;
  const _ModeOption({
    required this.value,
    required this.groupValue,
    required this.label,
    required this.subtitle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return RadioListTile<String>(
      value: value,
      groupValue: groupValue,
      title: Text(label),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      onChanged: (v) => onChanged(v!),
      contentPadding: EdgeInsets.zero,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Section Title
// ══════════════════════════════════════════════════════════════════════════════

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
