package com.easytier.jni

/**
 * EasyTier JNI 门面，仅保留 v1 需要的方法声明。
 *
 * 方法名与签名必须与 EasyTier v2.6.4
 * `easytier-contrib/easytier-android-jni/src/lib.rs` 中的
 * `Java_com_easytier_jni_EasyTierJNI_*` 导出一致，类名/包名不能改动。
 * 上游该文件以 LGPL-3.0 分发，详见 THIRD_PARTY_NOTICES.md。
 */
object EasyTierJNI {

    init {
        // libeasytier_android_jni.so 依赖 libeasytier_ffi.so，按依赖顺序加载
        System.loadLibrary("easytier_ffi")
        System.loadLibrary("easytier_android_jni")
    }

    /**
     * 解析 TOML 配置。成功返回 0；失败抛 RuntimeException（消息为 getLastError）。
     */
    @JvmStatic external fun parseConfig(config: String): Int

    /**
     * 启动网络实例。成功返回 0；失败抛 RuntimeException。
     */
    @JvmStatic external fun runNetworkInstance(config: String): Int

    /**
     * 仅保留指定实例，停止其它实例；传 null 停止所有实例。
     */
    @JvmStatic external fun retainNetworkInstance(instanceNames: Array<String>?): Int

    /**
     * 收集运行信息，返回 JSON：{"map":{"<实例名>":{...}}}。
     */
    @JvmStatic external fun collectNetworkInfos(maxLength: Int): String?

    /** 最近一次错误消息，无错误返回 null */
    @JvmStatic external fun getLastError(): String?
}
