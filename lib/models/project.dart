import 'device.dart';
import 'hmi_screen.dart';
import 'tag.dart';

/// O projeto inteiro: equipamentos, variáveis e telas.
///
/// É a unidade que vai para o disco e que se **exporta como arquivo**
/// (`.ihm.json`) — o "entregar o arquivo pro dono da máquina" da reunião:
/// quem programa o CLP monta o projeto, manda o arquivo, e o dono importa no
/// celular dele.
///
/// [schemaVersion] sobe quando o formato mudar de jeito incompatível; o
/// [ProjectCodec] migra arquivos antigos na leitura.
class Project {
  const Project({
    this.name = 'Meu projeto',
    this.devices = const [],
    this.tags = const [],
    this.screens = const [],
  });

  static const int schemaVersion = 1;

  final String name;
  final List<Device> devices;
  final List<Tag> tags;
  final List<HmiScreen> screens;

  bool get isEmpty => devices.isEmpty && tags.isEmpty && screens.isEmpty;

  Device? device(String id) => _firstWhere(devices, (d) => d.id == id);
  Tag? tag(String id) => _firstWhere(tags, (t) => t.id == id);
  HmiScreen? screen(String id) => _firstWhere(screens, (s) => s.id == id);

  List<Tag> tagsOf(String deviceId) =>
      tags.where((t) => t.deviceId == deviceId).toList();

  /// Telas que usam a variável — para avisar antes de apagar.
  List<HmiScreen> screensUsingTag(String tagId) =>
      screens.where((s) => s.tagIds.contains(tagId)).toList();

  Project copyWith({
    String? name,
    List<Device>? devices,
    List<Tag>? tags,
    List<HmiScreen>? screens,
  }) =>
      Project(
        name: name ?? this.name,
        devices: devices ?? this.devices,
        tags: tags ?? this.tags,
        screens: screens ?? this.screens,
      );

  // ── Edições (sempre devolvem um projeto novo) ────────────────────────────────

  Project upsertDevice(Device d) => copyWith(devices: _upsert(devices, d, (x) => x.id));
  Project upsertTag(Tag t) => copyWith(tags: _upsert(tags, t.normalized(), (x) => x.id));
  Project upsertScreen(HmiScreen s) => copyWith(screens: _upsert(screens, s, (x) => x.id));

  /// Várias variáveis de uma vez (Criar várias, CSV). Com índice por id: mil
  /// [upsertTag] seguidos seriam mil cópias da lista inteira.
  Project upsertTags(Iterable<Tag> list) {
    final next = [...tags];
    final index = {for (var i = 0; i < next.length; i++) next[i].id: i};
    for (final t in list) {
      final n = t.normalized();
      final i = index[n.id];
      if (i == null) {
        index[n.id] = next.length;
        next.add(n);
      } else {
        next[i] = n;
      }
    }
    return copyWith(tags: next);
  }

  /// Apaga o equipamento **e** as variáveis dele. Elementos de tela que
  /// apontavam para elas ficam "sem variável" (mostram aviso), não somem —
  /// o usuário decide o que fazer com eles.
  Project removeDevice(String id) => copyWith(
        devices: devices.where((d) => d.id != id).toList(),
        tags: tags.where((t) => t.deviceId != id).toList(),
      );

  Project removeTag(String id) => copyWith(tags: tags.where((t) => t.id != id).toList());
  Project removeScreen(String id) => copyWith(screens: screens.where((s) => s.id != id).toList());

  Map<String, dynamic> toJson() => {
        'format': 'celiware-ihm',
        'schemaVersion': schemaVersion,
        'name': name,
        'devices': [for (final d in devices) d.toJson()],
        'tags': [for (final t in tags) t.toJson()],
        'screens': [for (final s in screens) s.toJson()],
      };

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        name: (j['name'] as String?) ?? 'Meu projeto',
        devices: [
          for (final d in (j['devices'] as List? ?? const []))
            Device.fromJson(Map<String, dynamic>.from(d as Map)),
        ],
        tags: [
          for (final t in (j['tags'] as List? ?? const []))
            Tag.fromJson(Map<String, dynamic>.from(t as Map)),
        ],
        screens: [
          for (final s in (j['screens'] as List? ?? const []))
            HmiScreen.fromJson(Map<String, dynamic>.from(s as Map)),
        ],
      );

  static T? _firstWhere<T>(List<T> list, bool Function(T) test) {
    for (final x in list) {
      if (test(x)) return x;
    }
    return null;
  }

  static List<T> _upsert<T>(List<T> list, T item, String Function(T) id) {
    final i = list.indexWhere((x) => id(x) == id(item));
    if (i < 0) return [...list, item];
    return [...list]..[i] = item;
  }
}
