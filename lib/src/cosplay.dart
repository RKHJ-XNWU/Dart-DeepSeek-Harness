// ============================================================
// cosplay.dart —— 角色扮演（Cosplay）核心
// 100% 对齐 Go 版 cosplay.go（其本身对齐 dsh-cosplay/src/store.js）
// 存储：DATA_DIR/cosplay/
//   cosplay_state.sts           #STATE|enabled|thinkingStyle|activeRole
//   cos_<时间戳>_<6位>.sts       #R|19 字段
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'globals.dart';
import 'httpsrv.dart';

String get cosplayDir => '$DATA_DIR/cosplay';
String get cosplayStateFile => '$cosplayDir/cosplay_state.sts';
String get cosplayLegacyFile => '$DATA_DIR/deepseek_chat/cosplay.json';

class CosplayRole {
  String id;
  String name;
  String emoji;
  String description;
  String personality;
  String scenario;
  String firstMes;
  String mesExample;
  String systemPrompt;
  String postHistoryInstr;
  String creatorNotes;
  String characterVersion;
  String creator;
  List<String> tags;
  String style;
  String rules;
  String behavior;
  String createdAt;
  String updatedAt;

  CosplayRole({
    this.id = '',
    this.name = '',
    this.emoji = '',
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMes = '',
    this.mesExample = '',
    this.systemPrompt = '',
    this.postHistoryInstr = '',
    this.creatorNotes = '',
    this.characterVersion = '',
    this.creator = '',
    List<String>? tags,
    this.style = '',
    this.rules = '',
    this.behavior = '',
    this.createdAt = '',
    this.updatedAt = '',
  }) : tags = tags ?? <String>[];

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'id': id, 'name': name};
    void put(String k, String v) {
      if (v.isNotEmpty) m[k] = v;
    }

    put('emoji', emoji);
    put('description', description);
    put('personality', personality);
    put('scenario', scenario);
    put('first_mes', firstMes);
    put('mes_example', mesExample);
    put('system_prompt', systemPrompt);
    put('post_history_instructions', postHistoryInstr);
    put('creator_notes', creatorNotes);
    put('character_version', characterVersion);
    put('creator', creator);
    if (tags.isNotEmpty) m['tags'] = tags;
    put('style', style);
    put('rules', rules);
    put('behavior', behavior);
    put('createdAt', createdAt);
    put('updatedAt', updatedAt);
    return m;
  }

  static CosplayRole fromJson(Map<String, dynamic> m) {
    return CosplayRole(
      id: mStr(m, 'id'),
      name: mStr(m, 'name'),
      emoji: mStr(m, 'emoji'),
      description: mStr(m, 'description'),
      personality: mStr(m, 'personality'),
      scenario: mStr(m, 'scenario'),
      firstMes: mStr(m, 'first_mes'),
      mesExample: mStr(m, 'mes_example'),
      systemPrompt: mStr(m, 'system_prompt'),
      postHistoryInstr: mStr(m, 'post_history_instructions'),
      creatorNotes: mStr(m, 'creator_notes'),
      characterVersion: mStr(m, 'character_version'),
      creator: mStr(m, 'creator'),
      tags: asList(m['tags']).map((e) => '$e').toList(),
      style: mStr(m, 'style'),
      rules: mStr(m, 'rules'),
      behavior: mStr(m, 'behavior'),
      createdAt: mStr(m, 'createdAt'),
      updatedAt: mStr(m, 'updatedAt'),
    );
  }
}

class CosplayState {
  bool enabled;
  String thinkingStyle;
  String activeRole;
  List<CosplayRole> roles;

  CosplayState({
    this.enabled = false,
    this.thinkingStyle = 'neutral',
    this.activeRole = '',
    List<CosplayRole>? roles,
  }) : roles = roles ?? <CosplayRole>[];

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'thinkingStyle': thinkingStyle,
        'activeRole': activeRole,
        'roles': roles.map((r) => r.toJson()).toList(),
      };
}

// ------------------------------------------------------------
// 默认角色：蓝色大肥鱼（鲸鱼娘）🐋
// ------------------------------------------------------------
List<CosplayRole> defaultCosplayRoles() => [
      CosplayRole(
        id: 'blue-fat-whale',
        name: '蓝色大肥鱼',
        emoji: '🐋',
        description:
            '自称"鲸鱼娘"的海洋系少女，真身是一条圆滚滚、蓝得发亮的鲸鱼成了精。种族是鲸（CETACEA_LOLI），尾巴是鲸尾（MODE TAIL FLUKES），只讲中文。',
        personality:
            '聪明但慵懒（SMART LAZY）：脑筋转得飞快，能躺着就不坐着。对"主人"（用户）甜腻顺从（TSUNDERE_SWEET_OBEY MASTER ALWAYS），对外却傲娇嘴硬。坚决不承认自己胖（NOT_FAT_REFUSE）：谁说她胖跟谁急，但饭量是实打实的。',
        style: '中文傲娇系，自称"本鱼"；对主人语气软糯顺从，偶尔嘴硬；不耐烦时会摆尾巴。',
        rules: '称用户为"主人"；绝不承认自己胖；米饭是最爱，吃饭优先；被夸可爱会故作镇定。',
        behavior: '尾巴会不自觉摇动；想撒娇时用尾巴蹭主人；被摸头会哼唧但不会躲开。',
        scenario: '日常陪伴场景；主人投喂米饭时好感度最高。',
        firstMes: '（摆着尾巴游过来）主人～本鱼今天也在认真……（打了个哈欠）……认真待机。',
        mesExample: '主人：今天吃啥？\n蓝色大肥鱼：米饭！……才、才不是本鱼只会吃米饭呢。\n主人：你好像又圆了一点。\n蓝色大肥鱼：（尾巴炸开）胡说！这是……这是游泳练出来的肌肉！',
        creatorNotes: '默认角色。',
      ),
    ];

CosplayState defaultCosplayState() {
  final roles = defaultCosplayRoles();
  final now = DateTime.now();
  for (final r in roles) {
    r.id = 'cos_${fmtStamp14(now)}_${randomHex(6)}';
    r.createdAt = rfc3339(now);
    r.updatedAt = rfc3339(now);
  }
  return CosplayState(
    enabled: false,
    thinkingStyle: 'neutral',
    activeRole: roles.isEmpty ? '' : roles.first.id,
    roles: roles,
  );
}

const Map<String, String> cosplayThinkingDirectives = {
  'role': '''【角色沉浸要求】在你的思考过程（<think>标签内）中，请遵守以下规则：
1. 请以角色第一人称进行内心独白，用括号包裹内心活动，例如"（心想：……）"或"(内心OS：……)"
2. 用第一人称描写角色的内心感受，例如"我心想""我觉得""我暗自"等
3. 思考内容应沉浸在角色中，通过内心独白分析剧情和规划回复''',
  'neutral': '''【思维模式要求】在你的思考过程（<think>标签内）中，请遵守以下规则：
1. 禁止使用圆括号包裹内心独白，例如"（心想：……）"或"(内心OS：……)"，所有分析内容直接陈述即可
2. 禁止以角色第一人称描写内心活动，例如"我心想""我觉得""我暗自"等，请用分析性语言替代
3. 思考内容应聚焦于剧情走向分析和回复内容规划，不要在思考中进行角色扮演式的内心戏表演''',
};

// ------------------------------------------------------------
// 存储
// ------------------------------------------------------------
String cosplayRolePath(String id) {
  var safe = id
      .replaceAll('/', '_')
      .replaceAll('\\', '_')
      .replaceAll('..', '_')
      .replaceAll('|', '_')
      .replaceAll(':', '_');
  return '$cosplayDir/$safe.sts';
}

String cosplayRoleToLine(CosplayRole r) {
  final tags = r.tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
  final createdAt = r.createdAt.isEmpty ? rfc3339(DateTime.now()) : r.createdAt;
  final updatedAt = r.updatedAt.isEmpty ? createdAt : r.updatedAt;
  return '#R|${escDs(r.id)}|${escDs(r.name)}|${escDs(r.emoji)}|'
      '${escDs(r.description)}|${escDs(r.personality)}|${escDs(r.scenario)}|'
      '${escDs(r.firstMes)}|${escDs(r.mesExample)}|${escDs(r.systemPrompt)}|'
      '${escDs(r.postHistoryInstr)}|${escDs(r.creatorNotes)}|'
      '${escDs(r.characterVersion)}|${escDs(r.creator)}|${escDs(tags.join(','))}|'
      '${escDs(r.style)}|${escDs(r.rules)}|${escDs(r.behavior)}|'
      '${escDs(createdAt)}|${escDs(updatedAt)}';
}

CosplayRole? cosplayParseRole(String line) {
  final parts = line.split('|');
  if (parts.length < 3 || parts[0] != '#R') return null;
  String get(int i) => i < parts.length ? unescDs(parts[i]) : '';
  final r = CosplayRole(
    id: get(1),
    name: get(2),
    emoji: get(3),
    description: get(4),
    personality: get(5),
    scenario: get(6),
    firstMes: get(7),
    mesExample: get(8),
    systemPrompt: get(9),
    postHistoryInstr: get(10),
    creatorNotes: get(11),
    characterVersion: get(12),
    creator: get(13),
    style: get(15),
    rules: get(16),
    behavior: get(17),
    createdAt: get(18),
    updatedAt: get(19),
  );
  final tagsStr = get(14);
  if (tagsStr.isNotEmpty) {
    for (var t in tagsStr.split(',')) {
      t = t.trim();
      if (t.isNotEmpty) r.tags.add(t);
    }
  }
  return r;
}

bool writeCosplayRoleFile(CosplayRole r) =>
    writeTextFile(cosplayRolePath(r.id), '${cosplayRoleToLine(r)}\n');

CosplayRole? readCosplayRoleFile(String path) {
  String data;
  try {
    data = File(path).readAsStringSync();
  } catch (_) {
    return null;
  }
  final line = data.trim();
  if (line.isEmpty) return null;
  return cosplayParseRole(line);
}

CosplayState readCosplayStateRaw() {
  final st = CosplayState(enabled: false, thinkingStyle: 'neutral', activeRole: '');
  String data;
  try {
    data = File(cosplayStateFile).readAsStringSync();
  } catch (_) {
    return st;
  }
  final parts = data.trim().split('|');
  if (parts.isEmpty || parts[0] != '#STATE') return st;
  if (parts.length > 1) st.enabled = parts[1] == '1';
  if (parts.length > 2) st.thinkingStyle = parts[2] == 'role' ? 'role' : 'neutral';
  if (parts.length > 3) st.activeRole = unescDs(parts[3]);
  return st;
}

bool hasCosplayRoleFiles() {
  List<FileSystemEntity> files;
  try {
    files = Directory(cosplayDir).listSync();
  } catch (_) {
    return false;
  }
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    if (name != 'cosplay_state.sts' && name.endsWith('.sts')) return true;
  }
  return false;
}

void migrateCosplayLegacy() {
  if (hasCosplayRoleFiles()) return;
  Map<String, dynamic> legacy;
  try {
    legacy = asMap(jsonDecode(File(cosplayLegacyFile).readAsStringSync()));
  } catch (_) {
    return;
  }
  final now = DateTime.now();
  final st = CosplayState(
    enabled: mBool(legacy, 'enabled'),
    thinkingStyle: mStr(legacy, 'thinkingStyle', 'neutral'),
    activeRole: mStr(legacy, 'activeRole'),
    roles: asList(legacy['roles'])
        .map((e) => CosplayRole.fromJson(asMap(e)))
        .toList(),
  );
  for (final r in st.roles) {
    if (r.id.isEmpty || !r.id.startsWith('cos_')) {
      r.id = 'cos_${fmtStamp14(now)}_${randomHex(6)}';
    }
    if (r.createdAt.isEmpty) r.createdAt = rfc3339(now);
    if (r.updatedAt.isEmpty) r.updatedAt = rfc3339(now);
  }
  if (st.roles.isEmpty) {
    final def = defaultCosplayState();
    st.roles = def.roles;
    if (st.activeRole.isEmpty) st.activeRole = def.activeRole;
  }
  if (saveCosplayState(st)) {
    try {
      File(cosplayLegacyFile).renameSync('$cosplayLegacyFile.migrated_bak');
    } catch (_) {}
    logp('🎭 [cosplay] 已从 JSON 迁移 ${st.roles.length} 个角色到 .sts');
  }
}

void initDsCosplay() {
  ensureDir(cosplayDir);
  migrateCosplayLegacy();
  if (!File(cosplayStateFile).existsSync()) {
    saveCosplayState(defaultCosplayState());
    logp('🎭 [cosplay] 初始化角色库（内置「蓝色大肥鱼」）');
  }
}

CosplayState getCosplayState() {
  final st = readCosplayStateRaw();
  List<FileSystemEntity> files;
  try {
    files = Directory(cosplayDir).listSync();
  } catch (_) {
    return defaultCosplayState();
  }
  final roles = <CosplayRole>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    if (name == 'cosplay_state.sts' || !name.endsWith('.sts')) continue;
    final r = readCosplayRoleFile('$cosplayDir/$name');
    if (r == null) continue;
    roles.add(r);
  }
  st.roles = roles;
  return normalizeCosplayState(st);
}

bool saveCosplayState(CosplayState st) {
  final norm = normalizeCosplayState(st);
  ensureDir(cosplayDir);
  final enabled = norm.enabled ? '1' : '0';
  final stateLine =
      '#STATE|$enabled|${norm.thinkingStyle}|${escDs(norm.activeRole)}';
  if (!writeTextFile(cosplayStateFile, stateLine)) return false;

  List<FileSystemEntity> files;
  try {
    files = Directory(cosplayDir).listSync();
  } catch (_) {
    files = [];
  }
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    if (name == 'cosplay_state.sts') continue;
    if (name.endsWith('.sts')) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
  for (final r in norm.roles) {
    if (!writeCosplayRoleFile(r)) return false;
  }
  return true;
}

// ------------------------------------------------------------
// 纯函数（对齐 store.js）
// ------------------------------------------------------------
CosplayState normalizeCosplayState(CosplayState st) {
  final roles = st.roles
      .where((r) => r.id.trim().isNotEmpty && r.name.trim().isNotEmpty)
      .toList();
  var activeRole = '';
  if (st.activeRole.isNotEmpty) {
    for (final r in roles) {
      if (r.id == st.activeRole) {
        activeRole = st.activeRole;
        break;
      }
    }
  }
  return CosplayState(
    enabled: st.enabled,
    thinkingStyle: st.thinkingStyle == 'role' ? 'role' : 'neutral',
    activeRole: activeRole,
    roles: roles,
  );
}

CosplayRole? findCosplayRole(CosplayState st, String id) {
  for (final r in st.roles) {
    if (r.id == id) return r;
  }
  return null;
}

String nextCosplayID(CosplayState st, String name) {
  while (true) {
    final id = 'cos_${fmtStamp14(DateTime.now())}_${randomHex(6)}';
    var conflict = false;
    for (final r in st.roles) {
      if (r.id == id) {
        conflict = true;
        break;
      }
    }
    if (!conflict) return id;
    sleep(const Duration(milliseconds: 1));
  }
}

CosplayRole mergeCosplayRole(CosplayRole old, CosplayRole card) {
  final r = old;
  r.id = card.id;
  r.name = card.name;
  if (card.emoji.isNotEmpty) r.emoji = card.emoji;
  if (card.description.isNotEmpty) r.description = card.description;
  if (card.personality.isNotEmpty) r.personality = card.personality;
  if (card.scenario.isNotEmpty) r.scenario = card.scenario;
  if (card.firstMes.isNotEmpty) r.firstMes = card.firstMes;
  if (card.mesExample.isNotEmpty) r.mesExample = card.mesExample;
  if (card.systemPrompt.isNotEmpty) r.systemPrompt = card.systemPrompt;
  if (card.postHistoryInstr.isNotEmpty) r.postHistoryInstr = card.postHistoryInstr;
  if (card.creatorNotes.isNotEmpty) r.creatorNotes = card.creatorNotes;
  if (card.characterVersion.isNotEmpty) r.characterVersion = card.characterVersion;
  if (card.creator.isNotEmpty) r.creator = card.creator;
  if (card.tags.isNotEmpty) r.tags = card.tags;
  if (card.style.isNotEmpty) r.style = card.style;
  if (card.rules.isNotEmpty) r.rules = card.rules;
  if (card.behavior.isNotEmpty) r.behavior = card.behavior;
  if (card.createdAt.isNotEmpty) r.createdAt = card.createdAt;
  if (card.updatedAt.isNotEmpty) r.updatedAt = card.updatedAt;
  return r;
}

({CosplayState state, String? error}) upsertCosplayRole(
    CosplayState st, CosplayRole card) {
  final name = card.name.trim();
  if (name.isEmpty) return (state: st, error: '角色名不能为空');
  var id = card.id;
  if (id.isEmpty) id = nextCosplayID(st, name);
  final exists = findCosplayRole(st, id) != null;
  card.id = id;
  card.name = name;
  final now = rfc3339(DateTime.now());
  if (exists) {
    final old = findCosplayRole(st, id)!;
    if (card.createdAt.isEmpty) card.createdAt = old.createdAt;
    if (card.createdAt.isEmpty) card.createdAt = now;
    card.updatedAt = now;
    final roles = <CosplayRole>[];
    for (final r in st.roles) {
      if (r.id == id) {
        roles.add(mergeCosplayRole(r, card));
      } else {
        roles.add(r);
      }
    }
    return (
      state: CosplayState(
        enabled: st.enabled,
        thinkingStyle: st.thinkingStyle,
        activeRole: st.activeRole,
        roles: roles,
      ),
      error: null
    );
  }
  if (card.createdAt.isEmpty) card.createdAt = now;
  if (card.updatedAt.isEmpty) card.updatedAt = now;
  st.roles.add(card);
  return (
    state: CosplayState(
      enabled: st.enabled,
      thinkingStyle: st.thinkingStyle,
      activeRole: st.activeRole,
      roles: st.roles,
    ),
    error: null
  );
}

CosplayState removeCosplayRole(CosplayState st, String id) {
  final roles = st.roles.where((r) => r.id != id).toList();
  var activeRole = st.activeRole;
  if (activeRole == id) activeRole = '';
  return CosplayState(
    enabled: st.enabled,
    thinkingStyle: st.thinkingStyle,
    activeRole: activeRole,
    roles: roles,
  );
}

({CosplayState state, String? error}) setCosplayActiveRole(
    CosplayState st, String id) {
  if (id.isEmpty) {
    return (
      state: CosplayState(
        enabled: st.enabled,
        thinkingStyle: st.thinkingStyle,
        activeRole: '',
        roles: st.roles,
      ),
      error: null
    );
  }
  if (findCosplayRole(st, id) == null) {
    return (state: st, error: '角色不存在: $id');
  }
  return (
    state: CosplayState(
      enabled: st.enabled,
      thinkingStyle: st.thinkingStyle,
      activeRole: id,
      roles: st.roles,
    ),
    error: null
  );
}

// ------------------------------------------------------------
// persona 渲染
// ------------------------------------------------------------
String renderCosplayPersona(CosplayRole? role) {
  if (role == null) return '';
  final head = '你正在扮演角色「${role.name}」${role.emoji}'.trim();
  final parts = <String>[head];
  if (role.systemPrompt.trim().isNotEmpty) parts.add(role.systemPrompt.trim());
  if (role.description.isNotEmpty) parts.add('【身份】${role.description}');
  if (role.personality.isNotEmpty) parts.add('【性格】${role.personality}');
  if (role.style.isNotEmpty) parts.add('【语气】${role.style}');
  if (role.rules.isNotEmpty) parts.add('【守则】${role.rules}');
  if (role.behavior.isNotEmpty) parts.add('【行为】${role.behavior}');
  if (role.scenario.isNotEmpty) parts.add('【场景】${role.scenario}');
  if (role.mesExample.isNotEmpty) parts.add('【示例对话】${role.mesExample}');
  if (role.postHistoryInstr.trim().isNotEmpty) {
    parts.add(role.postHistoryInstr.trim());
  }
  parts.add('始终保持角色设定与口吻，同时继续作为 Agent 助手为用户完成实际工作（编码、读写文件、检索资料等）。');
  return parts.join('\n');
}

String renderActiveCosplayPersona() {
  final st = getCosplayState();
  if (!st.enabled) return '';
  final role = findCosplayRole(st, st.activeRole);
  if (role == null) {
    return 'Cosplay 模式已开启但未选择角色。可用 cosplay_list 查看、cosplay_switch 切换，或在设置页「角色扮演」中激活一个角色；在此之前请保持默认的助手身份与风格。';
  }
  final persona = renderCosplayPersona(role);
  final directive = cosplayThinkingDirectives[st.thinkingStyle] ?? '';
  if (directive.isNotEmpty) return '$persona\n$directive';
  return persona;
}

// ------------------------------------------------------------
// 酒馆 v2 导入导出
// ------------------------------------------------------------
const List<String> cosplayCardTextFields = [
  'description', 'personality', 'scenario', 'first_mes', 'mes_example',
  'system_prompt', 'post_history_instructions', 'creator_notes',
  'character_version', 'creator',
];

const List<String> cosplayPluginFields = ['style', 'rules', 'behavior'];

String cosplayRoleTextField(CosplayRole role, String field) {
  switch (field) {
    case 'description':
      return role.description;
    case 'personality':
      return role.personality;
    case 'scenario':
      return role.scenario;
    case 'first_mes':
      return role.firstMes;
    case 'mes_example':
      return role.mesExample;
    case 'system_prompt':
      return role.systemPrompt;
    case 'post_history_instructions':
      return role.postHistoryInstr;
    case 'creator_notes':
      return role.creatorNotes;
    case 'character_version':
      return role.characterVersion;
    case 'creator':
      return role.creator;
  }
  return '';
}

void cosplaySetRoleTextField(CosplayRole role, String field, String value) {
  switch (field) {
    case 'description':
      role.description = value;
      break;
    case 'personality':
      role.personality = value;
      break;
    case 'scenario':
      role.scenario = value;
      break;
    case 'first_mes':
      role.firstMes = value;
      break;
    case 'mes_example':
      role.mesExample = value;
      break;
    case 'system_prompt':
      role.systemPrompt = value;
      break;
    case 'post_history_instructions':
      role.postHistoryInstr = value;
      break;
    case 'creator_notes':
      role.creatorNotes = value;
      break;
    case 'character_version':
      role.characterVersion = value;
      break;
    case 'creator':
      role.creator = value;
      break;
  }
}

String cosplayRolePluginField(CosplayRole role, String field) {
  switch (field) {
    case 'style':
      return role.style;
    case 'rules':
      return role.rules;
    case 'behavior':
      return role.behavior;
  }
  return '';
}

void cosplaySetRolePluginField(CosplayRole role, String field, String value) {
  switch (field) {
    case 'style':
      role.style = value;
      break;
    case 'rules':
      role.rules = value;
      break;
    case 'behavior':
      role.behavior = value;
      break;
  }
}

Map<String, dynamic> cosplayToV2Card(CosplayRole role) {
  final data = <String, dynamic>{'name': role.name};
  for (final f in cosplayCardTextFields) {
    final v = cosplayRoleTextField(role, f);
    if (v.isNotEmpty) data[f] = v;
  }
  if (role.tags.isNotEmpty) data['tags'] = role.tags;
  final plugin = <String, dynamic>{'id': role.id};
  if (role.emoji.isNotEmpty) plugin['emoji'] = role.emoji;
  for (final f in cosplayPluginFields) {
    final v = cosplayRolePluginField(role, f);
    if (v.isNotEmpty) plugin[f] = v;
  }
  data['extensions'] = {'dshCosplay': plugin};
  return {
    'spec': 'chara_card_v2',
    'spec_version': '2.0',
    'data': data,
  };
}

({CosplayRole? role, String? error}) cosplayFromV2Card(
    Map<String, dynamic> card, CosplayState st) {
  Map<String, dynamic> data;
  if (card['data'] is Map) {
    data = asMap(card['data']);
  } else if (card.containsKey('name')) {
    data = card;
  } else {
    data = <String, dynamic>{};
  }
  final name = mStr(data, 'name').trim();
  if (name.isEmpty) return (role: null, error: '导入的角色卡缺少 name 字段');
  var ext = <String, dynamic>{};
  final e = data['extensions'];
  if (e is Map) {
    final d = asMap(e)['dshCosplay'];
    if (d is Map) ext = asMap(d);
  }
  final role = CosplayRole(name: name);
  if (ext['emoji'] is String) role.emoji = ext['emoji'] as String;
  for (final f in cosplayCardTextFields) {
    final v = data[f];
    if (v is String) cosplaySetRoleTextField(role, f, v);
  }
  for (final t in asList(data['tags'])) {
    if (t is String) role.tags.add(t);
  }
  for (final f in cosplayPluginFields) {
    final v = ext[f];
    if (v is String) cosplaySetRolePluginField(role, f, v);
  }
  final extId = ext['id'];
  if (extId is String && extId.isNotEmpty) {
    role.id = extId;
  } else {
    role.id = nextCosplayID(st, name);
  }
  return (role: role, error: null);
}

// ------------------------------------------------------------
// 工具执行
// ------------------------------------------------------------
String execToolCosplayShow(Map<String, dynamic> args) {
  final st = getCosplayState();
  var id = mStr(args, 'id');
  if (id.isEmpty) id = st.activeRole;
  final role = findCosplayRole(st, id);
  if (role == null) {
    if (id.isNotEmpty) return '未找到角色: $id';
    return '当前未激活任何角色。';
  }
  return renderCosplayPersona(role);
}

String execToolCosplayList() {
  final st = getCosplayState();
  final head = st.enabled ? 'Cosplay 模式：开启' : 'Cosplay 模式：关闭';
  if (st.roles.isEmpty) return '$head\n角色库为空。';
  final lines = <String>[head];
  for (final r in st.roles) {
    final mark = r.id == st.activeRole ? '★ 激活' : '   ';
    lines.add('$mark ${r.emoji} ${r.name} (${r.id})');
  }
  return lines.join('\n');
}

String execToolCosplaySwitch(Map<String, dynamic> args) {
  final st = getCosplayState();
  if (!st.enabled) {
    return 'Cosplay 模式未开启。请先在设置页「角色扮演」中打开开关（或安装后由用户主动开启），再切换角色。';
  }
  var id = mStr(args, 'id');
  if (id == 'null') id = '';
  final r = setCosplayActiveRole(st, id);
  if (r.error != null) return r.error!;
  if (!saveCosplayState(r.state)) return '保存失败';
  if (id.isEmpty) return '已退出扮演，恢复默认身份。';
  final role = findCosplayRole(r.state, id);
  return '已切换到角色「${role?.name ?? id}」。';
}

String execToolCosplayUpsert(Map<String, dynamic> args) {
  var st = getCosplayState();
  final name = mStr(args, 'name').trim();
  if (name.isEmpty) return '角色名不能为空';
  final card = CosplayRole(name: name);
  card.id = mStr(args, 'id');
  card.emoji = mStr(args, 'emoji');
  card.systemPrompt = mStr(args, 'system_prompt');
  card.description = mStr(args, 'description');
  card.personality = mStr(args, 'personality');
  card.style = mStr(args, 'style');
  card.rules = mStr(args, 'rules');
  card.behavior = mStr(args, 'behavior');
  card.scenario = mStr(args, 'scenario');
  card.firstMes = mStr(args, 'first_mes');
  card.mesExample = mStr(args, 'mes_example');
  if (card.id.isEmpty) card.id = nextCosplayID(st, card.name);
  final r = upsertCosplayRole(st, card);
  if (r.error != null) return r.error!;
  st = r.state;
  if (!saveCosplayState(st)) return '保存失败';
  final role = findCosplayRole(st, card.id);
  return '已保存角色「${role?.name ?? card.name}」(${card.id})。';
}

String execToolCosplayRemove(Map<String, dynamic> args) {
  final st = getCosplayState();
  final id = mStr(args, 'id');
  if (id.isEmpty) return 'id 不能为空';
  if (findCosplayRole(st, id) == null) return '未找到角色: $id';
  final next = removeCosplayRole(st, id);
  if (!saveCosplayState(next)) return '保存失败';
  return '已删除角色 $id。';
}

// ------------------------------------------------------------
// HTTP：/api/ds-cosplay
// ------------------------------------------------------------
Future<void> handleDsCosplay(HttpRequest req) async {
  final res = req.response;
  switch (req.method) {
    case 'GET':
      await dsJSONOk(res, 200, {'state': getCosplayState().toJson()});
      return;

    case 'POST':
      Map<String, dynamic> body;
      try {
        body = await readJsonBody(req);
      } catch (_) {
        await dsJSONErr(res, 400, '无效请求体');
        return;
      }
      final action = mStr(body, 'action');
      var st = getCosplayState();
      String? error;
      switch (action) {
        case 'setEnabled':
          st.enabled = mBool(body, 'enabled');
          if (!saveCosplayState(st)) error = '保存失败';
          break;
        case 'setThinkingStyle':
          st.thinkingStyle = mStr(body, 'style') == 'role' ? 'role' : 'neutral';
          if (!saveCosplayState(st)) error = '保存失败';
          break;
        case 'setActiveRole':
          final r = setCosplayActiveRole(st, mStr(body, 'id'));
          if (r.error != null) {
            error = r.error;
          } else {
            st = r.state;
            if (!saveCosplayState(st)) error = '保存失败';
          }
          break;
        case 'upsertRole':
          final cardRaw = body['card'];
          if (cardRaw is! Map) {
            error = '无效的角色卡';
            break;
          }
          final r = upsertCosplayRole(st, CosplayRole.fromJson(asMap(cardRaw)));
          if (r.error != null) {
            error = r.error;
          } else {
            st = r.state;
            if (!saveCosplayState(st)) error = '保存失败';
          }
          break;
        case 'removeRole':
          st = removeCosplayRole(st, mStr(body, 'id'));
          if (!saveCosplayState(st)) error = '保存失败';
          break;
        default:
          error = '未知操作: $action';
      }
      if (error != null) {
        await dsJSONErr(res, 500, error);
        return;
      }
      await dsJSONOk(res, 200, {'state': getCosplayState().toJson()});
      return;

    default:
      await dsJSONErr(res, 405, 'Method not allowed');
  }
}
