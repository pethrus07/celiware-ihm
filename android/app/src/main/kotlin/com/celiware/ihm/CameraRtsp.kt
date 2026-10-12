package com.celiware.ihm

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.rtsp.RtspMediaSource
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Câmeras IP (lib/services/cameras/exo_camera_player.dart), no canal
 * `celiware/camera`: o ExoPlayer (Media3) só com o RTSP, desenhando numa
 * textura do Flutter.
 *
 * Por que não o `video_player`: ele espera 2,5 s de vídeo antes de começar
 * (o buffer padrão do ExoPlayer, que ele não deixa mudar), trata fluxo ao
 * vivo como vídeo de duração zero (posição presa em 0, "terminou" na hora) e
 * entrega o erro só como "Source error" — sem dizer se foi senha recusada ou
 * câmera desligada. Aqui:
 *
 * - buffer de ao vivo: começa com 250 ms de vídeo;
 * - se o atraso cresce (Wi-Fi engasgou e chegou tudo de uma vez), acelera
 *   um pouco até voltar — vídeo sem som, ninguém percebe;
 * - o erro vai com a causa: "401" (senha), "refused", "timeout"...;
 * - a cada 500 ms manda posição e quanto já chegou: a diferença é o atraso
 *   que o aparelho põe, mostrado na tela.
 */
@OptIn(UnstableApi::class)
class CameraRtsp(
    private val context: Context,
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) {
    private val channel = MethodChannel(messenger, "celiware/camera")
    private val abertas = mutableMapOf<Long, Aberta>()
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "abrir" -> result.success(abrir(call.argument<String>("url") ?: ""))
                    "fechar" -> {
                        abertas.remove(call.argument<Number>("id")?.toLong())?.soltar()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("camera", e.toString(), null)
            }
        }
    }

    private fun abrir(url: String): Map<String, Any> {
        val producer = textures.createSurfaceProducer()
        val a = Aberta(producer, url)
        abertas[producer.id()] = a
        return mapOf("id" to producer.id())
    }

    /** Activity encerrando: nada fica decodificando. */
    fun encerrar() {
        abertas.values.forEach { it.soltar() }
        abertas.clear()
    }

    private inner class Aberta(
        private val producer: TextureRegistry.SurfaceProducer,
        url: String,
    ) : Player.Listener, TextureRegistry.SurfaceProducer.Callback {
        private val id = producer.id()
        private val player: ExoPlayer
        private var primeiraImagem = false
        private var erro: String? = null
        private var largura = 0
        private var altura = 0
        private var solta = false
        private val pulso = object : Runnable {
            override fun run() {
                if (solta) return
                acompanharAtraso()
                enviar()
                main.postDelayed(this, 500)
            }
        }

        init {
            // Ao vivo: começa com 250 ms de vídeo e guarda pouco. O padrão
            // (2,5 s para começar, 50 s guardados) é de filme.
            val carga = DefaultLoadControl.Builder()
                .setBufferDurationsMs(500, 2000, 250, 250)
                .setPrioritizeTimeOverSizeThresholds(true)
                .build()
            player = ExoPlayer.Builder(context).setLoadControl(carga).build()
            producer.setCallback(this)
            player.setVideoSurface(producer.surface)
            player.addListener(this)
            player.volume = 0f
            // 4 s sem pacote = fim (câmera parou) e, sem nada pelo UDP, tenta
            // por TCP mais cedo que os 8 s do padrão.
            val fonte = RtspMediaSource.Factory()
                .setTimeoutMs(4000)
                .createMediaSource(MediaItem.fromUri(url))
            player.setMediaSource(fonte)
            player.playWhenReady = true
            player.prepare()
            main.post(pulso)
        }

        /**
         * Atraso crescendo (passou de 0,7 s guardado): acelera 25% até voltar a
         * ~0,35 s; passou de 3 s, pula para perto do fim.
         */
        private fun acompanharAtraso() {
            if (!player.isPlaying) return
            val adiante = player.bufferedPosition - player.currentPosition
            val velocidade = when {
                adiante > 3000 -> {
                    player.seekTo(player.bufferedPosition - 300)
                    1f
                }
                adiante > 700 -> 1.25f
                adiante < 350 -> 1f
                else -> player.playbackParameters.speed
            }
            if (velocidade != player.playbackParameters.speed) player.playbackParameters = PlaybackParameters(velocidade)
        }

        private fun fase(): String = when {
            erro != null -> "failed"
            player.playbackState == Player.STATE_ENDED -> "ended"
            !primeiraImagem -> "opening"
            player.playbackState == Player.STATE_READY && player.isPlaying -> "playing"
            else -> "buffering"
        }

        private fun enviar() {
            if (solta) return
            channel.invokeMethod(
                "estado",
                mapOf(
                    "id" to id,
                    "fase" to fase(),
                    "erro" to erro,
                    "posicao" to player.currentPosition,
                    "carregado" to player.bufferedPosition,
                    "largura" to largura,
                    "altura" to altura,
                ),
            )
        }

        override fun onRenderedFirstFrame() {
            primeiraImagem = true
            enviar()
        }

        override fun onPlaybackStateChanged(playbackState: Int) = enviar()

        override fun onIsPlayingChanged(isPlaying: Boolean) = enviar()

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width == 0 || videoSize.height == 0) return
            largura = (videoSize.width * videoSize.pixelWidthHeightRatio).toInt()
            altura = videoSize.height
            // O ImageReader do Flutter nasce 1×1: com o tamanho do vídeo ele
            // troca a superfície, e o player passa a desenhar na nova.
            producer.setSize(videoSize.width, videoSize.height)
            player.setVideoSurface(producer.surface)
            enviar()
        }

        override fun onPlayerError(error: PlaybackException) {
            erro = descrever(error)
            enviar()
        }

        override fun onSurfaceAvailable() {
            if (!solta) player.setVideoSurface(producer.surface)
        }

        override fun onSurfaceCleanup() {
            if (!solta) player.setVideoSurface(null)
        }

        fun soltar() {
            if (solta) return
            solta = true
            main.removeCallbacks(pulso)
            player.removeListener(this)
            player.release()
            producer.release()
        }
    }

    companion object {
        /**
         * O erro com a causa, numa linha que o Dart traduz
         * (`CameraErrors.describe`): "DESCRIBE 401" = senha, "ECONNREFUSED",
         * "timeout"...
         * Os nomes das classes somem no R8; os tipos (`is`) e o código do
         * erro, não.
         */
        fun descrever(e: PlaybackException): String {
            val partes = mutableListOf(e.errorCodeName)
            var c: Throwable? = e
            var passos = 0
            while (c != null && passos < 8) {
                when (c) {
                    is RtspMediaSource.RtspPlaybackException -> partes.add("rtsp ${c.message ?: ""}")
                    is ConnectException -> partes.add("connect ${c.message ?: ""}")
                    is SocketTimeoutException -> partes.add("timeout")
                    is UnknownHostException -> partes.add("unknownhost")
                    else -> c.message?.let { if (it.isNotBlank()) partes.add(it) }
                }
                c = c.cause
                passos++
            }
            return partes.joinToString(" | ")
        }
    }
}
