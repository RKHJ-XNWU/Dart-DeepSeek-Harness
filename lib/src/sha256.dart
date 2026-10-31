// ============================================================
// sha256.dart —— 纯 Dart SHA-256 / HMAC-SHA256
// 用于钉钉、飞书机器人的加签（对齐 Go crypto/hmac + crypto/sha256）
// ============================================================

import 'dart:typed_data';

const List<int> _K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

Uint8List sha256(List<int> data) {
  var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

  final msg = BytesBuilder();
  msg.add(data);
  final bitLen = data.length * 8;
  msg.addByte(0x80);
  var padLen = msg.length % 64;
  final need = padLen <= 56 ? 56 - padLen : 120 - padLen;
  msg.add(Uint8List(need));
  final lenBytes = Uint8List(8);
  var bl = bitLen;
  for (var i = 7; i >= 0; i--) {
    lenBytes[i] = bl & 0xFF;
    bl >>= 8;
  }
  msg.add(lenBytes);

  final all = msg.takeBytes();
  final w = List<int>.filled(64, 0);

  for (var off = 0; off < all.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      final j = off + i * 4;
      w[i] = (all[j] << 24) | (all[j + 1] << 16) | (all[j + 2] << 8) | all[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (var i = 0; i < 64; i++) {
      final S1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final temp1 = (h + S1 + ch + _K[i] + w[i]) & 0xFFFFFFFF;
      final S0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (S0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
    h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF;
    h7 = (h7 + h) & 0xFFFFFFFF;
  }

  final out = Uint8List(32);
  final hs = [h0, h1, h2, h3, h4, h5, h6, h7];
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (hs[i] >> 24) & 0xFF;
    out[i * 4 + 1] = (hs[i] >> 16) & 0xFF;
    out[i * 4 + 2] = (hs[i] >> 8) & 0xFF;
    out[i * 4 + 3] = hs[i] & 0xFF;
  }
  return out;
}

Uint8List hmacSha256(List<int> key, List<int> message) {
  const blockSize = 64;
  var k = key.length > blockSize ? sha256(key) : Uint8List.fromList(key);
  final kPad = Uint8List(blockSize)..setRange(0, k.length, k);

  final ipad = Uint8List(blockSize);
  final opad = Uint8List(blockSize);
  for (var i = 0; i < blockSize; i++) {
    ipad[i] = kPad[i] ^ 0x36;
    opad[i] = kPad[i] ^ 0x5C;
  }
  final inner = sha256([...ipad, ...message]);
  return sha256([...opad, ...inner]);
}

/// 自检（RFC 4231 测试用例 2）
bool shaSelfTest() {
  final mac = hmacSha256(
      'Jefe'.codeUnits, 'what do ya want for nothing?'.codeUnits);
  final hex = mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return hex ==
      '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843';
}
