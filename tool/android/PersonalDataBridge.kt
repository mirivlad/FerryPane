package top.mirv.ferrypane

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import android.provider.Telephony
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
        val contactCache = mutableMapOf<String, String?>()
        fun contactName(number: String): String? {
            if (number.isBlank() ||
                activity.checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
                return null
            }
            return contactCache.getOrPut(number) {
                try {
                    val uri = Uri.withAppendedPath(
                        ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                        Uri.encode(number)
                    )
                    activity.contentResolver.query(
                        uri,
                        arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                        null, null, null
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    }
                } catch (_: Exception) {
                    null
                }
            }
        }
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
                        val number = it.getString(0) ?: ""
                        val row = JSONObject()
                            .put("address", number)
                            .put("body", it.getString(1) ?: "")
                            .put("date", if (it.isNull(2)) 0L else it.getLong(2))
                            .put("dateSent", if (it.isNull(3)) 0L else it.getLong(3))
                            .put("type", if (it.isNull(4)) 0 else it.getInt(4))
                            .put("read", if (it.isNull(5)) 0 else it.getInt(5))
                        contactName(number)?.let { name ->
                            row.put("contactName", name)
                        }
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

    private val importer by lazy { ContactsImporter(activity) }

    fun previewContactsImport(path: String): Map<String, Any> =
        importer.preview(path)

    fun restoreContactsImport(path: String): Map<String, Any> =
        importer.restore(path)
}
