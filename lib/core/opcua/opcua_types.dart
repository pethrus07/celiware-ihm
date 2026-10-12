/// Tipos do OPC UA que o cliente usa: NodeId, valores (Variant, DataValue),
/// nomes e as descrições que vêm do servidor (endpoint, referência).
///
/// Só o subconjunto de uma IHM: ler, gravar e navegar. Estruturas próprias
/// do servidor (ExtensionObject com corpo) viajam como bytes e não viram
/// valor de variável.
library;

import 'dart:convert';
import 'dart:typed_data';

// ── NodeId ─────────────────────────────────────────────────────────────────────

/// Forma do identificador dentro do namespace.
enum NodeIdKind {
  /// `i=1001`
  numeric,

  /// `s=Maquina.Temperatura` — o mais comum em CLP (no S7-1500,
  /// `s="DB1"."Velocidade"`).
  string,

  /// `g=72962B91-FA75-4AE6-8D28-B404DC7DAF63`
  guid,

  /// `b=AQID` (bytes em base64)
  opaque,
}

/// Endereço de um nó no servidor: namespace + identificador.
///
/// O texto segue a notação da norma (Parte 6, 5.3.1.10), a mesma que
/// UaExpert, Kepware e o TIA Portal mostram: `ns=2;s=Maquina.Temperatura`,
/// `ns=3;i=1001`, `i=2258` (namespace 0 omitido).
class NodeId {
  const NodeId.numeric(this.namespace, int id)
      : kind = NodeIdKind.numeric,
        _value = id;
  const NodeId.string(this.namespace, String id)
      : kind = NodeIdKind.string,
        _value = id;

  /// [guid] em texto canônico, maiúsculo (`72962B91-FA75-…`).
  NodeId.guid(this.namespace, String guid)
      : kind = NodeIdKind.guid,
        _value = guid.toUpperCase();
  NodeId.opaque(this.namespace, Uint8List bytes)
      : kind = NodeIdKind.opaque,
        _value = bytes;

  final int namespace;
  final NodeIdKind kind;
  final Object _value;

  /// `int` (numérico), `String` (texto e GUID) ou `Uint8List` (opaco).
  Object get identifier => _value;

  /// O NodeId nulo (ns=0;i=0): "sem nó", como no token de sessão antes de
  /// a sessão existir.
  static const NodeId nullId = NodeId.numeric(0, 0);

  bool get isNull => kind == NodeIdKind.numeric && namespace == 0 && _value == 0;

  /// Pasta "Objects" — onde a navegação começa.
  static const NodeId objectsFolder = NodeId.numeric(0, 85);

  /// O objeto "Server" (diagnóstico do próprio servidor): fica fora da
  /// navegação do operador.
  static const NodeId server = NodeId.numeric(0, 2253);

  /// Estado do servidor (Server_ServerStatus_State): o "ping" lê este nó.
  static const NodeId serverState = NodeId.numeric(0, 2259);

  /// Limites de operação: quantos nós cabem numa leitura e numa escrita.
  static const NodeId maxNodesPerRead = NodeId.numeric(0, 11705);
  static const NodeId maxNodesPerWrite = NodeId.numeric(0, 11707);

  /// Referências hierárquicas (pasta → filho), usadas na navegação.
  static const NodeId hierarchicalReferences = NodeId.numeric(0, 33);

  /// Lê o texto da norma. Lança [FormatException] com a mensagem curta, em
  /// português, que o cadastro mostra embaixo do campo.
  static NodeId parse(String text) {
    final s = text.trim();
    if (s.isEmpty) throw const FormatException('Informe o NodeId (ex.: ns=2;s=Maquina.Temperatura)');
    var rest = s;
    var ns = 0;
    final lower = rest.toLowerCase();
    if (lower.startsWith('nsu=')) {
      throw const FormatException('nsu= (namespace pelo endereço) ainda não é aceito: use ns= com o número');
    }
    if (lower.startsWith('ns=')) {
      final semi = rest.indexOf(';');
      if (semi < 0) throw FormatException('$s: falta o ";" depois do namespace (ex.: ns=2;s=Temperatura)');
      final n = int.tryParse(rest.substring(3, semi).trim());
      if (n == null || n < 0 || n > 0xFFFF) throw const FormatException('o namespace (ns=) vai de 0 a 65535');
      ns = n;
      rest = rest.substring(semi + 1).trimLeft();
    }
    if (rest.length < 2 || rest[1] != '=') {
      throw FormatException('$s: falta o tipo do identificador — i=, s=, g= ou b= (ex.: ns=2;s=Temperatura)');
    }
    final id = rest.substring(2);
    switch (rest[0].toLowerCase()) {
      case 'i':
        final v = int.tryParse(id.trim());
        if (v == null || v < 0 || v > 0xFFFFFFFF) throw const FormatException('i= pede um número inteiro (ex.: ns=2;i=1001)');
        return NodeId.numeric(ns, v);
      case 's':
        if (id.isEmpty) throw const FormatException('s= pede um nome (ex.: ns=2;s=Temperatura)');
        return NodeId.string(ns, id);
      case 'g':
        final g = id.trim();
        if (!_guid.hasMatch(g)) throw const FormatException('g= pede um GUID (ex.: g=72962B91-FA75-4AE6-8D28-B404DC7DAF63)');
        return NodeId.guid(ns, g);
      case 'b':
        try {
          return NodeId.opaque(ns, base64.decode(id.trim()));
        } on FormatException {
          throw const FormatException('b= pede bytes em base64 (ex.: b=AQID)');
        }
      default:
        throw FormatException('$s: o tipo do identificador é i=, s=, g= ou b=');
    }
  }

  static NodeId? tryParse(String text) {
    try {
      return parse(text);
    } on FormatException {
      return null;
    }
  }

  static final RegExp _guid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  /// O texto canônico: `ns=2;s=Maquina.Temperatura`, `i=85`.
  @override
  String toString() {
    final prefix = namespace == 0 ? '' : 'ns=$namespace;';
    return switch (kind) {
      NodeIdKind.numeric => '${prefix}i=$_value',
      NodeIdKind.string => '${prefix}s=$_value',
      NodeIdKind.guid => '${prefix}g=$_value',
      NodeIdKind.opaque => '${prefix}b=${base64.encode(_value as Uint8List)}',
    };
  }

  @override
  bool operator ==(Object other) {
    if (other is! NodeId || other.namespace != namespace || other.kind != kind) return false;
    if (kind != NodeIdKind.opaque) return other._value == _value;
    final a = _value as Uint8List, b = other._value as Uint8List;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => kind == NodeIdKind.opaque ? Object.hash(namespace, kind, Object.hashAll(_value as Uint8List)) : Object.hash(namespace, kind, _value);
}

// ── Nomes ──────────────────────────────────────────────────────────────────────

/// Nome com namespace (BrowseName).
class QualifiedName {
  const QualifiedName(this.namespace, this.name);
  final int namespace;
  final String? name;

  @override
  String toString() => namespace == 0 ? name ?? '' : '$namespace:${name ?? ''}';
}

/// Texto com idioma (DisplayName).
class LocalizedText {
  const LocalizedText(this.text, {this.locale});
  final String? text;
  final String? locale;

  @override
  String toString() => text ?? '';
}

// ── Valores ────────────────────────────────────────────────────────────────────

/// Tipos embutidos do OPC UA (Parte 6, 5.1.2), com o número que vai na
/// codificação do Variant.
enum UaType {
  boolean(1),
  sbyte(2),
  byte(3),
  int16(4),
  uint16(5),
  int32(6),
  uint32(7),
  int64(8),
  uint64(9),
  float(10),
  double(11),
  string(12),
  dateTime(13),
  guid(14),
  byteString(15),
  xmlElement(16),
  nodeId(17),
  expandedNodeId(18),
  statusCode(19),
  qualifiedName(20),
  localizedText(21),
  extensionObject(22),
  dataValue(23),
  variant(24),
  diagnosticInfo(25);

  const UaType(this.id);
  final int id;

  static UaType? byId(int id) => id >= 1 && id <= 25 ? UaType.values[id - 1] : null;

  /// Inteiro (com ou sem sinal, de 8 a 64 bits).
  bool get isInteger => id >= 2 && id <= 9;
  bool get isNumber => isInteger || this == float || this == double;

  /// Faixa dos inteiros, para conferir a gravação antes da rede. UInt64 vai
  /// até o maior inteiro do Dart.
  (int, int)? get range => switch (this) {
        sbyte => (-128, 127),
        byte => (0, 0xFF),
        int16 => (-32768, 32767),
        uint16 => (0, 0xFFFF),
        int32 => (-2147483648, 2147483647),
        uint32 => (0, 0xFFFFFFFF),
        int64 => (-0x8000000000000000, 0x7FFFFFFFFFFFFFFF),
        uint64 => (0, 0x7FFFFFFFFFFFFFFF),
        _ => null,
      };

  /// Nome como os servidores mostram ("Double", "UInt16").
  String get label => switch (this) {
        boolean => 'Boolean',
        sbyte => 'SByte',
        byte => 'Byte',
        int16 => 'Int16',
        uint16 => 'UInt16',
        int32 => 'Int32',
        uint32 => 'UInt32',
        int64 => 'Int64',
        uint64 => 'UInt64',
        float => 'Float',
        double => 'Double',
        string => 'String',
        dateTime => 'DateTime',
        guid => 'Guid',
        byteString => 'ByteString',
        xmlElement => 'XmlElement',
        nodeId => 'NodeId',
        expandedNodeId => 'ExpandedNodeId',
        statusCode => 'StatusCode',
        qualifiedName => 'QualifiedName',
        localizedText => 'LocalizedText',
        extensionObject => 'ExtensionObject',
        dataValue => 'DataValue',
        variant => 'Variant',
        diagnosticInfo => 'DiagnosticInfo',
      };
}

/// Um valor com o tipo dele, como viaja no protocolo.
///
/// [value] é `bool`, `int`, `double`, `String`, `DateTime`, `Uint8List`,
/// [NodeId], [QualifiedName], [LocalizedText] ou [UaExtensionObject] — ou uma
/// `List` deles em [isArray]. Variant vazio: [type] nulo.
class UaVariant {
  const UaVariant(this.type, this.value, {this.isArray = false, this.dimensions});

  /// Variant vazio (sem valor).
  static const UaVariant empty = UaVariant(null, null);

  final UaType? type;
  final Object? value;
  final bool isArray;

  /// Dimensões de matriz (raro em IHM: guardado, não interpretado).
  final List<int>? dimensions;

  bool get isEmpty => type == null;

  @override
  String toString() => isEmpty ? 'vazio' : '${type!.label}${isArray ? '[]' : ''} $value';
}

/// Corpo de um tipo estruturado do servidor — guardado como bytes.
class UaExtensionObject {
  const UaExtensionObject(this.typeId, this.body);
  final NodeId typeId;
  final Uint8List? body;
}

/// Valor lido, com a qualidade (StatusCode) e os horários.
class UaDataValue {
  const UaDataValue({this.value = UaVariant.empty, this.status = 0, this.sourceTimestamp, this.serverTimestamp});

  final UaVariant value;

  /// StatusCode: 0 = bom; bit mais alto ligado = ruim (ver [UaStatus]).
  final int status;
  final DateTime? sourceTimestamp;
  final DateTime? serverTimestamp;
}

/// Atributos de um nó (Parte 6, A.1) — só os que o app lê.
abstract final class UaAttribute {
  static const int nodeClass = 2;
  static const int browseName = 3;
  static const int displayName = 4;
  static const int value = 13;
  static const int dataType = 14;
  static const int accessLevel = 17;
  static const int userAccessLevel = 18;

  /// Bits do AccessLevel.
  static const int canRead = 0x01;
  static const int canWrite = 0x02;
}

/// Classe do nó (Parte 3, 5.2): o que ele é.
enum UaNodeClass {
  unspecified(0),
  object(1),
  variable(2),
  method(4),
  objectType(8),
  variableType(16),
  referenceType(32),
  dataType(64),
  view(128);

  const UaNodeClass(this.code);
  final int code;

  static UaNodeClass of(int code) => UaNodeClass.values.firstWhere((c) => c.code == code, orElse: () => unspecified);
}

/// Uma referência devolvida pela navegação (Browse): um filho do nó.
class UaReference {
  const UaReference({
    required this.referenceTypeId,
    required this.isForward,
    required this.nodeId,
    required this.browseName,
    required this.displayName,
    required this.nodeClass,
    required this.typeDefinition,
    this.serverIndex = 0,
  });

  final NodeId referenceTypeId;
  final bool isForward;
  final NodeId nodeId;
  final QualifiedName browseName;
  final LocalizedText displayName;
  final UaNodeClass nodeClass;
  final NodeId typeDefinition;

  /// Nó em outro servidor (≠ 0): o app não segue.
  final int serverIndex;

  /// O nome que aparece para o operador.
  String get name {
    final d = displayName.text;
    return d != null && d.isNotEmpty ? d : (browseName.name ?? nodeId.toString());
  }
}

/// Uma regra de identificação do usuário oferecida pelo servidor num
/// endpoint (anônimo, usuário e senha, certificado...).
class UaUserTokenPolicy {
  const UaUserTokenPolicy({required this.policyId, required this.tokenType, this.securityPolicyUri});

  final String policyId;

  /// 0 anônimo, 1 usuário e senha, 2 certificado, 3 token emitido.
  final int tokenType;

  /// Como a senha deve ir cifrada; nulo ou None = como está.
  final String? securityPolicyUri;

  static const int anonymous = 0;
  static const int userName = 1;
}

/// Um jeito de conectar no servidor: endereço, segurança e usuários aceitos.
class UaEndpoint {
  const UaEndpoint({
    required this.endpointUrl,
    required this.securityMode,
    required this.securityPolicyUri,
    required this.userTokens,
    this.serverCertificate,
  });

  final String endpointUrl;

  /// 1 None, 2 Sign, 3 SignAndEncrypt.
  final int securityMode;
  final String securityPolicyUri;
  final List<UaUserTokenPolicy> userTokens;
  final Uint8List? serverCertificate;

  bool get isNone => securityMode == UaSecurity.modeNone;

  /// "Basic256Sha256 · SignAndEncrypt" — para dizer o que o servidor exige.
  String get label => '${UaSecurity.policyName(securityPolicyUri)} · ${UaSecurity.modeName(securityMode)}';
}

/// Políticas e modos de segurança.
abstract final class UaSecurity {
  static const String policyNone = 'http://opcfoundation.org/UA/SecurityPolicy#None';
  static const String policyBasic256Sha256 = 'http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256';
  static const String policyBasic256 = 'http://opcfoundation.org/UA/SecurityPolicy#Basic256';
  static const String policyAes128Sha256RsaOaep = 'http://opcfoundation.org/UA/SecurityPolicy#Aes128_Sha256_RsaOaep';

  static const int modeNone = 1;
  static const int modeSign = 2;
  static const int modeSignAndEncrypt = 3;

  /// Política sem cifra (ou ausente).
  static bool isNone(String? uri) => uri == null || uri.isEmpty || uri == policyNone;

  static String policyName(String? uri) => isNone(uri) ? 'None' : uri!.substring(uri.lastIndexOf('#') + 1);

  static String modeName(int mode) => switch (mode) {
        modeNone => 'None',
        modeSign => 'Sign',
        modeSignAndEncrypt => 'SignAndEncrypt',
        _ => 'modo $mode',
      };
}
