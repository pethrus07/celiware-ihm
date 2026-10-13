import '../../core/modbus/modbus_memory.dart';
import '../../core/utils/ids.dart';
import '../../models/alarm.dart';
import '../../models/device.dart';
import '../../models/hmi_screen.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../models/vendor_profiles.dart';
import 'screen_templates.dart';

/// O que um modelo vira num equipamento: a tela e as variáveis.
class TemplateResult {
  const TemplateResult({required this.screen, required this.created, required this.reused, required this.style, this.profile});

  final HmiScreen screen;

  /// Variáveis novas — o que vai para o projeto.
  final List<Tag> created;

  /// As que o equipamento já tinha (mesmo endereço, ou mesmo nome e tipo
  /// quando o modelo não sabe o endereço): a tela usa essas, sem duplicar.
  final List<Tag> reused;

  final CommandStyle style;

  /// Perfil de inversor cujo mapa deu endereço a alguma variável.
  final VendorProfile? profile;

  /// Variáveis novas com o endereço do mapa da marca.
  int get mapped => created.where((t) => !t.addressPending).length;

  /// Variáveis da tela (novas ou não) com o endereço a configurar.
  int get pending => [...created, ...reused].where((t) => t.addressPending).length;
}

/// Aplica um [ScreenTemplate] num equipamento. Função pura: a tela de "Nova
/// tela" só mostra o resumo e grava o resultado (`saveTags` + `saveScreen`).
abstract final class TemplateBuilder {
  /// Jeito de comandar no [device]: palavra do inversor quando o modelo usa o
  /// mapa, o perfil é de inversor, tem o comando e o estado no mapa e os
  /// códigos são conhecidos; senão, bits.
  static CommandStyle styleFor(ScreenTemplate template, Device device) {
    if (!template.driveMap || !template.hasWordStyle) return CommandStyle.bits;
    final profile = _driveProfile(device);
    if (profile == null || ScreenTemplates.driveCodes[profile.id] == null) return CommandStyle.bits;
    final keys = {for (final t in profile.templates) t.key};
    final needed = template.tags.where((t) => t.only == CommandStyle.word && t.map != null).map((t) => t.map);
    return needed.every(keys.contains) ? CommandStyle.word : CommandStyle.bits;
  }

  /// Monta a tela [screenId] com o nome [name]. Em branco: a tela vazia de
  /// sempre, na grade normal.
  static TemplateResult build(
    ScreenTemplate template, {
    required Project project,
    required Device device,
    required String screenId,
    required String name,
  }) {
    if (template.isBlank) {
      return TemplateResult(screen: HmiScreen(id: screenId, name: name), created: const [], reused: const [], style: CommandStyle.bits);
    }
    final style = styleFor(template, device);
    final profile = template.driveMap ? _driveProfile(device) : null;
    final mapByKey = {for (final t in profile?.templates ?? const <TagTemplate>[]) t.key: t};
    final tagBase = newId('t');
    final alarmBase = newId('al');
    var alarmSeq = 0;

    // O que o equipamento já tem e pode ser reaproveitado.
    final onDevice = project.tags.where((t) => t.deviceId == device.id && !t.isCalc).toList();
    final bySlot = <String, Tag>{
      for (final t in onDevice.reversed)
        if (!t.addressPending) _slot(t): t,
    };

    final ids = <String, String>{};
    final created = <Tag>[];
    final reused = <Tag>[];
    var usedProfile = false;
    for (final (i, tt) in template.tags.where((t) => _in(t.only, style)).indexed) {
      final mapEntry = tt.map == null ? null : mapByKey[tt.map];
      Tag? existing;
      Tag fresh;
      if (mapEntry != null) {
        usedProfile = true;
        fresh = mapEntry.toTag(id: '${tagBase}_$i', deviceId: device.id);
        existing = bySlot[_slot(fresh)];
      } else {
        fresh = Tag(
          id: '${tagBase}_$i',
          name: tt.name,
          deviceId: device.id,
          // Só o tipo de memória mais provável; o endereço fica a configurar.
          area: tt.type == TagDataType.bool ? ModbusArea.coil : ModbusArea.holdingRegister,
          dataType: tt.type,
          length: tt.length,
          writable: tt.writable,
          unit: tt.unit,
          decimals: tt.decimals,
          description: tt.description,
          addressPending: true,
        );
        existing = _sameName(onDevice, tt);
      }
      if (existing != null) {
        ids[tt.key] = existing.id;
        if (!reused.any((t) => t.id == existing!.id)) reused.add(existing);
        continue;
      }
      final alarms = [
        for (final a in tt.alarms)
          AlarmRule(id: '${alarmBase}_${alarmSeq++}', kind: a.kind, limit: a.limit, priority: a.priority, message: a.message),
      ];
      final tag = fresh.copyWith(alarms: alarms).normalized();
      ids[tt.key] = tag.id;
      created.add(tag);
    }

    final codes = style == CommandStyle.word ? ScreenTemplates.driveCodes[profile!.id] : null;
    final elementBase = newId('e');
    final elements = [
      for (final (i, te) in template.elements.where((e) => _in(e.only, style)).indexed)
        HmiElement(
          id: '${elementBase}_$i',
          type: te.type,
          x: te.x,
          y: te.y,
          w: te.w,
          h: te.h,
          props: {
            ...te.props,
            if (te.tag != null) 'tagId': ids[te.tag]!,
            if (te.feedback != null) 'feedbackTagId': ids[te.feedback]!,
            if (te.tags.isNotEmpty) 'tagIds': [for (final k in te.tags) ids[k]!],
            if (te.command != null && codes != null) 'value': codes.valueOf(te.command!),
            if (te.driveStates && codes != null) 'states': codes.states,
          },
        ),
    ];

    return TemplateResult(
      screen: HmiScreen(id: screenId, name: name, columns: ScreenTemplate.columns, elements: elements),
      created: created,
      reused: reused,
      style: style,
      profile: usedProfile ? profile : null,
    );
  }

  /// Perfil de inversor do equipamento (nulo se não tem, ou se é de CLP).
  static VendorProfile? _driveProfile(Device device) {
    final p = VendorProfiles.of(device);
    return p != null && p.kind == ProfileKind.drive ? p : null;
  }

  static bool _in(CommandStyle? only, CommandStyle style) => only == null || only == style;

  /// O mesmo endereço que a conferência do "Criar várias" usa.
  static String _slot(Tag t) => '${t.area.index}:${t.address}:${t.isBitOfRegister ? t.bitIndex : -1}';

  /// Variável do equipamento com o mesmo nome (sem caixa nem acento) e do
  /// mesmo jeito (liga/desliga, número ou texto) — aplicar o modelo duas
  /// vezes, ou num equipamento que já tem "Velocidade", não duplica.
  static Tag? _sameName(List<Tag> tags, TemplateTag tt) {
    final name = _plain(tt.name);
    bool sameKind(Tag t) => switch (tt.type) {
          TagDataType.bool => t.dataType == TagDataType.bool && !t.isArray,
          TagDataType.string => t.isText,
          _ => t.dataType.isNumeric && !t.isArray,
        };
    return tags.where((t) => _plain(t.name) == name && sameKind(t)).firstOrNull;
  }

  static const _accents = {'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'é': 'e', 'ê': 'e', 'í': 'i', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ú': 'u', 'ç': 'c'};

  static String _plain(String s) {
    final b = StringBuffer();
    for (final ch in s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ').split('')) {
      b.write(_accents[ch] ?? ch);
    }
    return b.toString();
  }
}
