package com.celiware.ihm

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkAddress
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log
import java.net.Inet4Address
import java.net.InetAddress

/**
 * Faz a conexão com o equipamento sair pela rede LOCAL certa.
 *
 * O problema que resolve: a rede da máquina quase nunca tem internet. Com os
 * dados móveis ligados, o Android elege o 4G como rede padrão e todo socket
 * sem vínculo sai por ele — o pedido para 192.168.1.10 vai para a operadora e
 * morre em "tempo esgotado" (NetworkRanker / RouteController do AOSP).
 *
 * A saída é vincular o PROCESSO à rede Wi-Fi/cabo cuja faixa contém o IP do
 * equipamento (`bindProcessToNetwork`): todo socket criado depois, inclusive o
 * do Dart, sai por ela. Compartilhar, imprimir e abrir links continuam
 * funcionando — rodam em outros processos, que não herdam o vínculo.
 *
 * Só vincula quando o IP do equipamento está dentro da faixa de uma rede
 * local conectada; equipamento remoto (VPN, 4G) não mexe no vínculo.
 */
class RedeLocal(context: Context) {
    private val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private var vinculada: Network? = null
    private var pedido: ConnectivityManager.NetworkCallback? = null

    // Rede vinculada caiu: solta o vínculo (os sockets dela já morreram) e
    // deixa a próxima reconexão escolher de novo.
    private val observador = object : ConnectivityManager.NetworkCallback() {
        override fun onLost(network: Network) {
            if (network == vinculada) desvincular()
        }
    }

    init {
        try {
            cm.registerNetworkCallback(pedidoLocal(null), observador)
        } catch (e: Exception) {
            Log.w(TAG, "Sem observador de rede: $e")
        }
    }

    /** Redes Wi-Fi/cabo conectadas, com IPv4, faixa e estado. */
    fun listar(): List<Map<String, Any?>> = locais().map { (n, lp, caps) -> descrever(n, lp, caps) }

    /**
     * Vincula o processo à rede local que contém [ip]. Devolve a rede usada,
     * ou nulo se nenhuma rede local contém esse IP (o vínculo fica como está).
     */
    fun vincular(ip: String): Map<String, Any?>? {
        val alvo = ipv4(ip) ?: return null
        for ((n, lp, caps) in locais()) {
            if (lp.linkAddresses.none { mesmaFaixa(alvo, it) }) continue
            if (n != vinculada) {
                if (!cm.bindProcessToNetwork(n)) {
                    Log.w(TAG, "bindProcessToNetwork recusado")
                    return null
                }
                vinculada = n
                manter(caps)
                Log.i(TAG, "Conexões vinculadas à rede local de $ip")
            }
            return descrever(n, lp, caps)
        }
        return null
    }

    fun desvincular() {
        cm.bindProcessToNetwork(null)
        vinculada = null
        pedido?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        pedido = null
    }

    fun encerrar() {
        desvincular()
        runCatching { cm.unregisterNetworkCallback(observador) }
    }

    // ── Detalhes ────────────────────────────────────────────────────────────

    private data class Local(val rede: Network, val lp: LinkProperties, val caps: NetworkCapabilities)

    @Suppress("DEPRECATION") // allNetworks segue funcionando e cobre o minSdk 24.
    private fun locais(): List<Local> = cm.allNetworks.mapNotNull { n ->
        val caps = cm.getNetworkCapabilities(n) ?: return@mapNotNull null
        val local = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        val lp = cm.getLinkProperties(n)
        if (!local || lp == null) null else Local(n, lp, caps)
    }

    /**
     * Pede ao sistema que mantenha a rede de pé enquanto estiver vinculada:
     * rede que não atende pedido nenhum pode ser derrubada. Sem exigir
     * internet — a da máquina não tem.
     */
    private fun manter(caps: NetworkCapabilities) {
        pedido?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        val cb = object : ConnectivityManager.NetworkCallback() {}
        try {
            cm.requestNetwork(pedidoLocal(caps), cb)
            pedido = cb
        } catch (e: Exception) {
            Log.w(TAG, "requestNetwork recusado: $e")
            pedido = null
        }
    }

    private fun pedidoLocal(caps: NetworkCapabilities?): NetworkRequest {
        val b = NetworkRequest.Builder().removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        val ethernet = caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
        when {
            caps == null -> b.addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            ethernet -> b.addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            else -> b.addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
        }
        return b.build()
    }

    private fun descrever(n: Network, lp: LinkProperties, caps: NetworkCapabilities): Map<String, Any?> {
        val v4 = lp.linkAddresses.firstOrNull { it.address is Inet4Address }
        return mapOf(
            "tipo" to if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) "cabo" else "wifi",
            "ip" to v4?.address?.hostAddress,
            "prefixo" to v4?.prefixLength,
            "internet" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            "padrao" to (cm.activeNetwork == n),
            "vinculada" to (vinculada == n),
        )
    }

    private fun ipv4(texto: String): Inet4Address? {
        // Só IP numérico: resolver nome aqui faria DNS pela rede errada.
        if (!Regex("""^\d{1,3}(\.\d{1,3}){3}$""").matches(texto)) return null
        return runCatching { InetAddress.getByName(texto) as? Inet4Address }.getOrNull()
    }

    private fun mesmaFaixa(alvo: Inet4Address, la: LinkAddress): Boolean {
        val b = la.address as? Inet4Address ?: return false
        val p = la.prefixLength
        if (p !in 1..32) return false
        val mask = if (p == 32) -1 else (-1 shl (32 - p))
        return (paraInt(alvo) and mask) == (paraInt(b) and mask)
    }

    private fun paraInt(a: Inet4Address): Int =
        a.address.fold(0) { acc, byte -> (acc shl 8) or (byte.toInt() and 0xFF) }

    companion object {
        private const val TAG = "RedeLocal"
    }
}
