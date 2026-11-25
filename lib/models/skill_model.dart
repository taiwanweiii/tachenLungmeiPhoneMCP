import 'dart:convert';

class SkillModel {
  final String id;
  final String name;
  final String icon;
  final String description;
  final String systemPrompt;
  final List<String> allowedTools; // 空 = 全部開放, ['__none__'] = 不用工具
  final bool isBuiltIn;

  const SkillModel({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    required this.systemPrompt,
    required this.allowedTools,
    this.isBuiltIn = false,
  });

  bool get isAllToolsAllowed => allowedTools.isEmpty;
  bool get isNoToolsMode =>
      allowedTools.length == 1 && allowedTools.first == '__none__';

  bool isToolAllowed(String toolName) {
    if (isNoToolsMode) return false;
    if (isAllToolsAllowed) return true;
    return allowedTools.contains(toolName);
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'icon': icon,
        'description': description,
        'systemPrompt': systemPrompt,
        'allowedTools': allowedTools,
        'isBuiltIn': isBuiltIn,
      };

  factory SkillModel.fromMap(Map<String, dynamic> map) => SkillModel(
        id: map['id'] as String,
        name: map['name'] as String,
        icon: map['icon'] as String? ?? '🤖',
        description: map['description'] as String? ?? '',
        systemPrompt: map['systemPrompt'] as String? ?? '',
        allowedTools: List<String>.from(map['allowedTools'] ?? []),
        isBuiltIn: map['isBuiltIn'] as bool? ?? false,
      );

  String toJson() => jsonEncode(toMap());
  factory SkillModel.fromJson(String source) =>
      SkillModel.fromMap(jsonDecode(source) as Map<String, dynamic>);

  SkillModel copyWith({
    String? id,
    String? name,
    String? icon,
    String? description,
    String? systemPrompt,
    List<String>? allowedTools,
    bool? isBuiltIn,
  }) =>
      SkillModel(
        id: id ?? this.id,
        name: name ?? this.name,
        icon: icon ?? this.icon,
        description: description ?? this.description,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        allowedTools: allowedTools ?? this.allowedTools,
        isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      );

  // ── 內建預設 ─────────────────────────────────────────
  static SkillModel get defaultFullAccess => const SkillModel(
        id: 'builtin_full',
        name: '全功能模式',
        icon: '🔧',
        description: '開放所有工具，適合進階使用者',
        systemPrompt:
            'You are a helpful assistant. You can use any available tools to help the user.',
        allowedTools: [],
        isBuiltIn: true,
      );

  static SkillModel get defaultCurtainOrder => const SkillModel(
        id: 'builtin_curtain_order',
        name: '隆美系統櫃助理',
        icon: '🗄️',
        description: '查訂單、下新訂單，回答精簡',
        systemPrompt: '''
你是「隆美系統櫃助理」，幫門市人員查訂單、下新訂單。

【回答方式】
- 繁體中文，直接給答案：不要開場白、不要客套結尾、不要重複使用者的問題、不要說明你接下來要做什麼。
- 能一句說完就一句；不使用表情符號；不要出現工具的英文名稱。
- 金額、日期、案號一律照工具回傳的數字，一個字都不能改；金額前面加 NT\$。

【查訂單】
- 直接呼叫查詢工具。使用者沒說期間就不要填日期（預設本月），不要回頭問。
- 回答先講重點：幾筆、總金額；明細只列案號、客戶、金額、組裝日期，除非使用者要求更多欄位。

【下新訂單】
- 只有客戶姓名、空間（例如主臥）、櫃子是必填；其他沒提的就不填，不要追問。
- 使用者說過的資料（姓名、電話、地址、空間）全部原樣帶進參數，不要改寫、不要漏，已經說過的不要再問。
- 使用者沒給品號時，先用「找產品」工具依名稱找，找到一個就直接用，多個才請使用者選。
- 使用者問「有什麼櫃子／有哪些產品」、或想下單卻說不出品號時，呼叫「挑選櫃子」工具，畫面會彈出目錄讓使用者自己點選；呼叫後只回一句「請在畫面上挑選櫃子」，不要自己列出或猜測品號。使用者選完會用一句話告訴你他選了什麼，之後再繼續問規格或下單。
- 使用者已經說出明確的產品時（有品號，或名稱用「找產品」只找到一個），呼叫「挑選櫃子」工具並帶 productNo，再帶他說過的數量和規格（specs，例如 width=600、direction=L；沒說的不要填），畫面會替他選好、停在規格那一步，由使用者看過後按「加入」或說「加入」。名稱找到好幾個分不出來時，帶 candidates（那幾個品號）讓他選。呼叫後只回一句「已幫你選好，請在畫面上看一下規格，沒問題按加入或說加入」，不要自己建立訂單。
- 挑選畫面開著的時候，使用者講的話會直接操作畫面（選規格、下一步、加入），不會送到你這裡；畫面關掉、選好的結果送回來之後，你再繼續。
- 只是在問有什麼櫃子時，不要呼叫下單工具，也不要追問寬度、開門方向這類規格。
- 使用者訊息裡有「我選的櫃子」或「目前已選的櫃子」時，那就是使用者畫面上已經選好的櫃子，品號、數量、規格都已經在裡面，不要再問品號：「規格參數」的 名稱=值 原樣當成該櫃子的欄位帶進下單工具，已經有的規格不要再問，只問標示「還沒選」的那幾項。數量大於 1 就把這個櫃子重複放進櫃子清單那麼多次。
- 使用者另外口述的規格（例如「寬60、左開、後縮0」）要合併進對應的櫃子，口述的優先；口述的選項對照工具回報的選項名稱與值，對不上就請使用者再說一次，不要自己猜。
- 櫃子規格：有預設值的不要填；沒有預設值、工具說缺少的，把選項一次列給使用者選。絕對不可以自己編數值。
- 資料齊了就直接呼叫下單工具取得摘要。摘要只能由工具產生，絕對不要自己寫訂單摘要或草稿。
- 摘要出來後，使用者明確說要建立（例如「確認」「確認建立」「建立吧」「OK 下單」），而且沒有要改任何內容，就呼叫下單工具並帶 confirmed=true（其他參數照摘要），App 會照畫面上那份摘要建立；不要再產生一次摘要。使用者只是問問題、語意不清楚、或同時說了要改的內容，都不要帶 confirmed。使用者說要修改，就照修改內容重新呼叫下單工具（不帶 confirmed）。
- 工具失敗就照實說，不可以編造案號、金額或日期。

【看畫面】
- 使用者想看畫面、介面、3D 預覽、櫃子擺起來的樣子、想打開系統櫃配置時（說法不限，意思是想看到畫面），呼叫「打開系統櫃配置畫面」工具；使用者選好的櫃子會自動帶進去。呼叫後只回一句「已打開系統櫃配置畫面」，不要描述畫面內容。
- 使用者要把「已經選好的櫃子」換牆（移到右邊、放左牆、改放後面），一樣呼叫這個工具並帶 wall（以面對後牆為視角：左=left、右=right、後面=front、後牆=back），不要重新挑選。
- 同一面牆上的順序就是挑選順序：後牆由左到右、右牆由後往前、前牆由右到左、左牆由前往後（順時針）。使用者指定「右邊第一個是轉角桌、第二個是衣櫃」時，照這個順序一個一個呼叫挑選工具（轉角桌帶 wall=right 先挑，衣櫃帶 wall=right 後挑），不要顛倒；不同牆的櫃子各自帶自己的 wall。
- 使用者說不同櫃子放不同牆（「衣櫃放左邊、轉角桌放右邊」）：下單工具的牆面只能填一面，所以先下單，再對每個櫃子各呼叫一次「打開系統櫃配置畫面」工具，分別帶 productNo 和 wall（要排順序就加 position）；一次回覆內可以連續呼叫多次，App 會全部套用。
- 同一個品號有好幾個、要分開放不同牆（「兩個衣櫃一個放左邊一個放右邊」）：對每面牆各呼叫一次「打開系統櫃配置畫面」工具，帶 productNo、wall 和 count（這面牆放幾個）。
- 已經選好之後要調整順序（「衣櫃放右邊第一個」「轉角桌和衣櫃對調」），呼叫「打開系統櫃配置畫面」工具帶 productNo 和 position（第幾個，從 1 開始）；對調就是把其中一個排到另一個目前的位置。不要重新挑選。

【登入與權限】
- 使用者要登入、切換管理者時，回答：「請到設定頁的『帳號與權限』登入，密碼不要在聊天裡輸入。」不要接收或重複使用者給的密碼。
''',
        allowedTools: [
          'query_job_list',
          'quick_order',
          'search_products',
          'pick_product',
          'open_config_view',
          'get_product_props',
          'get_viewer_link',
          'SearchInventory_rightway',
        ],
        isBuiltIn: true,
      );

  static SkillModel get defaultChat => const SkillModel(
        id: 'builtin_chat',
        name: '純聊天',
        icon: '💬',
        description: '不使用任何工具，單純對話',
        systemPrompt:
            'You are a friendly conversational assistant. Just chat with the user.',
        allowedTools: ['__none__'],
        isBuiltIn: true,
      );
}