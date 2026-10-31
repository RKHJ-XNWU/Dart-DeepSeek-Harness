// ============================================================
// aes_gcm.dart —— 纯 Dart 的 AES-256-GCM
//
// 对应 Go 版：ds_crypto.go 使用 crypto/aes + cipher.NewGCM
//   密文格式：base64( nonce(12B) || ciphertext || tag(16B) )
//
// 之所以自己实现：
//   1. 项目要求零第三方依赖（不引入 cryptography / pointycastle）；
//   2. 必须与 Go 版已落盘的 DSENC1| 配置密文**二进制兼容**，
//      因此严格按 NIST SP 800-38D 实现（GHASH 用 BigInt 计算，
//      仅为少量配置字段加解密，性能足够）。
//
// S-box 由 GF(2^8) 乘法逆 + 仿射变换现场生成，避免手抄常量表出错，
// 并在编译期自检（见 verifySelfTest()）。
// ============================================================

import 'dart:typed_data';

// ------------------------------------------------------------
// GF(2^8) 基础
// ------------------------------------------------------------
int _xtime(int a) {
  final hi = a & 0x80;
  var r = (a << 1) & 0xFF;
  if (hi != 0) r ^= 0x1B;
  return r;
}

int _gmul8(int a, int b) {
  var p = 0;
  var aa = a;
  var bb = b;
  for (var i = 0; i < 8; i++) {
    if (bb & 1 != 0) p ^= aa;
    aa = _xtime(aa);
    bb >>= 1;
  }
  return p & 0xFF;
}

int _gInv(int a) {
  if (a == 0) return 0;
  for (var b = 1; b < 256; b++) {
    if (_gmul8(a, b) == 1) return b;
  }
  return 0;
}

int _rotl8(int x, int n) => ((x << n) | (x >> (8 - n))) & 0xFF;

int _sboxOf(int x) {
  final y = _gInv(x);
  return (_rotl8(y, 1) ^
          _rotl8(y, 2) ^
          _rotl8(y, 3) ^
          _rotl8(y, 4) ^
          y ^
          0x63) &
      0xFF;
}

List<int>? _sboxCache;

List<int> get _SBOX {
  final c = _sboxCache;
  if (c != null) return c;
  final t = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    t[i] = _sboxOf(i);
  }
  _sboxCache = t;
  return t;
}

List<int>? _invSboxCache;

List<int> get _INV_SBOX {
  final c = _invSboxCache;
  if (c != null) return c;
  final t = List<int>.filled(256, 0);
  final s = _SBOX;
  for (var i = 0; i < 256; i++) {
    t[s[i]] = i;
  }
  _invSboxCache = t;
  return t;
}

const List<int> _RCON = [
  0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36,
];

// ------------------------------------------------------------
// AES-256（只做单块加/解密，GCM 用 CTR 模式自行串联）
// ------------------------------------------------------------
class Aes256 {
  final List<int> _rk; // 60 words * 4 bytes

  Aes256(List<int> key) : _rk = _expandKey(key);

  static List<int> _expandKey(List<int> key) {
    if (key.length != 32) {
      throw ArgumentError('AES-256 需要 32 字节密钥，实际 ${key.length}');
    }
    final nk = 8;
    final nr = 14;
    final w = List<int>.filled(4 * (nr + 1) * 4, 0); // 每个 word 4 字节平铺
    for (var i = 0; i < nk * 4; i++) {
      w[i] = key[i];
    }
    final sbox = _SBOX;
    for (var i = nk; i < 4 * (nr + 1); i++) {
      var t0 = w[i * 4 - 4];
      var t1 = w[i * 4 - 3];
      var t2 = w[i * 4 - 2];
      var t3 = w[i * 4 - 1];
      if (i % nk == 0) {
        // RotWord + SubWord + Rcon
        final tmp = t0;
        t0 = sbox[t1] ^ _RCON[i ~/ nk - 1];
        t1 = sbox[t2];
        t2 = sbox[t3];
        t3 = sbox[tmp];
      } else if (i % nk == 4) {
        t0 = sbox[t0];
        t1 = sbox[t1];
        t2 = sbox[t2];
        t3 = sbox[t3];
      }
      w[i * 4] = w[(i - nk) * 4] ^ t0;
      w[i * 4 + 1] = w[(i - nk) * 4 + 1] ^ t1;
      w[i * 4 + 2] = w[(i - nk) * 4 + 2] ^ t2;
      w[i * 4 + 3] = w[(i - nk) * 4 + 3] ^ t3;
    }
    return w;
  }

  void _addRoundKey(Uint8List s, int round) {
    final base = round * 16;
    for (var i = 0; i < 16; i++) {
      s[i] ^= _rk[base + i];
    }
  }

  void _subBytes(Uint8List s) {
    final sbox = _SBOX;
    for (var i = 0; i < 16; i++) {
      s[i] = sbox[s[i]];
    }
  }

  void _invSubBytes(Uint8List s) {
    final inv = _INV_SBOX;
    for (var i = 0; i < 16; i++) {
      s[i] = inv[s[i]];
    }
  }

  // state 为列主序：s[c*4 + r]
  void _shiftRows(Uint8List s) {
    var t = s[1];
    s[1] = s[5];
    s[5] = s[9];
    s[9] = s[13];
    s[13] = t;

    t = s[2];
    s[2] = s[10];
    s[10] = t;
    t = s[6];
    s[6] = s[14];
    s[14] = t;

    t = s[15];
    s[15] = s[11];
    s[11] = s[7];
    s[7] = s[3];
    s[3] = t;
  }

  void _invShiftRows(Uint8List s) {
    var t = s[13];
    s[13] = s[9];
    s[9] = s[5];
    s[5] = s[1];
    s[1] = t;

    t = s[2];
    s[2] = s[10];
    s[10] = t;
    t = s[6];
    s[6] = s[14];
    s[14] = t;

    t = s[3];
    s[3] = s[7];
    s[7] = s[11];
    s[11] = s[15];
    s[15] = t;
  }

  void _mixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      final t = a0 ^ a1 ^ a2 ^ a3;
      s[i] = a0 ^ t ^ _xtime(a0 ^ a1);
      s[i + 1] = a1 ^ t ^ _xtime(a1 ^ a2);
      s[i + 2] = a2 ^ t ^ _xtime(a2 ^ a3);
      s[i + 3] = a3 ^ t ^ _xtime(a3 ^ a0);
    }
  }

  void _invMixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _gmul8(a0, 0x0E) ^
          _gmul8(a1, 0x0B) ^
          _gmul8(a2, 0x0D) ^
          _gmul8(a3, 0x09);
      s[i + 1] = _gmul8(a0, 0x09) ^
          _gmul8(a1, 0x0E) ^
          _gmul8(a2, 0x0B) ^
          _gmul8(a3, 0x0D);
      s[i + 2] = _gmul8(a0, 0x0D) ^
          _gmul8(a1, 0x09) ^
          _gmul8(a2, 0x0E) ^
          _gmul8(a3, 0x0B);
      s[i + 3] = _gmul8(a0, 0x0B) ^
          _gmul8(a1, 0x0D) ^
          _gmul8(a2, 0x09) ^
          _gmul8(a3, 0x0E);
    }
  }

  Uint8List encryptBlock(List<int> input) {
    final s = Uint8List.fromList(input.sublist(0, 16));
    _addRoundKey(s, 0);
    for (var round = 1; round < 14; round++) {
      _subBytes(s);
      _shiftRows(s);
      _mixColumns(s);
      _addRoundKey(s, round);
    }
    _subBytes(s);
    _shiftRows(s);
    _addRoundKey(s, 14);
    return s;
  }

  Uint8List decryptBlock(List<int> input) {
    final s = Uint8List.fromList(input.sublist(0, 16));
    _addRoundKey(s, 14);
    for (var round = 13; round >= 1; round--) {
      _invShiftRows(s);
      _invSubBytes(s);
      _addRoundKey(s, round);
      _invMixColumns(s);
    }
    _invShiftRows(s);
    _invSubBytes(s);
    _addRoundKey(s, 0);
    return s;
  }
}

// ------------------------------------------------------------
// GHASH / GCM（NIST SP 800-38D）
// ------------------------------------------------------------
final BigInt _R = BigInt.parse('E1000000000000000000000000000000', radix: 16);

BigInt _bytesToBig(List<int> b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x & 0xFF);
  }
  return r;
}

List<int> _bigToBytes(BigInt v, int len) {
  final out = List<int>.filled(len, 0);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x = x >> 8;
  }
  return out;
}

BigInt _gfMul(BigInt x, BigInt y) {
  var z = BigInt.zero;
  var v = y;
  for (var i = 0; i < 128; i++) {
    final bit = (x >> (127 - i)) & BigInt.one;
    if (bit == BigInt.one) z ^= v;
    if ((v & BigInt.one) == BigInt.one) {
      v = (v >> 1) ^ _R;
    } else {
      v = v >> 1;
    }
  }
  return z;
}

BigInt _ghash(BigInt h, List<int> aad, List<int> ct) {
  final data = <int>[];
  data.addAll(aad);
  final padA = (16 - (aad.length % 16)) % 16;
  data.addAll(List<int>.filled(padA, 0));
  data.addAll(ct);
  final padC = (16 - (ct.length % 16)) % 16;
  data.addAll(List<int>.filled(padC, 0));
  // 长度块：AAD 位数(64) || 密文位数(64)
  final lenBlock = <int>[
    ..._bigToBytes(BigInt.from(aad.length * 8), 8),
    ..._bigToBytes(BigInt.from(ct.length * 8), 8),
  ];
  data.addAll(lenBlock);

  var y = BigInt.zero;
  for (var i = 0; i < data.length; i += 16) {
    final block = _bytesToBig(data.sublist(i, i + 16));
    y = _gfMul(y ^ block, h);
  }
  return y;
}

class AesGcm {
  final Aes256 _aes;
  late final Uint8List _hashKey;

  AesGcm(List<int> key) : _aes = Aes256(key) {
    // H = E(K, 0^128)
    _hashKey = _aes.encryptBlock(List<int>.filled(16, 0));
  }

  /// 递增 32-bit 计数器（J0 的最后 4 字节）
  static List<int> _inc32(List<int> block) {
    final b = List<int>.from(block);
    var c = ((b[12] << 24) | (b[13] << 16) | (b[14] << 8) | b[15]);
    c = (c + 1) & 0xFFFFFFFF;
    b[12] = (c >> 24) & 0xFF;
    b[13] = (c >> 16) & 0xFF;
    b[14] = (c >> 8) & 0xFF;
    b[15] = c & 0xFF;
    return b;
  }

  static Uint8List _ctr(List<int> j0, List<int> input, Aes256 aes) {
    final out = Uint8List(input.length);
    var counter = List<int>.from(j0);
    var offset = 0;
    while (offset < input.length) {
      counter = _inc32(counter);
      final ks = aes.encryptBlock(counter);
      final n = (input.length - offset) < 16 ? (input.length - offset) : 16;
      for (var i = 0; i < n; i++) {
        out[offset + i] = input[offset + i] ^ ks[i];
      }
      offset += n;
    }
    return out;
  }

  /// 加密：返回 ciphertext || tag(16)
  Uint8List encrypt(List<int> nonce, List<int> plain, {List<int> aad = const []}) {
    final j0 = <int>[...nonce, 0, 0, 0, 1];
    final ct = _ctr(j0, plain, _aes);
    final s = _ghash(_bytesToBig(_hashKey), aad, ct);
    final ek = _bytesToBig(_aes.encryptBlock(j0));
    final tag = _bigToBytes(ek ^ s, 16);
    return Uint8List.fromList([...ct, ...tag]);
  }

  /// 解密：输入 ciphertext || tag(16)
  Uint8List decrypt(List<int> nonce, List<int> cipherWithTag,
      {List<int> aad = const []}) {
    if (cipherWithTag.length < 16) {
      throw const FormatException('密文长度不足');
    }
    final ct = cipherWithTag.sublist(0, cipherWithTag.length - 16);
    final tag = cipherWithTag.sublist(cipherWithTag.length - 16);
    final j0 = <int>[...nonce, 0, 0, 0, 1];
    final s = _ghash(_bytesToBig(_hashKey), aad, ct);
    final ek = _bytesToBig(_aes.encryptBlock(j0));
    final expect = _bigToBytes(ek ^ s, 16);
    for (var i = 0; i < 16; i++) {
      if (expect[i] != tag[i]) {
        throw const FormatException('GCM tag 校验失败');
      }
    }
    return _ctr(j0, ct, _aes);
  }
}

// ------------------------------------------------------------
// 自检（NIST 测试向量，供 verify 使用）
// ------------------------------------------------------------
bool aesSelfTest() {
  // FIPS-197 AES-256 单块向量
  final key = List<int>.generate(32, (i) => i);
  final pt = List<int>.generate(16, (i) => i * 0x11);
  final expect = [
    0x8e, 0xa2, 0xb7, 0xca, 0x51, 0x67, 0x45, 0xbf,
    0xea, 0xfc, 0x49, 0x90, 0x4b, 0x49, 0x60, 0x89,
  ];
  final aes = Aes256(key);
  final ct = aes.encryptBlock(pt);
  for (var i = 0; i < 16; i++) {
    if (ct[i] != expect[i]) return false;
  }
  final back = aes.decryptBlock(ct);
  for (var i = 0; i < 16; i++) {
    if (back[i] != pt[i]) return false;
  }
  // S-box 首尾抽样
  if (_SBOX[0] != 0x63 || _SBOX[1] != 0x7C || _SBOX[255] != 0x16) return false;
  return true;
}
