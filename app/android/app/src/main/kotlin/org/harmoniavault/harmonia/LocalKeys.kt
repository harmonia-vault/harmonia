package org.harmoniavault.harmonia

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// 本机密钥保护的 Keystore 部分（docs/protocol.md 2.5）：
// PIN 槽用的 HMAC 密钥（不要求验证），以及每次使用都要指纹授权的 AES 密钥。两者都不可导出。
class LocalKeys(private val activity: FragmentActivity) {
    private val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pinMac" -> result.success(pinMac(call.argument<ByteArray>("input")!!))
                "bioAvailable" -> result.success(
                    BiometricManager.from(activity).canAuthenticate(BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS
                )
                "bioEnable" -> bioEnable(call.argument<ByteArray>("key")!!, call.argument<String>("title")!!, result)
                "bioUnlock" -> bioUnlock(call.argument<ByteArray>("slot")!!, call.argument<String>("title")!!, result)
                "deleteAll" -> {
                    for (alias in listOf(PIN, BIO)) if (ks.containsAlias(alias)) ks.deleteEntry(alias)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("failed", e.message, null)
        }
    }

    private fun pinMac(input: ByteArray): ByteArray {
        if (!ks.containsAlias(PIN)) {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(PIN, KeyProperties.PURPOSE_SIGN).build())
            }.generateKey()
        }
        return Mac.getInstance("HmacSHA256").run {
            init(ks.getKey(PIN, null))
            doFinal(input)
        }
    }

    private fun newBioKey(): SecretKey {
        if (ks.containsAlias(BIO)) ks.deleteEntry(BIO)
        val spec = KeyGenParameterSpec.Builder(BIO, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                }
            }
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(spec)
            generateKey()
        }
    }

    // 槽 = IV(12) ‖ 密文。
    private fun bioEnable(key: ByteArray, title: String, result: MethodChannel.Result) {
        val cipher = Cipher.getInstance(AES_GCM).apply { init(Cipher.ENCRYPT_MODE, newBioKey()) }
        prompt(cipher, title, result) { it.iv + it.doFinal(key) }
    }

    private fun bioUnlock(slot: ByteArray, title: String, result: MethodChannel.Result) {
        val key = ks.getKey(BIO, null) as SecretKey? ?: return result.error("invalidated", null, null)
        val cipher = Cipher.getInstance(AES_GCM)
        try {
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, slot, 0, 12))
        } catch (e: KeyPermanentlyInvalidatedException) {
            // 用户新增或删除了指纹、关闭了锁屏：系统已作废这把密钥。
            ks.deleteEntry(BIO)
            return result.error("invalidated", null, null)
        }
        prompt(cipher, title, result) { it.doFinal(slot, 12, slot.size - 12) }
    }

    private fun prompt(cipher: Cipher, title: String, result: MethodChannel.Result, finish: (Cipher) -> ByteArray) {
        var replied = false
        fun reply(block: () -> Unit) {
            if (!replied) {
                replied = true
                block()
            }
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setNegativeButtonText("改用 PIN")
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .build()
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult) = reply {
                try {
                    result.success(finish(r.cryptoObject!!.cipher!!))
                } catch (e: Exception) {
                    result.error("failed", e.message, null)
                }
            }

            override fun onAuthenticationError(code: Int, msg: CharSequence) = reply {
                val canceled = code == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                    code == BiometricPrompt.ERROR_USER_CANCELED || code == BiometricPrompt.ERROR_CANCELED
                result.error(if (canceled) "canceled" else "failed", msg.toString(), null)
            }
        }
        BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback)
            .authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }

    companion object {
        private const val PIN = "harmonia.pin"
        private const val BIO = "harmonia.bio"
        private const val AES_GCM = "AES/GCM/NoPadding"
    }
}
