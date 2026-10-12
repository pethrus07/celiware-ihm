package com.celiware.ihm

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.hoho.android.usbserial.driver.CdcAcmSerialDriver
import com.hoho.android.usbserial.driver.Ch34xSerialDriver
import com.hoho.android.usbserial.driver.Cp21xxSerialDriver
import com.hoho.android.usbserial.driver.FtdiSerialDriver
import com.hoho.android.usbserial.driver.ProlificSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Cabo USB-OTG: adaptador USB-serial (CH340, CP210x, FTDI, PL2303) ou o USB
 * de um Arduino (CDC), pela biblioteca usb-serial-for-android (MIT).
 *
 * Fino de propósito: listar, pedir a permissão, abrir, configurar, escrever,
 * fechar e mandar ao Dart o que chega — com o horário da leitura do USB, para
 * o Dart medir as pausas da linha sem depender de a interface estar livre —
 * e as quedas (cabo puxado). O Modbus, a mensagem do Arduino, a divisão da
 * porta entre os equipamentos da mesma RS-485 e o tempo entre caracteres
 * ficam em lib/core/serial/ e lib/core/modbus/, onde os testes alcançam.
 *
 * Canal `celiware/usb` (métodos) e `celiware/usb/eventos` (dados, quedas,
 * adaptador plugado/tirado). Tudo responde na thread principal.
 */
class PortaSerialUsb(private val context: Context) : EventChannel.StreamHandler {
    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val prober = UsbSerialProber.getDefaultProber()
    private val principal = Handler(Looper.getMainLooper())
    private var saida: EventChannel.EventSink? = null

    private class Aberta(
        val nome: String,
        val porta: UsbSerialPort,
        val conexao: UsbDeviceConnection,
        val leitura: SerialInputOutputManager,
        val escrita: ExecutorService,
    ) {
        var baud = 9600
    }

    private val abertas = mutableMapOf<Int, Aberta>()
    private var proximo = 1

    // Permissão: quem espera a resposta da caixa do Android e quem já negou
    // desde que o adaptador foi plugado — a reconexão automática não pode
    // virar uma caixa atrás da outra.
    private val esperando = mutableMapOf<String, MutableList<MethodChannel.Result>>()
    private val negadas = mutableSetOf<String>()

    private val receptor = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                ACAO_PERMISSAO -> {
                    val d = dispositivo(intent) ?: return
                    val ok = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    if (ok) negadas.remove(d.deviceName) else negadas.add(d.deviceName)
                    esperando.remove(d.deviceName)?.forEach { it.success(ok) }
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> evento(mapOf("tipo" to "conectado"))
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val d = dispositivo(intent)
                    if (d != null) {
                        negadas.remove(d.deviceName)
                        esperando.remove(d.deviceName)?.forEach { it.success(false) }
                        abertas.filterValues { it.nome == d.deviceName }.keys.toList()
                            .forEach { fechar(it, "adaptador USB desconectado") }
                    }
                    evento(mapOf("tipo" to "desconectado"))
                }
            }
        }
    }

    fun registrar(mensageiro: BinaryMessenger) {
        MethodChannel(mensageiro, "celiware/usb").setMethodCallHandler(::chamada)
        EventChannel(mensageiro, "celiware/usb/eventos").setStreamHandler(this)
        val filtro = IntentFilter().apply {
            addAction(ACAO_PERMISSAO)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        // Os avisos do sistema chegam mesmo com o receptor fechado a outros
        // apps; a resposta da permissão vem do PendingIntent do próprio app.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receptor, filtro, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receptor, filtro)
        }
    }

    /** O app foi aberto (ou trazido à frente) porque um adaptador foi plugado. */
    fun anunciarConectado() = evento(mapOf("tipo" to "conectado"))

    fun encerrar() {
        abertas.keys.toList().forEach { fechar(it, null) }
        esperando.values.flatten().forEach { it.success(false) }
        esperando.clear()
        runCatching { context.unregisterReceiver(receptor) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        saida = events
    }

    override fun onCancel(arguments: Any?) {
        saida = null
    }

    private fun evento(dados: Map<String, Any?>) {
        saida?.success(dados)
    }

    // ── Métodos ─────────────────────────────────────────────────────────────

    private fun chamada(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "listar" -> result.success(listar())
                "pedirPermissao" -> pedirPermissao(call.argument<String>("nome") ?: "", call.argument<Boolean>("insistir") ?: false, result)
                "abrir" -> abrir(call, result)
                "configurar" -> configurar(call, result)
                "escrever" -> escrever(call, result)
                "fechar" -> {
                    fechar(call.argument<Int>("h") ?: -1, null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.w(TAG, "${call.method}: $e")
            result.error("usb", e.toString(), null)
        }
    }

    /** Todos os aparelhos no USB — os sem driver serial também, para o diagnóstico. */
    private fun listar(): List<Map<String, Any?>> = usb.deviceList.values.flatMap { d ->
        val driver = prober.probeDevice(d)
        val permissao = usb.hasPermission(d)
        val base = mapOf(
            "nome" to d.deviceName,
            "vid" to d.vendorId,
            "pid" to d.productId,
            "produto" to runCatching { d.productName }.getOrNull(),
            "fabricante" to runCatching { d.manufacturerName }.getOrNull(),
            // Sem a permissão o Android 10+ esconde o número de série.
            "serie" to (if (permissao) runCatching { d.serialNumber }.getOrNull() else null),
            "permissao" to permissao,
        )
        if (driver == null) {
            listOf(base + mapOf("chip" to null, "porta" to 0, "portas" to 1))
        } else {
            val portas = driver.ports.size
            (0 until portas).map { i -> base + mapOf("chip" to chip(driver, d), "porta" to i, "portas" to portas) }
        }
    }

    private fun chip(driver: UsbSerialDriver, d: UsbDevice): String = when (driver) {
        is Ch34xSerialDriver -> "CH340"
        is Cp21xxSerialDriver -> "CP210x"
        is FtdiSerialDriver -> "FTDI"
        is ProlificSerialDriver -> "PL2303"
        is CdcAcmSerialDriver -> when (d.vendorId) {
            0x2341, 0x2A03 -> "Arduino"
            0x1A86 -> "CH343/CH9102"
            0x303A -> "ESP32"
            else -> "CDC"
        }
        else -> driver.javaClass.simpleName.removeSuffix("SerialDriver")
    }

    private fun achar(nome: String): UsbDevice? = usb.deviceList.values.firstOrNull { it.deviceName == nome }

    private fun pedirPermissao(nome: String, insistir: Boolean, result: MethodChannel.Result) {
        val d = achar(nome) ?: return result.success(false)
        if (usb.hasPermission(d)) return result.success(true)
        if (!insistir && nome in negadas) return result.success(false)
        val fila = esperando.getOrPut(nome) { mutableListOf() }
        fila.add(result)
        if (fila.size > 1) return // a caixa já está na tela: espera a mesma resposta
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val pedido = PendingIntent.getBroadcast(context, 0, Intent(ACAO_PERMISSAO).setPackage(context.packageName), flags)
        usb.requestPermission(d, pedido)
    }

    private fun abrir(call: MethodCall, result: MethodChannel.Result) {
        val nome = call.argument<String>("nome") ?: ""
        val d = achar(nome) ?: return result.error("sumiu", "adaptador $nome não está plugado", null)
        if (!usb.hasPermission(d)) return result.error("permissao", "sem permissão para $nome", null)
        val driver = prober.probeDevice(d) ?: return result.error("driver", "sem driver serial para $nome", null)
        val porta = driver.ports.getOrNull(call.argument<Int>("porta") ?: 0)
            ?: return result.error("porta", "porta inexistente", null)
        val conexao = usb.openDevice(d) ?: return result.error("abrir", "o Android não abriu $nome", null)
        try {
            porta.open(conexao)
            parametros(porta, call)
            // FTDI de fábrica junta os bytes por 16 ms antes de mandar: com 1 ms
            // a resposta chega inteira mais cedo (a pausa medida fica real).
            if (porta is FtdiSerialDriver.FtdiSerialPort) runCatching { porta.setLatencyTimer(1) }
            // DTR só para o Arduino (Leonardo/Micro esperam por ele). Em
            // adaptador RS-485 o sinal fica como está: alguns usam DTR/RTS para
            // virar a linha.
            if (call.argument<Boolean>("dtr") == true) runCatching { porta.dtr = true }
        } catch (e: Exception) {
            runCatching { porta.close() }
            runCatching { conexao.close() }
            return result.error("abrir", e.toString(), null)
        }
        val h = proximo++
        val leitura = SerialInputOutputManager(porta, object : SerialInputOutputManager.Listener {
            override fun onNewData(data: ByteArray) {
                // O horário é o da leitura do USB, não o da entrega ao Dart.
                val t = SystemClock.elapsedRealtimeNanos() / 1000
                principal.post { if (abertas.containsKey(h)) evento(mapOf("tipo" to "dados", "h" to h, "dados" to data, "t" to t)) }
            }

            override fun onRunError(e: Exception) {
                // Cabo puxado: a leitura para com erro. Fechar de propósito
                // também para a leitura — aí a porta já saiu de `abertas`.
                principal.post { if (abertas.containsKey(h)) fechar(h, "adaptador USB desconectado") }
            }
        })
        val aberta = Aberta(nome, porta, conexao, leitura, Executors.newSingleThreadExecutor())
        aberta.baud = call.argument<Int>("baud") ?: 9600
        abertas[h] = aberta
        // Responde antes de começar a ler: o Dart sabe o número da porta antes
        // do primeiro byte chegar.
        result.success(h)
        leitura.start()
    }

    private fun parametros(porta: UsbSerialPort, call: MethodCall) {
        val paridade = when (call.argument<String>("paridade")) {
            "even" -> UsbSerialPort.PARITY_EVEN
            "odd" -> UsbSerialPort.PARITY_ODD
            else -> UsbSerialPort.PARITY_NONE
        }
        val parada = if (call.argument<Int>("parada") == 2) UsbSerialPort.STOPBITS_2 else UsbSerialPort.STOPBITS_1
        porta.setParameters(call.argument<Int>("baud") ?: 9600, call.argument<Int>("bits") ?: 8, parada, paridade)
    }

    private fun configurar(call: MethodCall, result: MethodChannel.Result) {
        val a = abertas[call.argument<Int>("h") ?: -1] ?: return result.error("fechada", "porta fechada", null)
        // Na fila da escrita: nunca troca a velocidade no meio de um envio.
        a.escrita.execute {
            try {
                parametros(a.porta, call)
                a.baud = call.argument<Int>("baud") ?: a.baud
                principal.post { result.success(null) }
            } catch (e: Exception) {
                principal.post { result.error("configurar", e.toString(), null) }
            }
        }
    }

    private fun escrever(call: MethodCall, result: MethodChannel.Result) {
        val a = abertas[call.argument<Int>("h") ?: -1] ?: return result.error("fechada", "porta fechada", null)
        val dados = call.argument<ByteArray>("dados") ?: ByteArray(0)
        a.escrita.execute {
            try {
                // Tempo para o quadro sair no fio (11 bits por caractere, folgado) + 1 s.
                val prazo = 1000 + (dados.size * 11_000L / a.baud.coerceAtLeast(300)).toInt()
                a.porta.write(dados, prazo)
                principal.post { result.success(null) }
            } catch (e: Exception) {
                principal.post {
                    result.error("escrever", e.toString(), null)
                    if (abertas.containsKey(call.argument<Int>("h") ?: -1)) fechar(call.argument<Int>("h") ?: -1, "falha ao enviar pelo adaptador USB")
                }
            }
        }
    }

    /** Fecha a porta [h]; com [motivo], avisa o Dart que ela caiu. */
    private fun fechar(h: Int, motivo: String?) {
        val a = abertas.remove(h) ?: return
        a.leitura.listener = null
        a.leitura.stop()
        runCatching { a.porta.close() }
        runCatching { a.conexao.close() }
        a.escrita.shutdownNow()
        if (motivo != null) evento(mapOf("tipo" to "caiu", "h" to h, "motivo" to motivo))
    }

    private fun dispositivo(intent: Intent): UsbDevice? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }

    companion object {
        private const val TAG = "PortaSerialUsb"
        private const val ACAO_PERMISSAO = "com.celiware.ihm.PERMISSAO_USB"
    }
}
