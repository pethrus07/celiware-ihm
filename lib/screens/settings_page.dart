// Ajustes (engrenagem no topo da aba Projetos): o que é do aparelho e do
// app, não do projeto — aparência, tutoriais, sobre e privacidade. Era a
// parte de baixo da antiga aba "Mais"; as ferramentas de monitoramento
// foram para a aba Ferramentas (reunião de 19–20/10/2026: estavam
// "escondidas" em Mais).

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../app/app_info.dart';
import '../app/app_scope.dart';
import '../app/appearance.dart';
import '../core/theme/app_theme.dart';
import '../services/demo/demo_project.dart';
import '../widgets/common/adaptive.dart';
import '../widgets/common/common.dart';
import '../widgets/hmi/write_actions.dart';
import '../widgets/tour/tour.dart';
import 'devices/devices_page.dart';
import 'editor/screen_editor_page.dart';
import 'privacy_page.dart';
import 'screen_run_page.dart';
import 'shell.dart';
import 'tags/tags_page.dart';
import 'tours.dart';

/// Engrenagem do topo: abre os Ajustes.
class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        key: const ValueKey('ajustes'),
        tooltip: 'Ajustes',
        icon: const Icon(Icons.settings_outlined),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
      );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // Alvos do tutorial do "?".
  final _deviceKey = GlobalKey();
  final _tutorialsKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return TourHost(
      spec: Tours.ajustes(device: _deviceKey, tutorials: _tutorialsKey),
      autoStart: false,
      child: Scaffold(
        appBar: AppBar(title: const Text('Ajustes'), actions: const [HelpButton()]),
        // No tablet, a coluna dos ajustes não estica até a borda (TB-3).
        body: FormWidth(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            // A lista é curta: monta tudo, para o tutorial achar os itens de baixo.
            scrollCacheExtent: const ScrollCacheExtent.pixels(4000),
            children: [
              const SectionHeader('Aparência'),
              Padding(
                key: _deviceKey,
                padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 4),
                child: ValueListenableBuilder<Appearance>(
                  valueListenable: AppearanceController.instance,
                  builder: (context, a, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ChoiceCards<Appearance>(
                      options: const [
                        ChoiceOption(value: Appearance.auto, title: 'Auto', icon: Icons.brightness_auto_outlined),
                        ChoiceOption(value: Appearance.claro, title: 'Claro', icon: Icons.light_mode_outlined),
                        ChoiceOption(value: Appearance.escuro, title: 'Escuro', icon: Icons.dark_mode_outlined),
                      ],
                      selected: a,
                      columns: 3,
                      onChanged: AppearanceController.instance.set,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Claro lê melhor de dia e no sol; escuro, à noite e em sala fechada. Auto segue o claro/escuro do celular. Vale só para este aparelho.',
                      style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4),
                    ),
                  ]),
                ),
              ),
              const SectionHeader('Tutoriais'),
              for (final (id, title, _) in Tours.catalog)
                KeyedSubtree(
                  key: id == Tours.catalog.first.$1 ? _tutorialsKey : null,
                  child: ListTile(
                    key: ValueKey('tutorial-$id'),
                    leading: const Icon(Icons.school_outlined),
                    title: Text(title),
                    trailing: Icon(Icons.play_circle_outline_rounded, color: Ind.accent),
                    onTap: () => _openTour(context, id),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.replay_rounded),
                title: const Text('Rever todos os tutoriais'),
                onTap: () async {
                  await TourMemory.resetAll();
                  if (context.mounted) WriteActions.toast(context, 'Pronto: os tutoriais vão aparecer de novo.');
                },
              ),
              // Sem seção "Vídeos · Em breve": numa demonstração, item que não
              // faz nada parece coisa inacabada. Volta quando houver vídeo.
              const SectionHeader('Sobre'),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('${AppInfo.name} · versão ${AppInfo.version}'),
                subtitle: const Text('Powered by ${AppInfo.company}'),
                onTap: () => showLicensePage(context: context, applicationName: AppInfo.name, applicationVersion: AppInfo.version),
              ),
              // A Play pede a política também dentro do app (PS-5).
              ListTile(
                key: const ValueKey('privacidade'),
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('Privacidade'),
                subtitle: const Text('Sem conta, sem anúncio, sem rastreamento'),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyPage())),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static void _openTour(BuildContext context, String id) {
    final project = AppScope.of(context).controller.project;
    final screen = project.screen(DemoProject.operationScreenId) ?? project.screens.firstOrNull;
    Widget? page;
    switch (id) {
      case 'inicio':
        // A trilha mora na casca: volta para ela e começa lá.
        Navigator.of(context).popUntil((r) => r.isFirst);
        Shell.active?.startIntroTour();
        return;
      case 'operar':
        if (screen != null) page = ScreenRunPage(screenId: screen.id, startTour: true);
      case 'editor':
        if (screen != null) page = ScreenEditorPage(screenId: screen.id, startTour: true);
      case 'equipamentos':
        page = const DevicesPage(startTour: true);
      case 'variaveis':
        page = const TagsPage(startTour: true);
    }
    if (page == null) {
      WriteActions.toast(context, 'Crie uma tela primeiro — ou abra a demonstração (Projetos → Novo projeto).');
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => page!));
  }
}
