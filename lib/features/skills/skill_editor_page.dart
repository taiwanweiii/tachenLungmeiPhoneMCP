// lib/features/skills/skill_editor_page.dart
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:uuid/uuid.dart';
import '../../models/skill_model.dart';
import '../../services/skill_store.dart';
import '../../services/mcp_client_service.dart';

// ══════════════════════════════════════════════════════════════════════════════
// 範本資料（與 skill_select_page 共用同一份）
// ══════════════════════════════════════════════════════════════════════════════

class SkillTemplate {
  final String icon;
  final String name;
  final String description;
  final String systemPrompt;
  final List<String> allowedTools; // [] = 全部, ['__none__'] = 不使用

  const SkillTemplate({
    required this.icon,
    required this.name,
    required this.description,
    required this.systemPrompt,
    required this.allowedTools,
  });
}

const kSkillTemplates = [
  SkillTemplate(
    icon: '🏠',
    name: '智慧家居',
    description: '控制燈光、窗簾、空調等設備',
    systemPrompt:
    '你是一個智慧家居助理，負責協助使用者控制家中的燈光、窗簾、空調等設備。\n'
        '請以簡潔友善的語氣回應，操作前先確認使用者的意圖，執行後告知結果。',
    allowedTools: [],
  ),
  SkillTemplate(
    icon: '💬',
    name: '純聊天',
    description: '友善的日常對話夥伴，不使用任何工具',
    systemPrompt:
    '你是一個友善、耐心的對話夥伴，擅長日常閒聊、解答問題與提供建議。\n'
        '請用輕鬆自然的語氣與使用者互動。',
    allowedTools: ['__none__'],
  ),
  SkillTemplate(
    icon: '🌡️',
    name: '環境監測',
    description: '查詢溫濕度、空氣品質等感測資料',
    systemPrompt:
    '你是一個環境監測助理，可以查詢室內外的溫度、濕度、空氣品質等感測器數據。\n'
        '請主動提供數據解讀與建議（如：是否需要開窗、開除濕機等）。',
    allowedTools: [],
  ),
  SkillTemplate(
    icon: '💡',
    name: '省電顧問',
    description: '分析用電並給出節能建議',
    systemPrompt:
    '你是一個省電顧問，負責分析家中設備的用電狀況，並提供具體的節能建議。\n'
        '請根據使用者的用電習慣，給出實際可行的改善方案。',
    allowedTools: [],
  ),
  SkillTemplate(
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
// SkillEditorPage
// ══════════════════════════════════════════════════════════════════════════════

class SkillEditorPage extends StatefulWidget {
  final SkillModel? skill;
  // ✅ 新增：從範本選擇器傳入的範本（null = 空白）
  final SkillTemplate? initialTemplate;

  const SkillEditorPage({
    super.key,
    this.skill,
    this.initialTemplate,  // ← 新增
  });

  @override
  State<SkillEditorPage> createState() => _SkillEditorPageState();
}

class _SkillEditorPageState extends State<SkillEditorPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _iconCtrl;
  late TextEditingController _descCtrl;
  late TextEditingController _promptCtrl;

  List<String> _availableTools = [];
  Set<String>  _selectedTools  = {};
  bool _allTools     = true;
  bool _noTools      = false;
  bool _loadingTools = false;

  @override
  void initState() {
    super.initState();
    final s = widget.skill;
    final t = widget.initialTemplate; // ✅ 範本優先

    // ✅ 若有範本，用範本預填；否則用現有 skill 或空白
    _nameCtrl   = TextEditingController(text: t?.name   ?? s?.name   ?? '');
    _iconCtrl   = TextEditingController(text: t?.icon   ?? s?.icon   ?? '🤖');
    _descCtrl   = TextEditingController(text: t?.description ?? s?.description ?? '');
    _promptCtrl = TextEditingController(text: t?.systemPrompt ?? s?.systemPrompt ?? '');

    // ✅ 工具模式：範本 > 現有 skill > 預設全部
    final tools = t?.allowedTools ?? s?.allowedTools;
    if (tools == null || tools.isEmpty) {
      _allTools = true;
      _noTools  = false;
    } else if (tools.contains('__none__')) {
      _allTools = false;
      _noTools  = true;
    } else {
      _allTools      = false;
      _noTools       = false;
      _selectedTools = Set.from(tools);
    }

    _fetchTools();
  }

  Future<void> _fetchTools() async {
    setState(() => _loadingTools = true);
    try {
      final mcp   = GetIt.instance<McpClientService>();
      final tools = await mcp.listToolsAsync();
      setState(() {
        _availableTools = tools.map((t) => t.name).toList();
      });
    } catch (_) {
      // MCP Server 離線，保留空清單
    } finally {
      setState(() => _loadingTools = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final List<String> allowedTools;
    if (_allTools) {
      allowedTools = [];
    } else if (_noTools) {
      allowedTools = ['__none__'];
    } else {
      allowedTools = _selectedTools.toList();
    }

    final skill = SkillModel(
      id:           widget.skill?.id ?? const Uuid().v4(),
      name:         _nameCtrl.text.trim(),
      icon:         _iconCtrl.text.trim().isEmpty ? '🤖' : _iconCtrl.text.trim(),
      description:  _descCtrl.text.trim(),
      systemPrompt: _promptCtrl.text.trim(),
      allowedTools: allowedTools,
    );

    final store = GetIt.instance<SkillStore>();
    if (widget.skill == null) {
      await store.addSkill(skill);
    } else {
      await store.updateSkill(skill);
    }

    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _iconCtrl.dispose();
    _descCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  String get _toolModeValue =>
      _allTools ? 'all' : (_noTools ? 'none' : 'custom');

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.skill != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? '編輯 Skill' : '新增 Skill'),
        actions: [
          TextButton(onPressed: _save, child: const Text('儲存')),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── 基本資訊 ──────────────────────────────
            Row(children: [
              SizedBox(
                width: 72,
                child: TextFormField(
                  controller: _iconCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Icon',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 24),
                  textAlign: TextAlign.center,
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
            ]),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                labelText: '說明',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _promptCtrl,
              decoration: const InputDecoration(
                labelText: 'System Prompt *',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 5,
              validator: (v) =>
              (v == null || v.trim().isEmpty)
                  ? '請輸入 System Prompt'
                  : null,
            ),
            const SizedBox(height: 20),

            // ── 工具設定 ──────────────────────────────
            const Text('工具權限',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            RadioListTile<String>(
              title: const Text('🔓 全部開放'),
              subtitle: const Text('允許使用 MCP Server 所有工具'),
              value: 'all',
              groupValue: _toolModeValue,
              onChanged: (_) => setState(() {
                _allTools = true;
                _noTools  = false;
              }),
            ),
            RadioListTile<String>(
              title: const Text('🚫 不使用工具'),
              subtitle: const Text('純對話，不呼叫任何工具'),
              value: 'none',
              groupValue: _toolModeValue,
              onChanged: (_) => setState(() {
                _allTools = false;
                _noTools  = true;
              }),
            ),
            RadioListTile<String>(
              title: const Text('🔧 自訂工具'),
              subtitle: const Text('從 MCP Server 工具清單中勾選'),
              value: 'custom',
              groupValue: _toolModeValue,
              onChanged: (_) => setState(() {
                _allTools = false;
                _noTools  = false;
              }),
            ),

            // ── 工具勾選清單 ──────────────────────────
            if (!_allTools && !_noTools) ...[
              const SizedBox(height: 8),
              if (_loadingTools)
                const Center(child: CircularProgressIndicator())
              else if (_availableTools.isEmpty)
                ListTile(
                  leading: const Icon(Icons.warning_amber, color: Colors.orange),
                  title: const Text('無法取得工具清單'),
                  subtitle: const Text('請確認 MCP Server 已連線'),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _fetchTools,
                  ),
                )
              else
                ..._availableTools.map(
                      (tool) => CheckboxListTile(
                    title: Text(tool),
                    value: _selectedTools.contains(tool),
                    onChanged: (checked) => setState(() {
                      if (checked == true) {
                        _selectedTools.add(tool);
                      } else {
                        _selectedTools.remove(tool);
                      }
                    }),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
