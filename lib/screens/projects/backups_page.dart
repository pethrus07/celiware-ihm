// Cópias de segurança da planta (menu da planta → Cópias de segurança).
//
// Antes de "Nova planta" ou de substituir a planta por um arquivo, o app
// guarda a planta inteira em `copias/` (PlantStore.backup). Essa pasta é
// privada do app: o seletor de arquivos do Android não a enxerga, então o
// "abra de novo em Novo projeto → De um arquivo" que o aviso prometia não
// funcionava. Aqui a cópia aparece com a data e duas ações:
//
// - Abrir: os projetos da cópia entram SOMADOS aos de agora (como "Somar"
//   ao importar uma planta) — nunca no lugar deles;
// - Enviar: o arquivo vai pela folha de compartilhar do Android (WhatsApp,
//   e-mail, Drive), para guardar fora do celular.
//
// Pouca informação: só a data de cada cópia e as duas ações.

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_info.dart';
import '../../app/app_scope.dart';
import '../../app/project_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/write_actions.dart';

class BackupsPage extends StatefulWidget {
  const BackupsPage({super.key});

  /// "21/10/2026 às 14:32".
  static String when(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} às ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  State<BackupsPage> createState() => _BackupsPageState();
}

class _BackupsPageState extends State<BackupsPage> {
  /// Um toque por vez: abrir lê e grava vários projetos.
  bool _busy = false;

  Future<void> _open(PlantBackup b) async {
    if (_busy) return;
    setState(() => _busy = true);
    final c = AppScope.of(context).controller;
    try {
      final n = await c.restoreBackup(b);
      if (!mounted) return;
      WriteActions.toast(context, n == 1 ? '1 projeto somado à planta.' : '$n projetos somados à planta.');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) WriteActions.toast(context, 'Não consegui abrir a cópia.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(PlantBackup b) async {
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(b.file.path, mimeType: 'application/json')],
        subject: 'Cópia da planta — ${AppInfo.name}',
        text: 'Cópia da planta do ${AppInfo.name} (${BackupsPage.when(b.when)}). Para abrir: Projetos → Novo projeto → De um arquivo.',
      ));
    } catch (e) {
      if (mounted) WriteActions.toast(context, 'Não consegui enviar: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = AppScope.watch(context).controller.backups();
    return Scaffold(
      appBar: AppBar(title: const Text('Cópias de segurança')),
      body: list.isEmpty
          ? const EmptyState(
              icon: Icons.history_rounded,
              title: 'Nenhuma cópia ainda',
              body: 'Antes de trocar a planta inteira, o app guarda uma cópia dela aqui.',
            )
          : FormWidth(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 32),
                children: [
                  // A legenda que muda a decisão: abrir não apaga nada.
                  Padding(
                    padding: const EdgeInsets.only(bottom: Ind.space),
                    child: Text('Abrir soma os projetos da cópia aos de agora. Nada é apagado.', style: TextStyle(color: Ind.textMuted, height: 1.4)),
                  ),
                  for (final b in list) ...[
                    _BackupCard(backup: b, busy: _busy, onOpen: () => _open(b), onShare: () => _share(b)),
                    const SizedBox(height: Ind.space),
                  ],
                ],
              ),
            ),
    );
  }
}

class _BackupCard extends StatelessWidget {
  const _BackupCard({required this.backup, required this.busy, required this.onOpen, required this.onShare});
  final PlantBackup backup;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final name = backup.file.uri.pathSegments.last;
    return Card(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
          child: Row(children: [
            Expanded(
              child: Text(BackupsPage.when(backup.when), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            TextButton(key: ValueKey('abrir-copia-$name'), onPressed: busy ? null : onOpen, child: const Text('Abrir')),
            TextButton(key: ValueKey('enviar-copia-$name'), onPressed: onShare, child: const Text('Enviar')),
          ]),
        ),
      ),
    );
  }
}
