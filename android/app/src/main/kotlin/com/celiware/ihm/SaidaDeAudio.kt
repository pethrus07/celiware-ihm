package com.celiware.ihm

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Saída de áudio para os avisos por voz (lib/services/voice/audio_output.dart).
 *
 * O `flutter_tts` só fala; não diz se há fone conectado nem abre os ajustes
 * de voz do sistema. Isso mora aqui, no canal `celiware/voz`:
 *
 * - `foneConectado`: há fone com fio, Bluetooth (A2DP, SCO, LE) ou USB entre
 *   as saídas agora? É o "falar só com fone" — no chão de fábrica o
 *   alto-falante não se ouve, e no escritório a voz no bolso assusta.
 *   Bluetooth A2DP também cobre caixa de som e rádio de carro: o Android não
 *   distingue, e errar para "fala" é o lado seguro de um alarme.
 * - `abrirAjustesDeVoz`: leva aos ajustes de conversão de texto em voz, onde
 *   se escolhe o motor e se baixa a voz em português para uso sem internet.
 */
class SaidaDeAudio(private val context: Context) {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    fun foneConectado(): Boolean =
        audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in TIPOS_FONE }

    /**
     * Tenta, nesta ordem: ajustes de voz do sistema; instalar dados de voz
     * do motor; ajustes gerais. Fabricante que esconde um cai no seguinte.
     */
    fun abrirAjustesDeVoz(): Boolean {
        val acoes = listOf(
            "com.android.settings.TTS_SETTINGS",
            TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA,
            Settings.ACTION_SETTINGS,
        )
        for (acao in acoes) {
            try {
                context.startActivity(Intent(acao).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (e: ActivityNotFoundException) {
                Log.w(TAG, "Sem tela para $acao")
            }
        }
        return false
    }

    companion object {
        private const val TAG = "SaidaDeAudio"

        // Constantes de API mais nova (USB 26, aparelho auditivo 28, LE 31)
        // são só números: em Android antigo o tipo simplesmente não aparece.
        private val TIPOS_FONE = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )

        /** Registra o canal `celiware/voz` (chamado pelo MainActivity). */
        fun registrar(messenger: BinaryMessenger, context: Context) {
            val saida = SaidaDeAudio(context)
            MethodChannel(messenger, "celiware/voz").setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "foneConectado" -> result.success(saida.foneConectado())
                        "abrirAjustesDeVoz" -> result.success(saida.abrirAjustesDeVoz())
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("voz", e.toString(), null)
                }
            }
        }
    }
}
