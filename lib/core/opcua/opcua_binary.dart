/// Codificação binária do OPC UA (Parte 6, 5.2 — "OPC UA Binary").
///
/// Tudo little-endian. Texto e bytes levam o tamanho na frente (Int32; −1 =
/// nulo). Funções puras sobre um buffer, testáveis sem rede: os testes
/// conferem byte a byte contra vetores gerados pelo asyncua.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'opcua_types.dart';

/// Diferença entre 1601-01-01 (época do OPC UA) e 1970-01-01, em unidades de
/// 100 ns.
const int _epochTicks = 116444736000000000;

/// Monta uma mensagem campo a campo.
class UaWriter {
  final BytesBuilder _out = BytesBuilder();
  final ByteData _scratch = ByteData(8);

  int get length => _out.length;

  Uint8List takeBytes() => _out.takeBytes();
  Uint8List toBytes() => _out.toBytes();

  void bytes(List<int> b) => _out.add(b);

  void boolean(bool v) => _out.addByte(v ? 1 : 0);
  void byte(int v) => _out.addByte(v & 0xFF);
  void sbyte(int v) => _out.addByte(v & 0xFF);

  void _put(int n) => _out.add(Uint8List.sublistView(_scratch, 0, n));

  void int16(int v) {
    _scratch.setInt16(0, v, Endian.little);
    _put(2);
  }

  void uint16(int v) {
    _scratch.setUint16(0, v, Endian.little);
    _put(2);
  }

  void int32(int v) {
    _scratch.setInt32(0, v, Endian.little);
    _put(4);
  }

  void uint32(int v) {
    _scratch.setUint32(0, v, Endian.little);
    _put(4);
  }

  void int64(int v) {
    _scratch.setInt64(0, v, Endian.little);
    _put(8);
  }

  void uint64(int v) {
    _scratch.setUint64(0, v, Endian.little);
    _put(8);
  }

  void float(double v) {
    _scratch.setFloat32(0, v, Endian.little);
    _put(4);
  }

  void float64(double v) {
    _scratch.setFloat64(0, v, Endian.little);
    _put(8);
  }

  /// Texto UTF-8; nulo vira tamanho −1.
  void string(String? v) {
    if (v == null) {
      int32(-1);
      return;
    }
    final b = utf8.encode(v);
    int32(b.length);
    _out.add(b);
  }

  void byteString(List<int>? v) {
    if (v == null) {
      int32(-1);
      return;
    }
    int32(v.length);
    _out.add(v);
  }

  /// Nulo vira 0 ("sem data").
  void dateTime(DateTime? v) => int64(v == null ? 0 : v.toUtc().microsecondsSinceEpoch * 10 + _epochTicks);

  void statusCode(int v) => uint32(v);

  void guid(String text) {
    final h = text.replaceAll('-', '');
    int p(int from, int len) => int.parse(h.substring(from, from + len), radix: 16);
    uint32(p(0, 8));
    uint16(p(8, 4));
    uint16(p(12, 4));
    for (var i = 16; i < 32; i += 2) {
      byte(p(i, 2));
    }
  }

  /// NodeId na forma mais curta que cabe: 2 bytes (ns 0, até 255), 4 bytes
  /// (ns até 255, id até 65535) ou completa.
  void nodeId(NodeId n, {int flags = 0}) {
    switch (n.kind) {
      case NodeIdKind.numeric:
        final id = n.identifier as int;
        if (n.namespace == 0 && id <= 0xFF) {
          byte(0x00 | flags);
          byte(id);
        } else if (n.namespace <= 0xFF && id <= 0xFFFF) {
          byte(0x01 | flags);
          byte(n.namespace);
          uint16(id);
        } else {
          byte(0x02 | flags);
          uint16(n.namespace);
          uint32(id);
        }
      case NodeIdKind.string:
        byte(0x03 | flags);
        uint16(n.namespace);
        string(n.identifier as String);
      case NodeIdKind.guid:
        byte(0x04 | flags);
        uint16(n.namespace);
        guid(n.identifier as String);
      case NodeIdKind.opaque:
        byte(0x05 | flags);
        uint16(n.namespace);
        byteString(n.identifier as Uint8List);
    }
  }

  void qualifiedName(QualifiedName q) {
    uint16(q.namespace);
    string(q.name);
  }

  void localizedText(LocalizedText t) {
    final mask = (t.locale != null ? 0x01 : 0) | (t.text != null ? 0x02 : 0);
    byte(mask);
    if (t.locale != null) string(t.locale);
    if (t.text != null) string(t.text);
  }

  /// ExtensionObject com corpo binário já codificado ([body] nulo = vazio).
  void extensionObject(NodeId typeId, [List<int>? body]) {
    nodeId(typeId);
    if (body == null) {
      byte(0x00);
      return;
    }
    byte(0x01);
    byteString(body);
  }

  /// Lista: Int32 com o tamanho (−1 = nula) e os itens.
  void array<T>(List<T>? items, void Function(T item) write) {
    if (items == null) {
      int32(-1);
      return;
    }
    int32(items.length);
    for (final it in items) {
      write(it);
    }
  }

  void variant(UaVariant v) {
    final type = v.type;
    if (type == null) {
      byte(0);
      return;
    }
    final dims = v.dimensions;
    byte(type.id | (v.isArray ? 0x80 : 0) | (v.isArray && dims != null ? 0x40 : 0));
    if (v.isArray) {
      final list = v.value as List;
      int32(list.length);
      for (final e in list) {
        _scalar(type, e);
      }
      if (dims != null) array<int>(dims, int32);
    } else {
      _scalar(type, v.value);
    }
  }

  void _scalar(UaType type, Object? v) {
    switch (type) {
      case UaType.boolean:
        boolean(v as bool);
      case UaType.sbyte:
        sbyte(v as int);
      case UaType.byte:
        byte(v as int);
      case UaType.int16:
        int16(v as int);
      case UaType.uint16:
        uint16(v as int);
      case UaType.int32:
        int32(v as int);
      case UaType.uint32:
        uint32(v as int);
      case UaType.int64:
        int64(v as int);
      case UaType.uint64:
        uint64(v as int);
      case UaType.float:
        float((v as num).toDouble());
      case UaType.double:
        float64((v as num).toDouble());
      case UaType.string:
      case UaType.xmlElement:
        string(v as String?);
      case UaType.dateTime:
        dateTime(v as DateTime?);
      case UaType.guid:
        guid(v as String);
      case UaType.byteString:
        byteString(v as List<int>?);
      case UaType.nodeId:
        nodeId(v as NodeId);
      case UaType.statusCode:
        statusCode(v as int);
      case UaType.qualifiedName:
        qualifiedName(v as QualifiedName);
      case UaType.localizedText:
        localizedText(v as LocalizedText);
      case UaType.extensionObject:
        final x = v as UaExtensionObject;
        extensionObject(x.typeId, x.body);
      case UaType.expandedNodeId:
      case UaType.dataValue:
      case UaType.variant:
      case UaType.diagnosticInfo:
        throw ArgumentError('${type.label} não é gravado por este cliente');
    }
  }

  /// DataValue só com o valor: na gravação, mandar StatusCode ou horário faz
  /// muito servidor recusar (BadWriteNotSupported, comum no S7-1500).
  void dataValue(UaDataValue d, {bool valueOnly = false}) {
    final hasStatus = !valueOnly && d.status != 0;
    final hasSource = !valueOnly && d.sourceTimestamp != null;
    final hasServer = !valueOnly && d.serverTimestamp != null;
    byte((d.value.isEmpty ? 0 : 0x01) | (hasStatus ? 0x02 : 0) | (hasSource ? 0x04 : 0) | (hasServer ? 0x08 : 0));
    if (!d.value.isEmpty) variant(d.value);
    if (hasStatus) statusCode(d.status);
    if (hasSource) dateTime(d.sourceTimestamp);
    if (hasServer) dateTime(d.serverTimestamp);
  }
}

/// Lê uma mensagem campo a campo. Mensagem curta demais ou campo impossível
/// lança [FormatException].
class UaReader {
  UaReader(Uint8List bytes, [this._pos = 0])
      : _bytes = bytes,
        _data = ByteData.sublistView(bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _pos;

  int get position => _pos;
  int get remaining => _bytes.length - _pos;
  bool get atEnd => _pos >= _bytes.length;

  void _need(int n) {
    if (n < 0 || _pos + n > _bytes.length) {
      throw FormatException('mensagem OPC UA cortada (precisava de $n bytes na posição $_pos de ${_bytes.length})');
    }
  }

  Uint8List bytes(int n) {
    _need(n);
    final b = Uint8List.sublistView(_bytes, _pos, _pos + n);
    _pos += n;
    return b;
  }

  /// O resto da mensagem.
  Uint8List rest() => bytes(remaining);

  bool boolean() => byte() != 0;

  int byte() {
    _need(1);
    return _bytes[_pos++];
  }

  int sbyte() {
    _need(1);
    return _data.getInt8(_pos++);
  }

  int int16() {
    _need(2);
    final v = _data.getInt16(_pos, Endian.little);
    _pos += 2;
    return v;
  }

  int uint16() {
    _need(2);
    final v = _data.getUint16(_pos, Endian.little);
    _pos += 2;
    return v;
  }

  int int32() {
    _need(4);
    final v = _data.getInt32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int uint32() {
    _need(4);
    final v = _data.getUint32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int int64() {
    _need(8);
    final v = _data.getInt64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  int uint64() {
    _need(8);
    final v = _data.getUint64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  double float() {
    _need(4);
    final v = _data.getFloat32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  double float64() {
    _need(8);
    final v = _data.getFloat64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  int _length() {
    final n = int32();
    if (n < -1) throw FormatException('tamanho negativo ($n) na mensagem OPC UA');
    return n;
  }

  String? string() {
    final n = _length();
    if (n < 0) return null;
    return utf8.decode(bytes(n), allowMalformed: true);
  }

  Uint8List? byteString() {
    final n = _length();
    if (n < 0) return null;
    return Uint8List.fromList(bytes(n));
  }

  /// 0 e o maior Int64 são "sem data" (nulo).
  DateTime? dateTime() {
    final t = int64();
    if (t <= 0 || t == 0x7FFFFFFFFFFFFFFF) return null;
    return DateTime.fromMicrosecondsSinceEpoch((t - _epochTicks) ~/ 10, isUtc: true);
  }

  int statusCode() => uint32();

  String guid() {
    String h(int v, int len) => v.toRadixString(16).padLeft(len, '0');
    final d1 = uint32(), d2 = uint16(), d3 = uint16();
    final d4 = bytes(8);
    final tail = d4.map((b) => h(b, 2)).join();
    return '${h(d1, 8)}-${h(d2, 4)}-${h(d3, 4)}-${tail.substring(0, 4)}-${tail.substring(4)}'.toUpperCase();
  }

  /// NodeId em qualquer uma das seis formas da norma.
  NodeId nodeId() => _nodeId(byte() & 0x3F);

  NodeId _nodeId(int form) {
    switch (form) {
      case 0x00:
        return NodeId.numeric(0, byte());
      case 0x01:
        final ns = byte();
        return NodeId.numeric(ns, uint16());
      case 0x02:
        final ns = uint16();
        return NodeId.numeric(ns, uint32());
      case 0x03:
        final ns = uint16();
        return NodeId.string(ns, string() ?? '');
      case 0x04:
        final ns = uint16();
        return NodeId.guid(ns, guid());
      case 0x05:
        final ns = uint16();
        return NodeId.opaque(ns, byteString() ?? Uint8List(0));
      default:
        throw FormatException('forma de NodeId desconhecida (0x${form.toRadixString(16)})');
    }
  }

  /// ExpandedNodeId: o NodeId, a URI do namespace (opcional) e o índice do
  /// servidor (opcional). O app usa o NodeId e o índice do servidor.
  (NodeId, int) expandedNodeId() {
    final first = byte();
    final id = _nodeId(first & 0x3F);
    if (first & 0x80 != 0) string(); // URI do namespace: não usada
    final server = first & 0x40 != 0 ? uint32() : 0;
    return (id, server);
  }

  QualifiedName qualifiedName() {
    final ns = uint16();
    return QualifiedName(ns, string());
  }

  LocalizedText localizedText() {
    final mask = byte();
    final locale = mask & 0x01 != 0 ? string() : null;
    final text = mask & 0x02 != 0 ? string() : null;
    return LocalizedText(text, locale: locale);
  }

  UaExtensionObject extensionObject() {
    final type = nodeId();
    final encoding = byte();
    if (encoding == 0) return UaExtensionObject(type, null);
    return UaExtensionObject(type, byteString());
  }

  List<T> array<T>(T Function() read) {
    final n = _length();
    if (n <= 0) return <T>[];
    // Cada item ocupa ao menos 1 byte: tamanho maior que o resto é lixo.
    if (n > remaining) throw FormatException('lista de $n itens com só $remaining bytes');
    return [for (var i = 0; i < n; i++) read()];
  }

  /// DiagnosticInfo: o app não usa; lê para pular.
  void diagnosticInfo() {
    final mask = byte();
    if (mask & 0x01 != 0) int32(); // SymbolicId
    if (mask & 0x02 != 0) int32(); // NamespaceUri
    if (mask & 0x08 != 0) int32(); // Locale
    if (mask & 0x04 != 0) int32(); // LocalizedText
    if (mask & 0x10 != 0) string(); // AdditionalInfo
    if (mask & 0x20 != 0) statusCode(); // InnerStatusCode
    if (mask & 0x40 != 0) diagnosticInfo(); // InnerDiagnosticInfo
  }

  UaVariant variant() {
    final mask = byte();
    final id = mask & 0x3F;
    if (id == 0) return UaVariant.empty;
    final type = UaType.byId(id);
    if (type == null) throw FormatException('tipo de Variant desconhecido ($id)');
    if (mask & 0x80 == 0) return UaVariant(type, _scalar(type));
    final n = _length();
    if (n > remaining) throw FormatException('lista de $n valores com só $remaining bytes');
    final values = [for (var i = 0; i < n; i++) _scalar(type)];
    final dims = mask & 0x40 != 0 ? array(int32) : null;
    return UaVariant(type, values, isArray: true, dimensions: dims);
  }

  Object? _scalar(UaType type) {
    switch (type) {
      case UaType.boolean:
        return boolean();
      case UaType.sbyte:
        return sbyte();
      case UaType.byte:
        return byte();
      case UaType.int16:
        return int16();
      case UaType.uint16:
        return uint16();
      case UaType.int32:
        return int32();
      case UaType.uint32:
        return uint32();
      case UaType.int64:
        return int64();
      case UaType.uint64:
        return uint64();
      case UaType.float:
        return float();
      case UaType.double:
        return float64();
      case UaType.string:
      case UaType.xmlElement:
        return string();
      case UaType.dateTime:
        return dateTime();
      case UaType.guid:
        return guid();
      case UaType.byteString:
        return byteString();
      case UaType.nodeId:
        return nodeId();
      case UaType.expandedNodeId:
        return expandedNodeId().$1;
      case UaType.statusCode:
        return statusCode();
      case UaType.qualifiedName:
        return qualifiedName();
      case UaType.localizedText:
        return localizedText();
      case UaType.extensionObject:
        return extensionObject();
      case UaType.dataValue:
        return dataValue();
      case UaType.variant:
        return variant();
      case UaType.diagnosticInfo:
        diagnosticInfo();
        return null;
    }
  }

  UaDataValue dataValue() {
    final mask = byte();
    final value = mask & 0x01 != 0 ? variant() : UaVariant.empty;
    final status = mask & 0x02 != 0 ? statusCode() : 0;
    final source = mask & 0x04 != 0 ? dateTime() : null;
    if (mask & 0x10 != 0) uint16(); // picossegundos da origem
    final server = mask & 0x08 != 0 ? dateTime() : null;
    if (mask & 0x20 != 0) uint16(); // picossegundos do servidor
    return UaDataValue(value: value, status: status, sourceTimestamp: source, serverTimestamp: server);
  }
}
