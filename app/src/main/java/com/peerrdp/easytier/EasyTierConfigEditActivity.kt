package com.peerrdp.easytier

import android.os.Bundle
import android.util.Patterns
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.peerrdp.data.AppDatabase
import com.peerrdp.data.EasyTierConfigEntity
import com.peerrdp.databinding.ActivityEasytierConfigEditBinding
import kotlinx.coroutines.launch

class EasyTierConfigEditActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_CONFIG_ID = "config_id"
    }

    private lateinit var binding: ActivityEasytierConfigEditBinding
    private val db by lazy { AppDatabase.get(this) }
    private var editing: EasyTierConfigEntity? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityEasytierConfigEditBinding.inflate(layoutInflater)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        binding.toolbar.setNavigationOnClickListener { finish() }

        binding.swDhcp.setOnCheckedChangeListener { _, checked ->
            binding.etIpv4.isEnabled = !checked
        }

        val id = intent.getLongExtra(EXTRA_CONFIG_ID, -1L)
        if (id > 0) {
            lifecycleScope.launch {
                db.easytierConfigDao().getById(id)?.let {
                    editing = it
                    binding.etName.setText(it.name)
                    binding.etNetworkName.setText(it.networkName)
                    binding.etNetworkSecret.setText(it.networkSecret)
                    binding.etPeers.setText(it.peers)
                    binding.swDhcp.isChecked = it.dhcp
                    binding.etIpv4.isEnabled = !it.dhcp
                    binding.etIpv4.setText(it.ipv4)
                    binding.etHostname.setText(it.hostname)
                }
            }
        }

        binding.btnSave.setOnClickListener { save() }
    }

    private fun save() {
        val name = binding.etName.text.toString().trim()
        val networkName = binding.etNetworkName.text.toString().trim()
        val networkSecret = binding.etNetworkSecret.text.toString().trim()
        val dhcp = binding.swDhcp.isChecked
        val ipv4 = binding.etIpv4.text.toString().trim()

        if (name.isEmpty()) {
            binding.etName.error = "请输入名称"
            return
        }
        if (networkName.isEmpty()) {
            binding.etNetworkName.error = "请输入网络名"
            return
        }
        if (networkSecret.isEmpty()) {
            binding.etNetworkSecret.error = "请输入网络密钥"
            return
        }
        if (!dhcp && !Patterns.IP_ADDRESS.matcher(ipv4).matches()) {
            binding.etIpv4.error = "请输入合法的 IPv4 地址"
            return
        }

        val old = editing
        val entity = EasyTierConfigEntity(
            id = old?.id ?: 0,
            name = name,
            networkName = networkName,
            networkSecret = networkSecret,
            peers = binding.etPeers.text.toString().trim(),
            ipv4 = if (dhcp) "" else ipv4,
            dhcp = dhcp,
            hostname = binding.etHostname.text.toString().trim().ifEmpty { "peerrdp" },
            createdAt = old?.createdAt ?: System.currentTimeMillis()
        )

        lifecycleScope.launch {
            if (old == null) db.easytierConfigDao().insert(entity)
            else db.easytierConfigDao().update(entity)
            Toast.makeText(this@EasyTierConfigEditActivity, "已保存", Toast.LENGTH_SHORT).show()
            finish()
        }
    }
}
