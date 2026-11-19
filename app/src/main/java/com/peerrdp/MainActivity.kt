package com.peerrdp

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.text.InputType
import android.util.Log
import android.view.LayoutInflater
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.peerrdp.data.AppDatabase
import com.peerrdp.data.ConnectionEntity
import com.peerrdp.databinding.ActivityMainBinding
import com.peerrdp.databinding.ItemConnectionBinding
import com.peerrdp.edit.ConnectionEditActivity
import com.peerrdp.easytier.EasyTierConfigEditActivity
import com.peerrdp.feedback.FeedbackActivity
import com.peerrdp.tailscale.TailscaleConfigEditActivity
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private val db by lazy { AppDatabase.get(this) }
    private val adapter = ConnectionAdapter(
        onClick = { onConnect(it) },
        onLongClick = { showItemMenu(it) }
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar)

        binding.recyclerView.layoutManager = LinearLayoutManager(this)
        binding.recyclerView.adapter = adapter

        binding.fabAdd.setOnClickListener {
            startActivity(Intent(this, ConnectionEditActivity::class.java))
        }

        lifecycleScope.launch {
            db.connectionDao().observeAll().collect { list ->
                adapter.submitList(list)
                binding.emptyView.visibility = if (list.isEmpty()) View.VISIBLE else View.GONE
            }
        }
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.main_menu, menu)
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean = when (item.itemId) {
        R.id.action_tailscale -> {
            openTailscaleConfig()
            true
        }
        R.id.action_easytier -> {
            openEasyTierConfig()
            true
        }
        R.id.action_feedback -> {
            startActivity(Intent(this, FeedbackActivity::class.java))
            true
        }
        R.id.action_about -> {
            showAbout()
            true
        }
        else -> super.onOptionsItemSelected(item)
    }

    /** 关于：版本号、作者、GitHub、许可与免责声明 */
    private fun showAbout() {
        val pkg = packageManager.getPackageInfo(packageName, 0)
        val version = "${pkg.versionName} (${pkg.longVersionCode})"
        val message = buildString {
            append("版本：$version\n")
            append("作者：duichuai\n")
            append("GitHub：https://github.com/duichuai/peerrdp\n")
            append("开源许可：Apache License 2.0\n")
            append("第三方组件：FreeRDP（Apache-2.0）、freeRDPCore（MPL-2.0）、Tailscale tsnet（BSD-3-Clause）、EasyTier（LGPL-3.0）\n")
            append("\n免责声明：\n")
            append("本应用为独立开发的远程桌面客户端，与 FreeRDP、Tailscale、EasyTier 等项目无隶属或背书关系。")
            append("请仅连接你拥有或已获得明确授权访问的主机；因使用本应用造成的任何数据丢失、服务中断或法律纠纷，")
            append("均由使用者自行承担，作者不承担任何责任。软件按“现状”提供，不附带任何明示或暗示的担保。")
        }
        AlertDialog.Builder(this)
            .setTitle("关于 ${getString(R.string.app_name_short)}")
            .setMessage(message)
            .setNeutralButton("GitHub") { _, _ ->
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/duichuai/peerrdp")))
            }
            .setPositiveButton("关闭", null)
            .show()
    }

    /** 已有 Tailscale 配置则回填编辑，没有则新建 */
    private fun openTailscaleConfig() {
        lifecycleScope.launch {
            val existing = db.tailscaleConfigDao().getAll().firstOrNull()
            val intent = Intent(this@MainActivity, TailscaleConfigEditActivity::class.java)
            if (existing != null) {
                intent.putExtra(TailscaleConfigEditActivity.EXTRA_CONFIG_ID, existing.id)
            }
            startActivity(intent)
        }
    }

    /** 已有 EasyTier 配置则回填编辑，没有则新建 */
    private fun openEasyTierConfig() {
        lifecycleScope.launch {
            val existing = db.easytierConfigDao().getAll().firstOrNull()
            val intent = Intent(this@MainActivity, EasyTierConfigEditActivity::class.java)
            if (existing != null) {
                intent.putExtra(EasyTierConfigEditActivity.EXTRA_CONFIG_ID, existing.id)
            }
            startActivity(intent)
        }
    }

    private fun onConnect(conn: ConnectionEntity) {
        lifecycleScope.launch { db.connectionDao().touch(conn.id, System.currentTimeMillis()) }
        if (conn.password.isEmpty()) {
            promptPassword(conn)
        } else {
            connectAsync(conn, conn.password)
        }
    }

    /** 在协程中调用 RdpConnector（可能需要等待 tsnet 就绪） */
    private fun connectAsync(conn: ConnectionEntity, password: String) {
        lifecycleScope.launch {
            try {
                RdpConnector.connect(this@MainActivity, conn, password)
            } catch (e: Throwable) {
                // 捕获 Throwable 而非 Exception：gomobile/JNI 层问题可能抛 Error，
                // 避免未捕获导致闪退，同时把堆栈打到 logcat 便于排查
                Log.e("MainActivity", "connect failed", e)
                android.widget.Toast.makeText(
                    this@MainActivity,
                    "连接失败: ${e.message ?: e.javaClass.simpleName}",
                    android.widget.Toast.LENGTH_LONG
                ).show()
            }
        }
    }

    /** 未保存密码时，连接前询问（不落库） */
    private fun promptPassword(conn: ConnectionEntity) {
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            hint = getString(R.string.password_hint)
        }
        val margin = (20 * resources.displayMetrics.density).toInt()
        val container = FrameLayout(this)
        container.setPadding(margin, margin / 2, margin, 0)
        container.addView(input)

        AlertDialog.Builder(this)
            .setTitle(getString(R.string.enter_password_title, conn.username))
            .setView(container)
            .setPositiveButton(R.string.connect) { _, _ ->
                connectAsync(conn, input.text.toString())
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun showItemMenu(conn: ConnectionEntity) {
        val items = arrayOf(
            getString(R.string.copy),
            getString(R.string.edit),
            getString(R.string.delete)
        )
        AlertDialog.Builder(this)
            .setTitle(conn.name.ifEmpty { conn.host })
            .setItems(items) { _, which ->
                when (which) {
                    0 -> startActivity(
                        Intent(this, ConnectionEditActivity::class.java)
                            .putExtra(ConnectionEditActivity.EXTRA_COPY_FROM_ID, conn.id)
                    )
                    1 -> startActivity(
                        Intent(this, ConnectionEditActivity::class.java)
                            .putExtra(ConnectionEditActivity.EXTRA_CONNECTION_ID, conn.id)
                    )
                    2 -> confirmDelete(conn)
                }
            }
            .show()
    }

    private fun confirmDelete(conn: ConnectionEntity) {
        AlertDialog.Builder(this)
            .setMessage(getString(R.string.delete_confirm, conn.name.ifEmpty { conn.host }))
            .setPositiveButton(R.string.delete) { _, _ ->
                lifecycleScope.launch { db.connectionDao().delete(conn) }
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private class ConnectionAdapter(
        private val onClick: (ConnectionEntity) -> Unit,
        private val onLongClick: (ConnectionEntity) -> Unit
    ) : ListAdapter<ConnectionEntity, ConnectionAdapter.VH>(DIFF) {

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
            val b = ItemConnectionBinding.inflate(LayoutInflater.from(parent.context), parent, false)
            return VH(b)
        }

        override fun onBindViewHolder(holder: VH, position: Int) = holder.bind(getItem(position))

        inner class VH(private val b: ItemConnectionBinding) : RecyclerView.ViewHolder(b.root) {
            fun bind(item: ConnectionEntity) {
                b.tvName.text = item.name.ifEmpty { item.host }
                b.tvAddress.text = "${item.host}:${item.port}"
                b.tvUser.text = item.username
                b.root.setOnClickListener { onClick(item) }
                b.root.setOnLongClickListener { onLongClick(item); true }
            }
        }

        companion object {
            private val DIFF = object : DiffUtil.ItemCallback<ConnectionEntity>() {
                override fun areItemsTheSame(a: ConnectionEntity, b: ConnectionEntity) = a.id == b.id
                override fun areContentsTheSame(a: ConnectionEntity, b: ConnectionEntity) = a == b
            }
        }
    }
}
