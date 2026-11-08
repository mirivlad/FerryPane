package top.mirv.ferrypane

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import android.provider.Telephony
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * Android contacts/SMS export is initiated only by previously authorized
 * paired devices. The user grants sensitive backup rights once while setting
 * up recovery, and Android permissions are enforced for every operation.
 * Exports are private temporary files, never part of the shared filesystem.
 */
class PersonalDataBridge(private val activity: FlutterActivity) {
    private fun verifyPermission(permission: String) {
        if (activity.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("Не выдано системное разрешение $permission")
        }
    }

    private fun privateBackups(): File {
        return File(activity.cacheDir, "ferrypane-backups").also { it.mkdirs() }
    }

    private fun uniqueName(kind: String, suffix: String): File {
        val timestamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        return File(privateBackups(), "$kind-$timestamp-${UUID.randomUUID().toString().substring(0, 8)}.$suffix")
    }

    /** Android's provider supplies complete vCard records with multiple fields. */
    fun exportContacts(): String {
        verifyPermission(Manifest.permission.READ_CONTACTS)
        val result = uniqueName("contacts", "vcf")
        var count = 0
        try {
            FileOutputStream(result).use { output ->
                val cursor = activity.contentResolver.query(
                    ContactsContract.Contacts.CONTENT_URI,
                    arrayOf(ContactsContract.Contacts.LOOKUP_KEY),
                    null, null, null
                ) ?: throw IllegalStateException("Не удалось открыть адресную книгу")
                cursor.use {
                    while (it.moveToNext()) {
                        val key = it.getString(0) ?: continue
                        val uri = Uri.withAppendedPath(
                            ContactsContract.Contacts.CONTENT_VCARD_URI, key
                        )
                        val descriptor = activity.contentResolver.openAssetFileDescriptor(uri, "r")
                            ?: throw IllegalStateException("Не удалось получить vCard для контакта")
                        descriptor.use { asset ->
                            asset.createInputStream().use { input -> input.copyTo(output) }
                        }
                        output.write("\n".toByteArray(Charsets.UTF_8))
                        count++
                    }
                }
            }
            if (count == 0) throw IllegalStateException("Адресная книга пуста")
            return result.absolutePath
        } catch (e: Exception) {
            result.delete()
            throw e
        }
    }

    /** SMS only: MMS and RCS are not represented in the Telephony.Sms table. */
    fun exportSms(): String {
        verifyPermission(Manifest.permission.READ_SMS)
        val result = uniqueName("sms", "json")
        try {
            OutputStreamWriter(FileOutputStream(result), Charsets.UTF_8).use { output ->
                val header = JSONObject()
                    .put("format", "ferrypane.sms.v1")
                    .put("exportedAtUtc", SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
                        timeZone = java.util.TimeZone.getTimeZone("UTC")
                    }.format(Date()))
                output.write("{\"format\":\"ferrypane.sms.v1\",")
                output.write("\"exportedAtUtc\":${JSONObject.quote(header.getString("exportedAtUtc"))},")
                output.write("\"messages\":[")
                val cols = arrayOf(
                    Telephony.Sms.ADDRESS, Telephony.Sms.BODY,
                    Telephony.Sms.DATE, Telephony.Sms.DATE_SENT,
                    Telephony.Sms.TYPE, Telephony.Sms.READ
                )
                val cursor = activity.contentResolver.query(
                    Telephony.Sms.CONTENT_URI, cols, null, null,
                    Telephony.Sms.DATE + " ASC"
                ) ?: throw IllegalStateException("Не удалось открыть базу SMS")
                cursor.use {
                    var first = true
                    while (it.moveToNext()) {
                        val row = JSONObject()
                            .put("address", it.getString(0) ?: "")
                            .put("body", it.getString(1) ?: "")
                            .put("date", if (it.isNull(2)) 0L else it.getLong(2))
                            .put("dateSent", if (it.isNull(3)) 0L else it.getLong(3))
                            .put("type", if (it.isNull(4)) 0 else it.getInt(4))
                            .put("read", if (it.isNull(5)) 0 else it.getInt(5))
                        if (!first) output.write(",")
                        output.write(row.toString())
                        first = false
                    }
                }
                output.write("]}")
            }
            return result.absolutePath
        } catch (e: Exception) {
            result.delete()
            throw e
        }
    }

    fun prepareContactsImport(): String {
        val target = File(activity.cacheDir, "ferrypane-import/${UUID.randomUUID()}")
        if (!target.mkdirs()) throw IllegalStateException("Не удалось создать временный каталог")
        return target.absolutePath
    }

    /**
     * Launch the phone's contacts app. It owns the import/merge workflow;
     * we cannot claim contacts have been restored when this intent returns.
     */
    fun openContactsImport(path: String): String {
        val base = File(activity.cacheDir, "ferrypane-import").canonicalFile
        val file = File(path).canonicalFile
        if (!file.path.startsWith(base.path + File.separator) ||
            !file.isFile || !file.name.endsWith(".vcf", ignoreCase = true) ||
            file.length() > 100L * 1024L * 1024L || file.length() == 0L) {
            throw SecurityException("Некорректный файл импорта контактов")
        }
        val uri = FileProvider.getUriForFile(
            activity, activity.packageName + ".fileprovider", file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "text/x-vcard")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            activity.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw IllegalStateException("На телефоне нет приложения импорта vCard", e)
        }
        return "Открыто приложение импорта контактов — подтвердите импорт в нём"
    }
}
