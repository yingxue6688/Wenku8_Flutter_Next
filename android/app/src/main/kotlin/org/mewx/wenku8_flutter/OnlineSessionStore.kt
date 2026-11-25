package org.mewx.wenku8_flutter

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Device-bound AES-256-GCM encrypted session vault for LightNovel online auth.
 *
 * Stored in a dedicated private SharedPreferences file excluded from Android
 * backup and device transfer. Fails closed and clears corrupted ciphertext.
 */
internal class OnlineSessionStore(
    context: Context,
    private val keyProvider: KeyProvider = AndroidKeyStoreProvider(KEY_ALIAS),
) {
    internal interface KeyProvider {
        fun find(): SecretKey?
        fun getOrCreate(): SecretKey
        fun reset(): SecretKey
    }

    private val preferences = context.applicationContext.getSharedPreferences(
        PREFS_NAME,
        Context.MODE_PRIVATE,
    )

    @Synchronized
    fun read(): String? {
        val sealed = try {
            preferences.getString(KEY_SEALED, null)
        } catch (_: Exception) {
            clearSilently()
            return null
        } ?: return null

        return try {
            if (sealed.length > MAX_SEALED_CHARS) {
                throw IllegalArgumentException("Oversized sealed session record")
            }
            val parts = sealed.split(':')
            if (parts.size != 3 || parts[0] != ENVELOPE_VERSION) {
                throw IllegalArgumentException("Malformed session envelope")
            }
            val iv = Base64.decode(parts[1], Base64.NO_WRAP)
            val ciphertext = Base64.decode(parts[2], Base64.NO_WRAP)
            if (iv.size != GCM_IV_BYTES ||
                ciphertext.size < GCM_TAG_BYTES ||
                ciphertext.size > MAX_PAYLOAD_BYTES + GCM_TAG_BYTES
            ) {
                throw IllegalArgumentException("Invalid session ciphertext bounds")
            }
            val secretKey = keyProvider.find()
                ?: throw IllegalStateException("Session encryption key missing")
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_BITS, iv))
            cipher.updateAAD(AAD)
            val plain = cipher.doFinal(ciphertext)
            try {
                if (plain.isEmpty() || plain.size > MAX_PAYLOAD_BYTES) {
                    throw IllegalArgumentException("Invalid decrypted session length")
                }
                val text = decodeStrictUtf8(plain)
                if (text.isBlank()) {
                    throw IllegalArgumentException("Blank decrypted session payload")
                }
                text
            } finally {
                plain.fill(0)
            }
        } catch (_: Exception) {
            clearSilently()
            null
        }
    }

    @Synchronized
    fun write(payload: String) {
        require(payload.isNotBlank()) { "Session payload must not be blank" }
        val plain = payload.toByteArray(Charsets.UTF_8)
        try {
            require(plain.size <= MAX_PAYLOAD_BYTES) {
                "Session payload exceeds limit"
            }
            val sealed = try {
                encrypt(plain, keyProvider.getOrCreate())
            } catch (_: Exception) {
                // Recover once if an existing KeyStore alias became unusable after OS/keychain changes.
                encrypt(plain, keyProvider.reset())
            }
            check(preferences.edit().putString(KEY_SEALED, sealed).commit()) {
                "Session storage failed"
            }
        } finally {
            plain.fill(0)
        }
    }

    @Synchronized
    fun clear() {
        check(preferences.edit().clear().commit()) { "Session clear failed" }
    }

    private fun encrypt(plain: ByteArray, secretKey: SecretKey): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey)
        cipher.updateAAD(AAD)
        val iv = cipher.iv
        require(iv != null && iv.size == GCM_IV_BYTES) { "Invalid GCM IV" }
        val ciphertext = cipher.doFinal(plain)
        val encodedIv = Base64.encodeToString(iv, Base64.NO_WRAP)
        val encodedBody = Base64.encodeToString(ciphertext, Base64.NO_WRAP)
        return "$ENVELOPE_VERSION:$encodedIv:$encodedBody"
    }

    private fun clearSilently() {
        try {
            preferences.edit().clear().commit()
        } catch (_: Exception) {
            // Best-effort cleanup when failing closed.
        }
    }

    private fun decodeStrictUtf8(bytes: ByteArray): String {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return decoder.decode(ByteBuffer.wrap(bytes)).toString()
    }

    private class AndroidKeyStoreProvider(private val alias: String) : KeyProvider {
        override fun find(): SecretKey? {
            val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            return store.getKey(alias, null) as? SecretKey
        }

        override fun getOrCreate(): SecretKey = find() ?: generate()

        override fun reset(): SecretKey {
            val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            if (store.containsAlias(alias)) {
                store.deleteEntry(alias)
            }
            return generate()
        }

        private fun generate(): SecretKey =
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).apply {
                init(
                    KeyGenParameterSpec.Builder(
                        alias,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setKeySize(KEY_SIZE_BITS)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build()
                )
            }.generateKey()
    }

    companion object {
        const val PREFS_NAME = "lightnovel_online_session"
        const val KEY_ALIAS = "lightnovel.online.session.v1"
        const val MAX_PAYLOAD_BYTES = 32 * 1024

        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val KEY_SEALED = "sealed"
        private const val ENVELOPE_VERSION = "v1"
        private const val KEY_SIZE_BITS = 256
        private const val GCM_TAG_BITS = 128
        private const val GCM_TAG_BYTES = 16
        private const val GCM_IV_BYTES = 12
        private const val MAX_SEALED_CHARS = 48 * 1024
        private val AAD = KEY_ALIAS.toByteArray(Charsets.UTF_8)
    }
}
