// Aba Ferramentas: o que acompanha e age sobre as máquinas do projeto
// aberto — Registros (histórico em gráfico e planilha), Câmeras, Receitas e
// Regras — e as ferramentas do aparelho (voz dos alarmes, procurar
// equipamentos na rede). Até a 1.4.0 isso morava no fim da aba "Mais", e o
// cliente achou as ferramentas de monitoramento "escondidas" (reunião de
// 19–20/10/2026): Registros vem primeiro e maior.

import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../core/theme/app_theme.dart';
import '../models/project.dart';
import '../widgets/common/adaptive.dart';
import '../widgets/common/common.dart';
import '../widgets/tour/tour.dart';
import 'cameras/cameras_page.dart';
import 'devices/device_form_page.dart';
import 'devices/network_scan_sheet.dart';
import 'logs/logs_page.dart';
import 'recipes/recipes_page.dart';
import 'rules/rules_page.dart';
import 'tours.dart';
import 'voice_sheet.dart';

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  /// "Histórico em gráfico e planilha" ou "2 registros · 1 ligado".
  static String logsSummary(Project p) {
    final n = p.logGroups.length, on = p.logGroups.where((g) => g.enabled).length;
    if (n == 0) return 'Histórico em gráfico e planilha';
    return '${n == 1 ? '1 registro' : '$n registros'} · ${on == 0 ? 'nenhum ligado' : on == 1 ? '1 ligado' : '$on ligados'}';
  }

  /// "Avisar e propor ação entre máquinas" ou "2 regras · 1 ligada".
  static String rulesSummary(Project p) {
    final n = p.rules.length, on = p.rules.where((r) => r.enabled).length;
    if (n == 0) return 'Avisar e propor ação entre máquinas';
    return '${n == 1 ? '1 regra' : '$n regras'} · ${on == 0 ? 'nenhuma ligada' : on == 1 ? '1 ligada' : '$on ligadas'}';
  }

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  // Alvos do tutorial do "?".
  final _logsKey = GlobalKey();
  final _projectKey = GlobalKey();
  final _deviceKey = GlobalKey();

  void _push(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  /// Procura equipamentos Modbus no Wi-Fi; tocar num achado abre o cadastro
  /// de equipamento já com o IP e a porta.
  Future<void> _scan() async {
    final known = {
      for (final d in AppScope.of(context).controller.project.equipment)
        if (d.isNetwork) '${d.host}:${d.port}': d.name,
    };
    final found = await showNetworkScanSheet(context, known: known);
    if (found == null || !mounted) return;
    _push(DeviceFormPage(found: found));
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.watch(context).controller.project;
    return TourHost(
      spec: Tours.ferramentas(logs: _logsKey, project: _projectKey, device: _deviceKey),
      autoStart: false,
      child: Scaffold(
        appBar: AppBar(title: const Text('Ferramentas'), actions: const [HelpButton()]),
        body: FormWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
            children: [
              // Registros à frente e maior: é o que o cliente procurava.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Ind.page),
                child: Card(
                  key: _logsKey,
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    key: const ValueKey('registros'),
                    contentPadding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
                    leading: Icon(Icons.timeline_rounded, color: Ind.accent, size: 30),
                    title: const Text('Registros', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                    subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: Text(ToolsPage.logsSummary(p))),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _push(const LogsPage()),
                  ),
                ),
              ),
              KeyedSubtree(
                key: _projectKey,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ListTile(
                    key: const ValueKey('cameras'),
                    leading: const Icon(Icons.videocam_outlined),
                    title: const Text('Câmeras'),
                    subtitle: Text(CamerasPage.summary(p)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _push(const CamerasPage()),
                  ),
                  ListTile(
                    key: const ValueKey('receitas'),
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: const Text('Receitas'),
                    subtitle: Text(RecipesPage.summary(p)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _push(const RecipesPage()),
                  ),
                  // Regras entre máquinas (§9.5, LG-4 a LG-7): avisam e propõem.
                  // As contas (variáveis calculadas) moram em Variáveis, no Σ.
                  ListTile(
                    key: const ValueKey('regras'),
                    leading: const Icon(Icons.rule_rounded),
                    title: const Text('Regras'),
                    subtitle: Text(ToolsPage.rulesSummary(p)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _push(const RulesPage()),
                  ),
                ]),
              ),
              // Do aparelho, não do projeto: valem em qualquer projeto aberto.
              const SectionHeader('Deste aparelho'),
              KeyedSubtree(
                key: _deviceKey,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const VoiceSettingsTile(),
                  ListTile(
                    key: const ValueKey('procurar-na-rede'),
                    leading: const Icon(Icons.radar_rounded),
                    title: const Text('Procurar na rede'),
                    subtitle: const Text('Equipamentos Modbus neste Wi-Fi'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _scan,
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
