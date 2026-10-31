// ============================================================
// ds_crypto.dart —— 主密钥 + AES-256-GCM 加解密 + DeepSeek 配置读写
// 100% 对齐 Go 版 ds_crypto.go + deepseek-chat.go(getDsConfig/saveDsConfig)
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'aes_gcm.dart';
import 'globals.dart';

String get dsChatDir => '$DATA_DIR/deepseek_chat';
String get dsSessionsDir => '$dsChatDir/sessions';
String get dsChatConfigFile => '$dsChatDir/ds_chat_config.sts';
String get dsMasterKeyFile => '$dsChatDir/ds_master.key';

const String dsConfigEncPrefix = 'DSENC1|';
const String DS_DEFAULT_MODEL = 'deepseek-flash';

final math.Random _secRnd = math.Random.secure();

Uint8List _randomBytes(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = _secRnd.nextInt(256);
  }
  return b;
}

// ------------------------------------------------------------
// 主密钥：环境变量 → ds_master.key → 自动生成
// ------------------------------------------------------------
List<int> decodeMasterKey(String s) {
  final t = s.trim();
  if (t.length == 64) {
    try {
      return _hexDecode(t);
    } catch (_) {/* fallthrough */}
  }
  try {
    return base64.decode(t);
  } catch (_) {
    return utf8.encode(t);
  }
}

List<int> _hexDecode(String s) {
  final out = <int>[];
  for (var i = 0; i + 1 < s.length; i += 2) {
    out.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return out;
}

String _hexEncode(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int>? _masterKeyCache;

List<int> getOrCreateMasterKey() {
  final cached = _masterKeyCache;
  if (cached != null) return cached;

  final env = getEnv('DS_MASTER_KEY');
  if (env != null && env.isNotEmpty) {
    final k = decodeMasterKey(env);
    if (k.length == 32) {
      _masterKeyCache = k;
      return k;
    }
  }
  if (File(dsMasterKeyFile).existsSync()) {
    try {
      final k = decodeMasterKey(File(dsMasterKeyFile).readAsStringSync());
      if (k.length == 32) {
        _masterKeyCache = k;
        return k;
      }
    } catch (_) {/* ignore */}
  }
  final key = _randomBytes(32);
  ensureDir(dsChatDir);
  try {
    File(dsMasterKeyFile).writeAsStringSync(_hexEncode(key));
    // 权限 0600（Termux 下 chmod 生效）
    Process.runSync('chmod', ['600', dsMasterKeyFile]);
  } catch (e) {
    logp('⚠️ 写入主密钥失败: $e');
  }
  _masterKeyCache = key;
  return key;
}

// ------------------------------------------------------------
// dsEncrypt / dsDecrypt（base64(nonce||cipher||tag)）
// ------------------------------------------------------------
String dsEncrypt(String plain) {
  final key = getOrCreateMasterKey();
  final nonce = _randomBytes(12);
  final gcm = AesGcm(key);
  final sealed = gcm.encrypt(nonce, utf8.encode(plain));
  return base64.encode([...nonce, ...sealed]);
}

String dsDecrypt(String encoded) {
  final key = getOrCreateMasterKey();
  List<int> raw;
  try {
    raw = base64.decode(encoded.trim());
  } catch (e) {
    throw FormatException('密文 base64 解码失败: $e');
  }
  if (raw.length < 12) {
    throw const FormatException('密文长度不足');
  }
  final nonce = raw.sublist(0, 12);
  final body = raw.sublist(12);
  final gcm = AesGcm(key);
  final plain = gcm.decrypt(nonce, body);
  return utf8.decode(plain);
}

// ------------------------------------------------------------
// DeepSeek 配置读写（支持旧明文自动迁移为加密格式）
// ------------------------------------------------------------
class DsConfig {
  final String apiKey;
  final String model;
  final String imgKey;
  const DsConfig(this.apiKey, this.model, this.imgKey);
}

DsConfig getDsConfig() {
  if (!File(dsChatConfigFile).existsSync()) {
    return const DsConfig('', DS_DEFAULT_MODEL, '');
  }
  String line;
  try {
    line = File(dsChatConfigFile).readAsStringSync().trim();
  } catch (_) {
    return const DsConfig('', DS_DEFAULT_MODEL, '');
  }
  if (line.isEmpty) return const DsConfig('', DS_DEFAULT_MODEL, '');

  if (line.startsWith(dsConfigEncPrefix)) {
    final rest = line.substring(dsConfigEncPrefix.length);
    final parts = rest.split('|');
    if (parts.length >= 3) {
      String key = '';
      String model = '';
      String imgKey = '';
      try {
        key = dsDecrypt(parts[0]);
      } catch (_) {}
      try {
        model = dsDecrypt(parts[1]);
      } catch (_) {}
      try {
        imgKey = dsDecrypt(parts[2]);
      } catch (_) {}
      if (model.isEmpty) model = DS_DEFAULT_MODEL;
      return DsConfig(key, model, imgKey);
    }
    return const DsConfig('', DS_DEFAULT_MODEL, '');
  }

  // 旧明文格式 apiKey|model|imgKey → 自动迁移
  final parts = line.split('|');
  var key = '';
  var model = DS_DEFAULT_MODEL;
  var imgKey = '';
  if (parts.isNotEmpty) key = parts[0];
  if (parts.length >= 2 && parts[1].trim().isNotEmpty) {
    model = parts[1].trim();
  }
  if (parts.length >= 3) imgKey = parts[2];
  if (key.isNotEmpty || imgKey.isNotEmpty) {
    saveDsConfig(key, model, imgKey);
  }
  return DsConfig(key, model, imgKey);
}

bool saveDsConfig(String apiKey, String model, String imgKey) {
  if (model.isEmpty) model = DS_DEFAULT_MODEL;
  try {
    final ek = dsEncrypt(apiKey);
    final em = dsEncrypt(model);
    final ei = dsEncrypt(imgKey);
    final line = '$dsConfigEncPrefix$ek|$em|$ei';
    ensureDir(dsChatDir);
    File(dsChatConfigFile).writeAsStringSync(line);
    Process.runSync('chmod', ['600', dsChatConfigFile]);
    return true;
  } catch (e) {
    logp('❌ 保存配置失败: $e');
    return false;
  }
}
