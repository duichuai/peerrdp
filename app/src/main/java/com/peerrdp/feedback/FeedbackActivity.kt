package com.peerrdp.feedback

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import com.peerrdp.R
import com.peerrdp.databinding.ActivityFeedbackBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 问题 / 需求反馈页：收集类型、描述、联系方式，
 * 可选择附带设备信息与客户端日志，生成文本文件后交给系统分享（邮件、IM 等）。
 */
class FeedbackActivity : AppCompatActivity() {

    companion object {
        /** 单个日志文件最多保留尾部 64KB */
        private const val MAX_LOG_FILE_BYTES = 64 * 1024
        /** 所有日志文件合计上限 512KB */
        private const val MAX_LOGS_TOTAL_BYTES = 512 * 1024
        /** logcat 最多抓取的行数 */
        private const val LOGCAT_LINES = 2000
        private const val PROVIDER_SUFFIX = ".feedback.fileprovider"
    }

    private lateinit var binding: ActivityFeedbackBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityFeedbackBinding.inflate(layoutInflater)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        binding.toolbar.setNavigationOnClickListener { finish() }
        binding.btnSubmit.setOnClickListener { submit() }
    }

    private fun submit() {
        val description = binding.etDescription.text.toString().trim()
        if (description.isEmpty()) {
            binding.etDescription.error = getString(R.string.feedback_description_required)
            return
        }
        val type = getString(
            if (binding.rbRequest.isChecked) R.string.feedback_type_request
            else R.string.feedback_type_issue
        )
        val contact = binding.etContact.text.toString().trim()
        val includeLogs = binding.cbIncludeLogs.isChecked

        binding.btnSubmit.isEnabled = false
        Toast.makeText(this, R.string.feedback_collecting, Toast.LENGTH_SHORT).show()
        lifecycleScope.launch {
            try {
                val file = withContext(Dispatchers.IO) {
                    buildFeedbackFile(type, description, contact, includeLogs)
                }
                share(file, type, description, contact)
            } catch (t: Throwable) {
                Toast.makeText(
                    this@FeedbackActivity,
                    getString(R.string.feedback_collect_failed, t.message ?: t.javaClass.simpleName),
                    Toast.LENGTH_LONG
                ).show()
            } finally {
                binding.btnSubmit.isEnabled = true
            }
        }
    }

    /** 生成反馈文本：描述、联系方式、设备信息与日志（可选）。 */
    private fun buildFeedbackFile(
        type: String,
        description: String,
        contact: String,
        includeLogs: Boolean
    ): File {
        val dir = File(cacheDir, "feedback").apply { mkdirs() }
        // 清理一天前的旧文件；保留刚生成的文件，避免分享目标还没读取就被删除
        val expireAt = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        dir.listFiles()?.filter { it.lastModified() < expireAt }?.forEach { it.delete() }

        val now = Date()
        val file = File(
            dir,
            "peerrdp-feedback-${SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(now)}.txt"
        )
        file.bufferedWriter(Charsets.UTF_8).use { writer ->
            writer.write("PeerRDP 反馈\n")
            writer.write("类型：$type\n")
            writer.write("时间：${SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(now)}\n")
            writer.write("联系方式：${contact.ifEmpty { "（未填写）" }}\n\n")
            writer.write("【描述】\n$description\n\n")

            if (includeLogs) {
                writer.write("【设备信息】\n")
                writer.write(deviceInfo())
                writer.write("\n【logcat】\n")
                writer.write(collectLogcat().ifEmpty { "（未获取到 logcat 输出）" })
                writer.write("\n\n【应用日志文件】\n")
                writer.write(collectLogFiles())
            }
        }
        return file
    }

    /** 应用版本与设备环境，便于复现问题。 */
    private fun deviceInfo(): String = buildString {
        val pkg = packageManager.getPackageInfo(packageName, 0)
        append("应用版本：${pkg.versionName} (${pkg.longVersionCode})\n")
        append("Android：${Build.VERSION.RELEASE}（API ${Build.VERSION.SDK_INT}）\n")
        append("设备：${Build.MANUFACTURER} ${Build.MODEL}\n")
        append("ABI：${Build.SUPPORTED_ABIS.joinToString(", ")}\n")
        append("语言/地区：${Locale.getDefault()}\n")
    }

    /** 抓取本进程可见的 logcat（系统仅允许读取应用自身日志）。 */
    private fun collectLogcat(): String = runCatching {
        val process = ProcessBuilder(
            "logcat", "-d", "-v", "threadtime", "-t", LOGCAT_LINES.toString()
        ).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().use { it.readText() }
        process.waitFor()
        output
    }.getOrDefault("")

    /** 汇总应用私有目录下的 *.log（如 tsnet.log），按尾部截断并限制总量。 */
    private fun collectLogFiles(): String {
        val logs = filesDir.walkTopDown()
            .filter { it.isFile && it.name.endsWith(".log") }
            .sortedBy { it.path }
            .toList()
        if (logs.isEmpty()) return "（无日志文件）\n"

        val sb = StringBuilder()
        var budget = MAX_LOGS_TOTAL_BYTES
        for (log in logs) {
            if (budget <= 0) {
                sb.append("（其余日志已省略）\n")
                break
            }
            val size = log.length()
            val take = minOf(size, MAX_LOG_FILE_BYTES.toLong(), budget.toLong()).toInt()
            sb.append("\n--- ${log.relativeTo(filesDir)} ---\n")
            runCatching {
                RandomAccessFile(log, "r").use { raf ->
                    raf.seek(size - take)
                    val buf = ByteArray(take)
                    raf.readFully(buf)
                    sb.append(String(buf, Charsets.UTF_8))
                }
            }.onFailure { sb.append("读取失败：${it.message}\n") }
            if (take < size) sb.append("\n（文件前部已截断）\n")
            budget -= take
            if (!sb.endsWith("\n")) sb.append('\n')
        }
        return sb.toString()
    }

    /** 把反馈文本作为附件交给系统分享面板（邮件、IM 等）。 */
    private fun share(file: File, type: String, description: String, contact: String) {
        val uri = FileProvider.getUriForFile(this, "$packageName$PROVIDER_SUFFIX", file)
        val text = buildString {
            append("PeerRDP $type\n\n")
            append(description)
            if (contact.isNotEmpty()) append("\n\n联系方式：$contact")
            append("\n\n日志与设备信息见附件。")
        }
        val send = Intent(Intent.ACTION_SEND).apply {
            this.type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, getString(R.string.feedback_share_subject, type))
            putExtra(Intent.EXTRA_TEXT, text)
            putExtra(Intent.EXTRA_STREAM, uri)
            // ClipData 显式携带 URI，确保接收方在 Android 11+ 能获得读取授权
            clipData = ClipData.newRawUri("feedback", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(Intent.createChooser(send, getString(R.string.feedback_share_title)))
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, R.string.feedback_no_app, Toast.LENGTH_LONG).show()
        }
    }
}
