// ============================================================
// tts_drm.dart —— Edge TTS Sec-MS-GEC v2 签名
//   对齐 https://github.com/rany2/edge-tts 的 drm.py
//   微软已把 DRM 从 v1（仅 SHA256）升级为 v2（CS64 + SHA256 双摘要），
//   旧版 v1 签名会被 speech.platform.bing.com 返回 403。
//   v2 token 格式："<16hex CS64>-<64hex SHA256>"，版本号前缀 "2-"。
// ============================================================



const int _u32Mask = 0xFFFFFFFF;

const String ttsTrustedToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const String ttsGecVersion = '2-143.0.3650.75';

// ------------------------------------------------------------
// SHA-256（非标准变体）常量
// ------------------------------------------------------------
const List<int> _sha256Initial = [
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];
const List<int> _sha256State = [
  0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A,
  0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
];
const List<int> _sha256Schedule = [
  0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA,
  0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6,
  0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
  0xD258B060, 0x72766564,
];
const List<int> _sha256RoundConstants = [
  0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
  0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
  0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
  0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
  0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
  0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
  0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
  0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
  0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
  0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
  0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
  0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
  0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
  0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
  0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
  0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
];
const int _sha256Adjustment = 0xC9DC06A7;
const int _sha256Sigma0Adjustment = 0x059C0B80;
const int _sha256Sigma1Adjustment = 0x000B92C0;

// _SHA256_BLOCK_CONSTANTS = ROUND_CONSTANTS，仅第 14 项替换为 ADJUSTMENT
final List<int> _sha256BlockConstants = List<int>.from(_sha256RoundConstants)
  ..[14] = _sha256Adjustment;

// ------------------------------------------------------------
// CS64 常量：14 组 (coefficient, offset)，展平为 28 个 int
// ------------------------------------------------------------
const List<int> _cs64Coefficients = [
  0xE82E91B1, 0xB32700D0,
  0x44DE24C6, 0x88DFF51D,
  0x3BEB65BC, 0x29514038,
  0xC89C5933, 0xB328CBDF,
  0x8D1EC211, 0xD405B4D5,
  0x314EF5D5, 0x26E55F3C,
  0xE92491B1, 0x607801C6,
  0xF0A5B9D5, 0x82B2C1FB,
  0x06064CF3, 0xFA51A3DA,
  0xDA79FA60, 0x207CC464,
  0xBED20560, 0x3C3C74F3,
  0x89F9C9F8, 0xD2D14B61,
  0x35FA38C6, 0xBB04A2C1,
  0xCB49E3C6, 0xC5626167,
];
const int _cs64Factor = 0x82893933;
const int _cs64Adjustment0 = 0xF2F90B1A;
const int _cs64Adjustment1 = 0x0B1A0000;

// ------------------------------------------------------------
// 基础位运算
// ------------------------------------------------------------
int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _u32Mask;

int _rol16(int v) {
  v &= _u32Mask;
  return ((v << 16) | (v >> 16)) & _u32Mask;
}

int _sigma0(int v) =>
    ((v >> 7) ^ (v << 25) ^ (v >> 18) ^ (v << 14) ^ (v >> 3)) & _u32Mask;

int _sigma1(int v) =>
    ((v >> 17) ^ (v << 15) ^ (v >> 19) ^ (v << 13) ^ (v >> 10)) & _u32Mask;

void _expandSha256Schedule(List<int> words, [int firstWord = 16]) {
  for (var index = firstWord; index < 64; index++) {
    final x = words[index - 2];
    final y = words[index - 15];
    final sigma1 = (x >> 17) ^ (x << 15) ^ (x >> 19) ^ (x << 13) ^ (x >> 10);
    final sigma0 = (y >> 7) ^ (y << 25) ^ (y >> 18) ^ (y << 14) ^ (y >> 3);
    words.add(
        (sigma1 + words[index - 7] + sigma0 + words[index - 16]) & _u32Mask);
  }
}

List<int> _sha256Rounds(List<int> state, List<int> words,
    [int firstRound = 0]) {
  var a = state[0], b = state[1], c = state[2], d = state[3];
  var e = state[4], f = state[5], g = state[6], h = state[7];
  final constants =
      firstRound == 14 ? _sha256BlockConstants : _sha256RoundConstants;
  for (var i = firstRound; i < 64; i++) {
    final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
    final ch = (e & f) ^ ((~e & _u32Mask) & g);
    final t1 = h + s1 + ch + constants[i] + words[i];
    final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
    final maj = (a & b) ^ (a & c) ^ (b & c);
    final t2 = s0 + maj;
    final na = (t1 + t2) & _u32Mask;
    final ne = (d + t1) & _u32Mask;
    h = g;
    g = f;
    f = e;
    e = ne;
    d = c;
    c = b;
    b = a;
    a = na;
  }
  return [a, b, c, d, e, f, g, h];
}

/// 计算前 7 字节的初始 SHA-256 状态
List<int> _sha256Init(List<int> data) {
  final words = <int>[];
  for (var i = 0; i < 14; i++) {
    words.add(0);
  }
  // int.from_bytes(data[:3], "big")
  words.add((data[0] << 16) | (data[1] << 8) | data[2]);
  // int.from_bytes(data[3:7], "big")
  words.add((data[3] << 24) | (data[4] << 16) | (data[5] << 8) | data[6]);

  for (var index = 16; index < 30; index++) {
    var value = _sha256Schedule[index - 16];
    if (index - 2 >= 14) {
      final s1 = _sigma1(words[index - 2]);
      value += (index == 16) ? (s1 ^ _sha256Sigma1Adjustment) : s1;
    }
    if (index - 7 >= 14) {
      value += words[index - 7];
    }
    if (index - 15 >= 14) {
      final s0 = _sigma0(words[index - 15]);
      value += (index == 29) ? (s0 ^ _sha256Sigma0Adjustment) : s0;
    }
    words.add(value & _u32Mask);
  }
  words.add((_sigma1(words[28]) +
          words[23] +
          _sigma0(words[15]) +
          words[14] +
          _sha256Adjustment -
          _sha256RoundConstants[14]) &
      _u32Mask);
  _expandSha256Schedule(words, 31);
  final working = _sha256Rounds(_sha256State, words, 14);
  final result = <int>[];
  for (var i = 0; i < 8; i++) {
    result.add((_sha256Initial[i] + working[i]) & _u32Mask);
  }
  return result;
}

List<int> _sha256Digest(List<int> data) {
  final length = 57 + data.length;
  final padded = <int>[];
  padded.addAll(data.sublist(7));
  padded.add(0x80);
  final padCount = ((55 - length) % 64 + 64) % 64;
  for (var i = 0; i < padCount; i++) {
    padded.add(0);
  }
  final lengthBits = length * 8;
  for (var i = 7; i >= 0; i--) {
    padded.add((lengthBits >> (8 * i)) & 0xFF);
  }
  var state = _sha256Init(data.sublist(0, 7));
  for (var offset = 0; offset < padded.length; offset += 64) {
    final words = <int>[];
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      words.add((padded[j] << 24) |
          (padded[j + 1] << 16) |
          (padded[j + 2] << 8) |
          padded[j + 3]);
    }
    _expandSha256Schedule(words);
    final working = _sha256Rounds(state, words);
    final newState = <int>[];
    for (var i = 0; i < 8; i++) {
      newState.add((state[i] + working[i]) & _u32Mask);
    }
    state = newState;
  }
  final out = <int>[];
  for (var i = 0; i < 8; i++) {
    final v = state[i];
    out.add((v >> 24) & 0xFF);
    out.add((v >> 16) & 0xFF);
    out.add((v >> 8) & 0xFF);
    out.add(v & 0xFF);
  }
  return out;
}

List<int> _wordsLe4Even(List<int> data) {
  final padLen = (4 - (data.length % 4)) % 4;
  final padded = List<int>.from(data);
  for (var i = 0; i < padLen; i++) {
    padded.add(0);
  }
  if (padded.isEmpty) return [];
  final words = <int>[];
  for (var i = 0; i + 3 < padded.length; i += 4) {
    words.add(padded[i] |
        (padded[i + 1] << 8) |
        (padded[i + 2] << 16) |
        (padded[i + 3] << 24));
  }
  if (words.length % 2 != 0) words.add(0);
  return words;
}

List<int> _cs64Digest(List<int> data, List<int> digest) {
  final keyA = (digest[0] |
          (digest[1] << 8) |
          (digest[2] << 16) |
          (digest[3] << 24)) |
      1;
  final keyB = (digest[4] |
          (digest[5] << 8) |
          (digest[6] << 16) |
          (digest[7] << 24)) |
      1;
  final factorA = (keyA * _cs64Factor) & _u32Mask;
  final factorB = (keyB * _cs64Factor) & _u32Mask;
  final factors = [factorA, factorB];

  final terms = <int>[];
  final offsets = <int>[];
  for (var i = 0; i < 14; i++) {
    final coefficient = _cs64Coefficients[2 * i];
    final offset = _cs64Coefficients[2 * i + 1];
    terms.add((coefficient * factors[i % 2]) & _u32Mask);
    offsets.add(offset);
  }

  final words = _wordsLe4Even([0, ...data]);
  for (var index = 0; index < words.length; index++) {
    final word = words[index];
    final even = index % 2 == 0;
    var term = word * (even ? keyA : keyB);
    var offset = _rol16(word) * (even ? 0xEF0569FB : 0xC31713DB);
    if (index == 0) {
      term += _cs64Adjustment0 * factors[0];
      offset += _cs64Adjustment1;
    }
    terms.add(term & _u32Mask);
    offsets.add(offset & _u32Mask);
  }

  var swapAcc = 0, swapLast = 0, state = 0, acc = 0;
  for (var index = 0; index + 1 < terms.length; index += 2) {
    final x = terms[index];
    final y = terms[index + 1];
    var t = _rol16((offsets[index] + x) & _u32Mask);
    var q = (t * 0x76F50F34) & _u32Mask;
    swapAcc += (_rol16(q) * 0xC3EFEA97 + q) & _u32Mask;
    t = _rol16((offsets[index + 1] + y) & _u32Mask);
    q = (t * 0x1881CE3C) & _u32Mask;
    swapLast = (_rol16(q) * 0x35BD1EC9 + q) & _u32Mask;
    swapAcc = (swapAcc + swapLast) & _u32Mask;

    state = (state * keyA + x) & _u32Mask;
    state = (_rol16(state) * 0xCF98B111) & _u32Mask;
    state = (_rol16(state) * 0x87085B9F) & _u32Mask;
    state = (_rol16(state) * 0x12CEB96D) & _u32Mask;
    state = (_rol16(state) * 0x257E1D83) & _u32Mask;
    acc += state;
    var t2 = (state * keyB + y) & _u32Mask;
    t2 = (_rol16(t2) * 0xA27416F5) & _u32Mask;
    t2 = (_rol16(t2) * 0xD38396FF) & _u32Mask;
    state =
        (_rol16((_rol16(t2) * 0x7C932B89) & _u32Mask) * 0xBFA49F69) & _u32Mask;
    acc = (acc + state) & _u32Mask;
  }
  return [swapLast ^ state, swapAcc ^ acc];
}

String _le32Hex(int v) {
  final b = [
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ];
  return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}

List<String> ttsTokenHash(List<int> data) {
  final digest = _sha256Digest(data);
  final cs = _cs64Digest(data, digest);
  final cs64Hex = _le32Hex(cs[0]) + _le32Hex(cs[1]);
  final shaHex =
      digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  return [cs64Hex, shaHex];
}

/// 生成 Sec-MS-GEC v2 token："<16hex CS64>-<64hex SHA256>"
String ttsSecMsGecV2() {
  final ms = DateTime.now().toUtc().millisecondsSinceEpoch;
  final totalMs = ms + 11644473600000; // WIN_EPOCH * 1000
  final ticksSeconds = (totalMs ~/ 300000) * 300;
  final ticks = ticksSeconds * 10000000; // S_TO_NS / 100
  final strToHash = '$ticks$ttsTrustedToken';
  final h = ttsTokenHash(strToHash.codeUnits);
  return '${h[0]}-${h[1]}';
}
