package com.celiware.ihm

import android.content.Intent
import android.hardware.usb.UsbManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var rede: RedeLocal? = null
    private var usb: PortaSerialUsb? = null
    private var cameras: CameraRtsp? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Canal da voz: fone conectado e ajustes de voz (ver SaidaDeAudio).
        SaidaDeAudio.registrar(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // Canal do cabo USB-OTG: adaptador RS-485/RS-232 e Arduino (ver PortaSerialUsb).
        usb = PortaSerialUsb(applicationContext).also { it.registrar(flutterEngine.dartExecutor.binaryMessenger) }
        // Canal das câmeras IP: vídeo RTSP numa textura (ver CameraRtsp).
        cameras = CameraRtsp(applicationContext, flutterEngine.dartExecutor.binaryMessenger, flutterEngine.renderer)
        val r = RedeLocal(applicationContext)
        rede = r
        // Canal da rede local (ver RedeLocal e lib/services/net/local_network.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "celiware/rede").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "listar" -> result.success(r.listar())
                    "vincular" -> result.success(r.vincular(call.argument<String>("ip") ?: ""))
                    "desvincular" -> {
                        r.desvincular()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("rede", e.toString(), null)
            }
        }
    }

    // Com o app aberto, plugar o adaptador chega aqui (singleTop): a lista do
    // cadastro se atualiza.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == UsbManager.ACTION_USB_DEVICE_ATTACHED) usb?.anunciarConectado()
    }

    override fun onDestroy() {
        cameras?.encerrar()
        cameras = null
        rede?.encerrar()
        rede = null
        usb?.encerrar()
        usb = null
        super.onDestroy()
    }
}
