package com.peerrdp.data

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * EasyTier 网络配置。
 * 每个配置对应一个名为 peerrdp 的 EasyTier 实例（no_tun + 内置 SOCKS5）。
 */
@Entity(tableName = "easytier_configs")
data class EasyTierConfigEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val name: String,
    /** EasyTier 网络名，参与同一网络的节点需一致 */
    val networkName: String,
    /** 网络密钥，参与同一网络的节点需一致 */
    val networkSecret: String,
    /** 对等节点 URI，换行分隔，例如 tcp://public.example.com:11010 */
    val peers: String = "",
    /** 固定虚拟 IP；空且 dhcp=true 时由 EasyTier 自动分配 */
    val ipv4: String = "",
    /** true 表示自动分配虚拟 IP */
    val dhcp: Boolean = true,
    /** 节点主机名 */
    val hostname: String = "peerrdp",
    val createdAt: Long = System.currentTimeMillis()
)
