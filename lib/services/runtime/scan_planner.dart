import '../../core/modbus/modbus_memory.dart';
import '../../core/modbus/modbus_pdu.dart';
import '../../models/tag.dart';

/// Uma leitura Modbus que atende várias variáveis de uma vez.
class ScanBlock {
  ScanBlock(this.area, this.start, this.count, this.tags);

  final ModbusArea area;
  final int start;
  final int count;
  final List<Tag> tags;

  int get end => start + count - 1;

  @override
  String toString() => '${area.shortLabel} $start..$end (${tags.length} var.)';
}

/// Agrupa as variáveis em uso no menor número de leituras possível.
///
/// Cada ida e volta na rede custa mais que ler alguns registradores a mais,
/// então variáveis da mesma área com endereços próximos viram **um** pedido —
/// mesmo que haja um pequeno buraco entre elas ([maxRegisterGap] /
/// [maxBitGap]). Os limites do protocolo (125 registradores, 2000 bits por
/// leitura) nunca são ultrapassados.
///
/// Função pura: mesma entrada, mesma saída. A [DeviceSession] replaneja
/// sempre que o conjunto de variáveis em uso muda (tela aberta/fechada).
///
/// Variáveis que já deram "endereço inexistente" dentro de um bloco são
/// passadas em [isolated] e ganham leitura própria — assim um endereço errado
/// não apaga a tela inteira, só o elemento dele.
class ScanPlanner {
  const ScanPlanner({this.maxRegisterGap = 8, this.maxBitGap = 32});

  final int maxRegisterGap;
  final int maxBitGap;

  List<ScanBlock> plan(Iterable<Tag> tags, {Set<String> isolated = const {}}) {
    final blocks = <ScanBlock>[];
    final byArea = <ModbusArea, List<Tag>>{};
    for (final t in tags) {
      if (isolated.contains(t.id)) {
        blocks.add(ScanBlock(t.area, t.address, t.span, [t]));
      } else {
        byArea.putIfAbsent(t.area, () => []).add(t);
      }
    }

    for (final entry in byArea.entries) {
      final area = entry.key;
      final limit = area.isBit ? ModbusPdu.maxReadBits : ModbusPdu.maxReadRegisters;
      final gap = area.isBit ? maxBitGap : maxRegisterGap;
      final sorted = entry.value..sort((a, b) => a.address.compareTo(b.address));

      int? start;
      var end = 0;
      var members = <Tag>[];

      void flush() {
        if (start != null) blocks.add(ScanBlock(area, start!, end - start! + 1, members));
        start = null;
        members = [];
      }

      for (final t in sorted) {
        final tEnd = t.lastAddress;
        final fits = start != null &&
            t.address - end - 1 <= gap &&
            (tEnd > end ? tEnd : end) - start! + 1 <= limit;
        if (!fits) {
          flush();
          start = t.address;
          end = tEnd;
        } else if (tEnd > end) {
          end = tEnd;
        }
        members.add(t);
      }
      flush();
    }

    blocks.sort((a, b) {
      final c = a.area.index.compareTo(b.area.index);
      return c != 0 ? c : a.start.compareTo(b.start);
    });
    return blocks;
  }
}
