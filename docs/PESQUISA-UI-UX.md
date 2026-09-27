# Pesquisa de UI/UX — base para o redesenho visual

Pesquisa de 27/09/2026 em quatro frentes: norma de IHM (ISA-101, ISA-18.2), mercado (IHMs e apps móveis), UX de chão de fábrica e linguagem visual para telas escuras de dados. Cada ponto traz a fonte; números marcados **(derivado)** são conta a partir das fontes, não valor publicado.

## 1. O que as fontes dizem

### 1.1 IHM de alto desempenho (ISA-101)
- **Cor só para o anormal.** ~90% da tela neutra; vermelho/amarelo reservados a alarme; nada de cor decorativa. Cor de alarme nunca usada em outra coisa. — [PAS/Hollifield](https://www.isa.org/getmedia/06130a38-f7af-4b35-8c9c-2c34f25c1977/The-High-Performance-HMI-Overview-v2-01.pdf), [Rockwell Process HMI Style Guide](https://literature.rockwellautomation.com/idc/groups/literature/documents/wp/proces-wp023_-en-p.pdf)
- **Ligado/desligado por brilho + palavra**, não verde/vermelho (Rockwell: desligado #808080, ligado #F0F0F0). — PAS p.9–10, Rockwell §8.1. *Contraponto:* sinaleiro físico de painel segue IEC 60073 (verde = normal).
- **Valor analógico com ponteiro e faixas** (LL, L, desejável, H, HH): ponteiro é melhor que barra, porque barra "some" quando o valor cai. Nada de tanque cheio de cor saturada. — PAS p.8, p.13–14; [Ignition Moving Analog Indicator](https://www.docs.inductiveautomation.com/docs/8.1/appendix/components/perspective-components/perspective-display-palette/perspective-moving-analog-indicator)
- **Tendência embutida**, já com histórico, faixa normal sombreada, até 3–4 traços; sparkline sem zoom, toque abre a completa. — PAS p.12; Rockwell §8.12.8
- **Proibido:** 3D, gradiente em objeto estático, bomba girando, tubo colorido, unidade em destaque. A única animação aceitável é a de alarme. — PAS p.6, Rockwell §8.1
- **Hierarquia de telas:** nível 1 visão geral (sem comando), 2 unidade, 3 equipamento, 4 diagnóstico. — PAS p.15–18

### 1.2 Alarmes (ISA-18.2 / EEMUA 191)
- Estados distintos: não reconhecido (pisca + som), reconhecido (fixo), retornado sem reconhecer, suprimido/"shelved". — [ANSI/ISA-18.2-2016 §11.3.2](https://18817087.s21i.faiusr.com/61/ABUIABA9GAAgyZfj5AUozIu7wwI.pdf)
- ≥3 prioridades, cada uma com **cor reservada + forma/número** (cor sozinha não basta). Alvo ~80% baixa / 15% média / 5% alta. — 18.2 §11.4
- Onde som não funciona (fábrica barulhenta, celular): **indicação visual sempre à vista** — banner fixo + vibração. — 18.2 §11.3.4
- Lista de alarmes: tag, descrição, estado, prioridade, hora; ordenar por hora/prioridade; reconhecer; contadores; histórico. — 18.2 §11.6
- Rockwell: urgente #E22028, alta #EC8629 (laranja), média #F5E11B, baixa #916AAD; **pisca a borda**, nunca o texto. Piscar seguro: **1–2 Hz** (WCAG ≤ 3/s). — Rockwell §9.2; [WCAG 2.3.1](https://www.w3.org/WAI/WCAG22/Understanding/three-flashes-or-below-threshold.html)

### 1.3 Chão de fábrica, no celular
- **Toque:** 1 cm mínimo, erro para de cair em 9,2–9,6 mm; luva: Zebra fez botão +25% e texto +30%. **(derivado)** toque comum 56–64 dp, comando 72–80 dp, crítico ≥ 96 dp, espaço ≥ 12 dp com luva. — [NN/g](https://www.nngroup.com/articles/touch-target-size/), [Parhi 2006](https://www.microsoft.com/en-us/research/wp-content/uploads/2006/01/parhi-mobileHCI06.pdf), [Zebra](https://medium.com/zebra-design/creating-the-zebra-technologies-component-library-a3c70b231d40)
- **Leitura à distância** (20–22 arcmin): **(derivado)** número ≈ 56 sp a 1 m, ≈ 110 sp a 2 m; tabular, bold. — [FAA HFDS cap. 5/8](https://hf.tc.faa.gov/hfds/download-hfds/hfds_pdfs/Ch5_Displays_and_printers.pdf)
- **Sol:** tela comum cai abaixo de 3:1 a 100 mil lux → mirar **7:1** em texto operacional. — [WebAIM](https://webaim.org/articles/contrast/), [Rising LCD](https://www.risinglcd.com/news/How-Many-Nits-Do-You-Need-to-See-a-Screen-in-Full-Sunlight.html)
- **Claro × escuro:** tema claro vence em leitura, piora menos com luz ambiente; escuro de dia foi o pior. OLED: escuro economiza 39–47% só com brilho a 100% (3–9% a 30–50%). — [NN/g dark mode](https://www.nngroup.com/articles/dark-mode/), [Purdue](https://www.purdue.edu/newsroom/archive/releases/2021/Q3/dark-mode-may-not-save-your-phones-battery-life-as-much-as-you-think,-but-there-are-a-few-silver-linings.html), FAA HFDS §5.3.8 (polaridade positiva)
- **Comando crítico:** confirmar só o perigoso; reversível → desfazer; "segurar para confirmar" 1–1,5 s com anel. Três estados: enviado → recebido → confirmado pela leitura. — [NN/g confirmação](https://www.nngroup.com/articles/confirmation-dialog/), [NN/g tempos](https://www.nngroup.com/articles/response-times-3-important-limits/)
- **Evitar botão momentâneo dependente de rede** (Wi-Fi + Modbus). — [Inductive Automation](https://inductiveautomation.com/blog/optimizing-touchscreen-hmis-applications-for-perspective)
- **Tutorial em cartões não ajuda** (sucesso 91% × 94%; quem viu achou mais difícil). Preferir empty state que ensina + dica pontual. — [NN/g mobile tutorials](https://www.nngroup.com/articles/mobile-tutorials/)
- **Editor no toque:** pegar com long-press (arraste simples briga com rolagem), alternativa sem arrastar, desfazer/refazer visíveis. — [NN/g drag-drop](https://www.nngroup.com/articles/drag-drop/), [Home Assistant sections](https://www.home-assistant.io/dashboards/sections/), [Blynk](https://docs.blynk.io/en/blynk.apps/constructor)
- **Tablet:** < 600 dp barra inferior; ≥ 600 rail; ≥ 840 dois painéis. — [M3 breakpoints](https://m3.material.io/foundations/layout/breakpoints/medium)
- **Material 3 Expressive:** aproveitar ênfase/hierarquia e forma que muda como sinal de estado; conter as molas; sempre ícone com rótulo. — [Google Design research](https://design.google/library/expressive-material-design-google-research)

### 1.4 Linguagem visual para escuro "bonito sem perder leitura"
- No escuro, **profundidade é luminosidade**, não sombra: camadas cada vez mais claras. — [Material dark](https://m2.material.io/design/color/dark-theme.html), [Linear](https://linear.app/now/how-we-redesigned-the-linear-ui), [Grafana palette.ts](https://raw.githubusercontent.com/grafana/grafana/main/packages/grafana-data/src/themes/palette.ts)
- **Borda de 1 px** (branco 6/10/16%) + **brilho no topo** substituem sombra. — [Grafana createColors.ts](https://raw.githubusercontent.com/grafana/grafana/main/packages/grafana-data/src/themes/createColors.ts)
- **Mostrador rebaixado:** a face do instrumento (arco, trilho, poço do LED) é mais escura que o cartão — sensação física sem neumorfismo.
- **Vidro/desfoque fora:** BackdropFilter custa 6–9 ms por quadro em aparelho médio; no Impeller GLES/Adreno 610, 46,8 ms. — [flutter#192147](https://github.com/flutter/flutter/issues/192147)
- **Séries de gráfico não usam cores de estado** (ciano, roxo, verde-água…). — [Carbon data viz](https://charts.carbondesignsystem.com/palettes)
- **Números tabulares** (`FontFeature.tabularFigures()`), senão o número "dança". — [Flutter API](https://api.flutter.dev/flutter/dart-ui/FontFeature/FontFeature.tabularFigures.html)
- Envelhece mal: gradient mesh, neon em tudo, vidro pesado. Dura: bento de peso desigual, brilho ligado a estado, monocromia com um acento.

### 1.5 Mercado
- **Espelhos de IHM** (Siemens Sm@rtClient, Weintek cMT, VNC da Inovance) mostram tela de painel de 7–15" no celular: alvo pequeno, zoom obrigatório. Oportunidade clara para um app pensado para o celular.
- **Apps da Play Store** (Virtuino, HMI Modbus, Scada Touch, IoT MQTT Panel, Blynk): visual pouco trabalhado; queixas de editor difícil, sem grade, documentação fraca, sem exportar/importar, sem widget na tela inicial.
- **"Básico de IHM" que falta nos apps móveis:** alarmes com histórico e reconhecimento, receitas, tendência com histórico, níveis de usuário, telas pop-up, modelo reutilizável (faceplate) aplicado a N equipamentos.
- Inovance (IT6000/IT7000) é referência de **recursos**, não de visual (skeuomorfismo datado sobre creme). — [Inovance IT7000](https://www.inovance.eu/products/plcs-hmis/it7000-hmi)

## 2. Decisões em aberto
1. **Âmbar da marca × amarelo/laranja de alarme** — hoje quase coincidem (#FFB020 × #F5C518) e laranja é "alta prioridade" na Rockwell.
2. **Lâmpada verde/vermelha (IEC 60073, costume do painel) × brilho + palavra (ISA-101).**
3. **Tema claro "campo"** como padrão ou opção, além do escuro.
