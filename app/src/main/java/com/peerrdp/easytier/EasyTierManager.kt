package com.peerrdp.easytier

import android.content.Context
import android.util.Log
import com.easytier.jni.EasyTierJNI
import com.peerrdp.data.AppDatabase
import com.peerrdp.data.EasyTierConfigEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * 封装 EasyTier 实例的启停与 SOCKS5 代理管理。
 *
 * v1 使用 `no_tun = true` + 内置 SOCKS5：不申请 VpnService，
 * RDP 通过 /proxy:socks5://127.0.0.1:<port> 走虚拟网络。
 * 单例，所有 JNI 调用在 IO 线程 + Mutex 中串行执行。
 */
object EasyTierManager {
    private const val TAG = "EasyTierManager"

    /** 固定实例名，切换配置时先停后启，避免残留 */
    private const val INSTANCE_NAME = "peerrdp"

    /** 等待实例就绪的最长时间（注册、打洞、DHCP 分配都需要时间） */
    private const val READY_TIMEOUT_MS = 60_000L

    private val mutex = Mutex()

    @Volatile
    private var started = false

    @Volatile
    private var runningConfigId: Long = 0

    @Volatile
    private var socksPort: Int? = null

    @Volatile
    private var lastError: String? = null

    /**
     * 启动（或复用）指定配置对应的实例，返回本地 SOCKS5 端口。
     * 同一配置已在运行时直接复用；切换配置会先停止旧实例。
     */
    suspend fun ensureReady(context: Context, configId: Long): Int = withContext(Dispatchers.IO) {
        mutex.withLock {
            if (started && runningConfigId == configId) {
                socksPort?.let { port ->
                    if (instanceRunning()) return@withLock port
                }
                // 实例已退出（进程内状态过期），走下面的重启流程
            }
            stopLocked()

            val config = AppDatabase.get(context.applicationContext)
                .easytierConfigDao()
                .getById(configId)
                ?: throw IllegalStateException("EasyTier 配置不存在（可能已被删除），请重新编辑连接绑定配置")

            val port = start(config)
            started = true
            runningConfigId = configId
            socksPort = port
            lastError = null
            Log.i(TAG, "EasyTier ready, socks5=127.0.0.1:$port")
            port
        }
    }

    /** 停止当前实例，释放所有资源。 */
    suspend fun stop() = withContext(Dispatchers.IO) {
        mutex.withLock { stopLocked() }
    }

    /** 当前状态：stopped / starting / running / error */
    suspend fun status(): String = withContext(Dispatchers.IO) {
        if (!started) return@withContext "stopped"
        when {
            instanceRunning() -> "running"
            else -> lastError?.let { "error" } ?: "starting"
        }
    }

    /** 当前 SOCKS5 端口，未启动返回 null。 */
    fun socks5Port(): Int? = socksPort

    fun isRunning(): Boolean = started

    /** 最近一次错误消息，便于调用方回显。 */
    fun lastError(): String? = lastError

    // ---------------------------------------------------------------- 启动

    /**
     * 分配端口 → 生成 TOML → parseConfig → runNetworkInstance → 等待就绪。
     * 端口冲突等启动失败时换一组端口重试一次。
     */
    private fun start(config: EasyTierConfigEntity): Int {
        var last: Throwable? = null
        repeat(2) {
            val socks = freePort()
            val listen = freePort()
            try {
                val toml = buildToml(config, socks, listen)
                EasyTierJNI.parseConfig(toml)
                EasyTierJNI.runNetworkInstance(toml)
                waitReady(config.dhcp, socks)
                return socks
            } catch (t: Throwable) {
                last = t
                // 失败后清掉可能半启动的实例，换端口重试
                runCatching { EasyTierJNI.retainNetworkInstance(null) }
                Log.w(TAG, "EasyTier start failed (socks=$socks, listen=$listen): ${t.message}")
            }
        }
        val detail = last?.message ?: "unknown"
        lastError = detail
        throw IllegalStateException("EasyTier 启动失败: $detail", last)
    }

    private fun stopLocked() {
        if (started) {
            try {
                EasyTierJNI.retainNetworkInstance(null)
            } catch (t: Throwable) {
                Log.e(TAG, "stop EasyTier failed: ${t.message}")
            }
        }
        started = false
        runningConfigId = 0
        socksPort = null
    }

    /** 轮询 collectNetworkInfos 直到实例 running、虚拟 IP 就绪且 SOCKS5 可连接。 */
    private fun waitReady(dhcp: Boolean, socksPort: Int) {
        val deadline = System.currentTimeMillis() + READY_TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            val info = instanceInfo()
            val running = info?.optBoolean("running") == true
            val node = info?.optJSONObject("my_node_info")
            // dhcp 模式下必须已分配到虚拟 IP；固定 IP 模式下节点信息出现即可
            val hasIp = node != null && node.has("virtual_ipv4") && !node.isNull("virtual_ipv4")
            if (running && (hasIp || !dhcp) && canConnect(socksPort)) {
                Log.i(TAG, "EasyTier node info: ${info.toString().take(500)}")
                return
            }
            Thread.sleep(500)
        }
        throw IllegalStateException("EasyTier 启动超时（${READY_TIMEOUT_MS / 1000}s 内未就绪）")
    }

    /** 实例是否处于 running 且已拿到节点信息。 */
    private fun instanceRunning(): Boolean {
        val info = instanceInfo() ?: return false
        return info.optBoolean("running") && info.optJSONObject("my_node_info") != null
    }

    /** 解析 collectNetworkInfos 返回值中的当前实例信息。 */
    private fun instanceInfo(): JSONObject? = try {
        val json = EasyTierJNI.collectNetworkInfos(16) ?: return null
        JSONObject(json).optJSONObject("map")?.optJSONObject(INSTANCE_NAME)
    } catch (t: Throwable) {
        Log.w(TAG, "collectNetworkInfos failed: ${t.message}")
        null
    }

    /** 探测本地 SOCKS5 是否已监听。 */
    private fun canConnect(port: Int): Boolean = try {
        Socket().use {
            it.connect(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 1_000)
        }
        true
    } catch (_: Throwable) {
        false
    }

    /** 由系统分配一个当前空闲的本地端口。 */
    private fun freePort(): Int = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use {
        it.localPort
    }

    // ---------------------------------------------------------------- TOML

    private fun buildToml(cfg: EasyTierConfigEntity, socksPort: Int, listenPort: Int): String {
        val peerBlocks = cfg.peers.lines()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString("\n") { "[[peer]]\nuri = \"${tomlEscape(it)}\"" }

        val address = if (cfg.dhcp) {
            "dhcp = true"
        } else {
            "ipv4 = \"${tomlEscape(cfg.ipv4)}\""
        }

        return buildString {
            appendLine("instance_name = \"$INSTANCE_NAME\"")
            appendLine("hostname = \"${tomlEscape(cfg.hostname)}\"")
            appendLine(address)
            appendLine("listeners = [")
            appendLine("  \"tcp://0.0.0.0:$listenPort\",")
            appendLine("  \"udp://0.0.0.0:$listenPort\",")
            appendLine("]")
            appendLine("socks5_proxy = \"socks5://127.0.0.1:$socksPort\"")
            appendLine()
            appendLine("[network_identity]")
            appendLine("network_name = \"${tomlEscape(cfg.networkName)}\"")
            appendLine("network_secret = \"${tomlEscape(cfg.networkSecret)}\"")
            if (peerBlocks.isNotEmpty()) {
                appendLine()
                appendLine(peerBlocks)
            }
            appendLine()
            appendLine("[flags]")
            appendLine("no_tun = true")
            appendLine("enable_encryption = true")
            appendLine("mtu = 1380")
        }
    }

    /** TOML 基本字符串转义：反斜杠、双引号、控制字符 */
    private fun tomlEscape(value: String): String = buildString {
        value.forEach { c ->
            when (c) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (c.code < 0x20) append("\\u%04x".format(c.code)) else append(c)
            }
        }
    }
}
