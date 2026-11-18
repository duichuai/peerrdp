package com.peerrdp.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface EasyTierConfigDao {
    @Query("SELECT * FROM easytier_configs ORDER BY createdAt DESC")
    fun observeAll(): Flow<List<EasyTierConfigEntity>>

    @Query("SELECT * FROM easytier_configs ORDER BY createdAt DESC")
    suspend fun getAll(): List<EasyTierConfigEntity>

    @Query("SELECT * FROM easytier_configs WHERE id = :id")
    suspend fun getById(id: Long): EasyTierConfigEntity?

    @Insert
    suspend fun insert(config: EasyTierConfigEntity): Long

    @Update
    suspend fun update(config: EasyTierConfigEntity)

    @Query("DELETE FROM easytier_configs WHERE id = :id")
    suspend fun delete(id: Long)
}
