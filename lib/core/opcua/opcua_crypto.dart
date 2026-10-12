/// O mínimo de criptografia para a senha do usuário ir cifrada num canal sem
/// segurança (modo None).
///
/// Muito servidor que também tem endpoint seguro (asyncua com certificado,
/// S7-1500, Prosys) pede, no endpoint None, a senha cifrada com a chave
/// pública do certificado dele — RSA-OAEP com SHA-1, o da política
/// Basic256Sha256 (Parte 4, 7.36.2.2; Parte 7, "SecurityPolicy"). É uma
/// operação só de chave pública: não precisa de certificado do cliente nem
/// de chave privada.
///
/// Fica de fora (custo estimado em docs/pesquisa-etapa4/7-spike-opcua.md):
/// assinar e cifrar o canal (Sign/SignAndEncrypt), que exige certificado
/// próprio, chave privada, AES e HMAC.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// SHA-1 (FIPS 180-4). Usado só no preenchimento OAEP e na impressão digital
/// do certificado — não como proteção de senha.
abstract final class Sha1 {
  static Uint8List hash(List<int> data) {
    final ml = data.length * 8;
    final padded = BytesBuilder()
      ..add(data)
      ..addByte(0x80);
    while ((padded.length + 8) % 64 != 0) {
      padded.addByte(0);
    }
    final len = ByteData(8)..setUint64(0, ml);
    padded.add(len.buffer.asUint8List());
    final msg = ByteData.sublistView(padded.takeBytes());

    var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    final w = Uint32List(80);
    int rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
    for (var chunk = 0; chunk < msg.lengthInBytes; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = msg.getUint32(chunk + i * 4);
      }
      for (var i = 16; i < 80; i++) {
        w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4;
      for (var i = 0; i < 80; i++) {
        final int f, k;
        if (i < 20) {
          f = (b & c) | ((~b & 0xFFFFFFFF) & d);
          k = 0x5A827999;
        } else if (i < 40) {
          f = b ^ c ^ d;
          k = 0x6ED9EBA1;
        } else if (i < 60) {
          f = (b & c) | (b & d) | (c & d);
          k = 0x8F1BBCDC;
        } else {
          f = b ^ c ^ d;
          k = 0xCA62C1D6;
        }
        final t = (rotl(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
        e = d;
        d = c;
        c = rotl(b, 30);
        b = a;
        a = t;
      }
      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
    }
    final out = ByteData(20)
      ..setUint32(0, h0)
      ..setUint32(4, h1)
      ..setUint32(8, h2)
      ..setUint32(12, h3)
      ..setUint32(16, h4);
    return out.buffer.asUint8List();
  }
}

/// Chave pública RSA (módulo e expoente).
class RsaPublicKey {
  const RsaPublicKey(this.modulus, this.exponent);

  final BigInt modulus;
  final BigInt exponent;

  /// Tamanho da chave em bytes (256 numa chave de 2048 bits).
  int get size => (modulus.bitLength + 7) ~/ 8;

  /// A chave do certificado X.509 (DER) do servidor. Quando o servidor manda
  /// a cadeia inteira (vários certificados colados), vale o primeiro. Lança
  /// [FormatException] se não achar uma chave RSA.
  static RsaPublicKey fromCertificate(Uint8List der) {
    final cert = _Der(der).sequence(); // Certificate
    final tbs = cert.sequence(); // TBSCertificate
    if (tbs.peek == 0xA0) tbs.skip(); // [0] versão
    tbs.skip(); // número de série
    tbs.skip(); // algoritmo da assinatura
    tbs.skip(); // emissor
    tbs.skip(); // validade
    tbs.skip(); // titular
    final spki = tbs.sequence(); // SubjectPublicKeyInfo
    final alg = spki.sequence();
    if (!_bytesEqual(alg.raw(0x06), _rsaOid)) throw const FormatException('o certificado do servidor não tem chave RSA');
    final bits = spki.raw(0x03);
    if (bits.isEmpty || bits[0] != 0) throw const FormatException('chave pública mal formada no certificado');
    final key = _Der(Uint8List.sublistView(bits, 1)).sequence();
    return RsaPublicKey(key.integer(), key.integer());
  }

  /// 1.2.840.113549.1.1.1 (rsaEncryption).
  static const List<int> _rsaOid = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01];

  BigInt _encryptBlock(Uint8List block) => _toBigInt(block).modPow(exponent, modulus);

  /// RSA-OAEP com SHA-1 e MGF1-SHA1, rótulo vazio (RFC 8017, 7.1). Texto maior
  /// que um bloco vai em vários blocos colados, como a norma do OPC UA manda.
  Uint8List encryptOaep(List<int> message, {Random? random}) {
    final rnd = random ?? Random.secure();
    final k = size;
    const hLen = 20;
    final maxBlock = k - 2 * hLen - 2;
    if (maxBlock < 1) throw const FormatException('chave RSA pequena demais');
    final lHash = Sha1.hash(const []);
    final out = BytesBuilder();
    for (var off = 0; off < message.length || (off == 0 && message.isEmpty); off += maxBlock) {
      final m = message.sublist(off, min(off + maxBlock, message.length));
      // DB = lHash || PS (zeros) || 0x01 || M
      final db = Uint8List(k - hLen - 1)
        ..setRange(0, hLen, lHash)
        ..[k - hLen - 1 - m.length - 1] = 0x01
        ..setRange(k - hLen - 1 - m.length, k - hLen - 1, m);
      final seed = Uint8List.fromList([for (var i = 0; i < hLen; i++) rnd.nextInt(256)]);
      final dbMask = _mgf1(seed, db.length);
      for (var i = 0; i < db.length; i++) {
        db[i] ^= dbMask[i];
      }
      final seedMask = _mgf1(db, hLen);
      for (var i = 0; i < hLen; i++) {
        seed[i] ^= seedMask[i];
      }
      final em = Uint8List(k)
        ..setRange(1, 1 + hLen, seed)
        ..setRange(1 + hLen, k, db);
      out.add(_fromBigInt(_encryptBlock(em), k));
      if (message.isEmpty) break;
    }
    return out.takeBytes();
  }

  static Uint8List _mgf1(List<int> seed, int length) {
    final out = BytesBuilder();
    for (var counter = 0; out.length < length; counter++) {
      final c = ByteData(4)..setUint32(0, counter);
      out.add(Sha1.hash([...seed, ...c.buffer.asUint8List()]));
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }
}

/// A senha do usuário no formato da norma para ir cifrada: tamanho (UInt32
/// little-endian) de senha + nonce, a senha em UTF-8 e o nonce que o
/// servidor mandou na criação da sessão (impede repetir a mensagem).
Uint8List uaPasswordSecret(String password, Uint8List serverNonce) {
  final pwd = utf8.encode(password);
  final len = ByteData(4)..setUint32(0, pwd.length + serverNonce.length, Endian.little);
  return Uint8List.fromList([...len.buffer.asUint8List(), ...pwd, ...serverNonce]);
}

/// Algoritmo da senha cifrada com RSA-OAEP (SHA-1), no campo
/// EncryptionAlgorithm do token.
const String uaRsaOaepUri = 'http://www.w3.org/2001/04/xmlenc#rsa-oaep';

BigInt _toBigInt(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

Uint8List _fromBigInt(BigInt v, int length) {
  final out = Uint8List(length);
  var x = v;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x = x >> 8;
  }
  return out;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Leitor DER mínimo: só o que é preciso para achar a chave no certificado.
class _Der {
  _Der(this._b);
  final Uint8List _b;
  int _p = 0;

  int get peek {
    if (_p >= _b.length) throw const FormatException('certificado cortado');
    return _b[_p];
  }

  /// Tag e conteúdo do próximo elemento.
  (int, Uint8List) _next() {
    if (_p + 2 > _b.length) throw const FormatException('certificado cortado');
    final tag = _b[_p++];
    var len = _b[_p++];
    if (len & 0x80 != 0) {
      final n = len & 0x7F;
      if (n == 0 || n > 4 || _p + n > _b.length) throw const FormatException('tamanho DER inválido no certificado');
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | _b[_p++];
      }
    }
    if (_p + len > _b.length) throw const FormatException('certificado cortado');
    final content = Uint8List.sublistView(_b, _p, _p + len);
    _p += len;
    return (tag, content);
  }

  void skip() => _next();

  Uint8List raw(int expectedTag) {
    final (tag, content) = _next();
    if (tag != expectedTag) throw FormatException('certificado: esperado 0x${expectedTag.toRadixString(16)}, veio 0x${tag.toRadixString(16)}');
    return content;
  }

  _Der sequence() => _Der(raw(0x30));

  BigInt integer() => _toBigInt(raw(0x02));
}
