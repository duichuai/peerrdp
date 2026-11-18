package com.peerrdp.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [ConnectionEntity::class, TailscaleConfigEntity::class, EasyTierConfigEntity::class],
    version = 5,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun connectionDao(): ConnectionDao
    abstract fun tailscaleConfigDao(): TailscaleConfigDao
    abstract fun easytierConfigDao(): EasyTierConfigDao

    companion object {
        @Volatile private var instance: AppDatabase? = null

        /** v2：新增分辨率字段，默认自适应 */
        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "ALTER TABLE connections ADD COLUMN resolution TEXT NOT NULL DEFAULT 'adaptive'"
                )
            }
        }

        /** v3：新增 tailscale_configs 表 */
        private val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS tailscale_configs (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        name TEXT NOT NULL,
                        controlURL TEXT NOT NULL,
                        authKey TEXT NOT NULL,
                        hostname TEXT NOT NULL,
                        stateDir TEXT NOT NULL,
                        createdAt INTEGER NOT NULL
                    )
                    """.trimIndent()
                )
            }
        }

        /** v4：connections 表新增 tailscaleConfigId 字段，默认 0（不使用 Tailscale） */
        private val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "ALTER TABLE connections ADD COLUMN tailscaleConfigId INTEGER NOT NULL DEFAULT 0"
                )
            }
        }

        /** v5：新增 easytier_configs 表，connections 表新增 easytierConfigId 字段，默认 0（不使用 EasyTier） */
        private val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS easytier_configs (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        name TEXT NOT NULL,
                        networkName TEXT NOT NULL,
                        networkSecret TEXT NOT NULL,
                        peers TEXT NOT NULL,
                        ipv4 TEXT NOT NULL,
                        dhcp INTEGER NOT NULL,
                        hostname TEXT NOT NULL,
                        createdAt INTEGER NOT NULL
                    )
                    """.trimIndent()
                )
                db.execSQL(
                    "ALTER TABLE connections ADD COLUMN easytierConfigId INTEGER NOT NULL DEFAULT 0"
                )
            }
        }

        fun get(context: Context): AppDatabase =
            instance ?: synchronized(this) {
                instance ?: Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "peerrdp.db"
                ).addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5)
                    .build().also { instance = it }
            }
    }
}
