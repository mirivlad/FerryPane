package top.mirv.ferrypane

import android.Manifest
import android.content.ContentProviderOperation
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.provider.ContactsContract
import android.telephony.PhoneNumberUtils
import ezvcard.Ezvcard
import ezvcard.VCard
import java.io.File
import java.util.Locale

private typealias Raw = ContactsContract.RawContacts
private typealias Data = ContactsContract.Data
private typealias Phone = ContactsContract.CommonDataKinds.Phone
private typealias Email = ContactsContract.CommonDataKinds.Email
private typealias StructuredName = ContactsContract.CommonDataKinds.StructuredName
private typealias Organization = ContactsContract.CommonDataKinds.Organization
private typealias Note = ContactsContract.CommonDataKinds.Note
private typealias Postal = ContactsContract.CommonDataKinds.StructuredPostal

/**
 * User-approved, in-app vCard import. Never deletes or overwrites existing
 * contacts. Existing contacts matched by phone/email can receive missing
 * phone/email fields. Standard Android ContactsProvider owns persistence.
 */
class ContactsImporter(private val context: Context) {
    private data class Candidate(
        val name: String,
        val phones: List<String>,
        val emails: List<String>,
        val organizations: List<String>,
        val notes: List<String>,
        val addresses: List<String>
    )
    private class Existing(val rawId: Long) {
        val phones = mutableSetOf<String>()
        val emails = mutableSetOf<String>()
    }
    private class Index {
        val byPhone = mutableMapOf<String, Existing>()
        val byEmail = mutableMapOf<String, Existing>()
        val byContactId = mutableMapOf<Long, Existing>()
    }

    private fun requirePermission() {
        for (permission in listOf(Manifest.permission.READ_CONTACTS, Manifest.permission.WRITE_CONTACTS)) {
            if (context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                throw SecurityException("Для импорта FerryPane нужен доступ к чтению и записи контактов")
            }
        }
    }

    private fun checkFile(path: String): File {
        val root = File(context.cacheDir, "ferrypane-import").canonicalFile
        val file = File(path).canonicalFile
        if (!file.path.startsWith(root.path + File.separator) ||
            !file.isFile || !file.name.endsWith(".vcf", ignoreCase = true) ||
            file.length() == 0L || file.length() > 100L * 1024L * 1024L) {
            throw SecurityException("Недопустимый файл .vcf для импорта")
        }
        return file
    }

    private fun phoneKey(value: String): String = PhoneNumberUtils.normalizeNumber(value)
        .filter { it.isDigit() || it == '+' }
    private fun emailKey(value: String): String = value.trim().lowercase(Locale.ROOT)

    private fun cards(file: File): List<Candidate> {
        val parsed: List<VCard> = file.inputStream().use { stream ->
            Ezvcard.parse(stream).all()
        }
        if (parsed.isEmpty() || parsed.size > 20000) {
            throw IllegalArgumentException("Архив пуст или содержит больше 20 000 контактов")
        }
        return parsed.map { card ->
            val structured = card.structuredName
            val defaultName = listOfNotNull(structured?.given, structured?.family)
                .filter { it.isNotBlank() }.joinToString(" ")
            Candidate(
                card.formattedName?.value?.trim().orEmpty().ifBlank { defaultName },
                card.telephoneNumbers.mapNotNull { it.text?.trim()?.takeIf(String::isNotEmpty) }.distinct(),
                card.emails.mapNotNull { it.value?.trim()?.takeIf(String::isNotEmpty) }.distinct(),
                card.organizations.map { it.values.filterNotNull().joinToString(" / ") }
                    .filter { it.isNotBlank() },
                card.notes.mapNotNull { it.value?.takeIf(String::isNotBlank) },
                card.addresses.map { a ->
                    listOfNotNull(a.streetAddress, a.locality, a.region, a.postalCode, a.country)
                        .filter { it.isNotBlank() }.joinToString(", ")
                }.filter { it.isNotBlank() }
            )
        }.filter { it.name.isNotBlank() || it.phones.isNotEmpty() || it.emails.isNotEmpty() }
    }

    private fun index(): Index {
        val result = Index()
        val resolver = context.contentResolver
        // A single cursor over phone/email Data rows avoids one query per
        // entry and includes aggregated contacts from different accounts.
        resolver.query(
            Data.CONTENT_URI,
            arrayOf(Data.CONTACT_ID, Data.RAW_CONTACT_ID, Data.MIMETYPE, Data.DATA1),
            "${Data.MIMETYPE}=? OR ${Data.MIMETYPE}=?",
            arrayOf(Phone.CONTENT_ITEM_TYPE, Email.CONTENT_ITEM_TYPE),
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val contactId = cursor.getLong(0)
                val rawId = cursor.getLong(1)
                val mime = cursor.getString(2)
                val value = cursor.getString(3) ?: continue
                val item = result.byContactId.getOrPut(contactId) { Existing(rawId) }
                if (mime == Phone.CONTENT_ITEM_TYPE) {
                    val key = phoneKey(value)
                    if (key.isNotEmpty()) {
                        item.phones.add(key)
                        result.byPhone[key] = item
                    }
                } else {
                    val key = emailKey(value)
                    if (key.isNotEmpty()) {
                        item.emails.add(key)
                        result.byEmail[key] = item
                    }
                }
            }
        }
        return result
    }

    private fun matching(card: Candidate, index: Index): Existing? {
        for (v in card.phones) index.byPhone[phoneKey(v)]?.let { return it }
        for (v in card.emails) index.byEmail[emailKey(v)]?.let { return it }
        return null
    }

    fun preview(path: String): Map<String, Any> {
        requirePermission()
        val contacts = cards(checkFile(path))
        val existing = index()
        val matches = contacts.count { matching(it, existing) != null }
        return mapOf(
            "total" to contacts.size,
            "matched" to matches,
            "new" to (contacts.size - matches),
            "details" to "FerryPane добавит отсутствующие контакты и телефоны/email к совпадающим. " +
                "Существующие данные не удаляются. Неизвестные поля vCard (например, фото) пока не импортируются."
        )
    }

    fun restore(path: String): Map<String, Any> {
        requirePermission()
        val contacts = cards(checkFile(path))
        val resolver = context.contentResolver
        val existing = index()
        var created = 0
        var expanded = 0
        var unchanged = 0
        var failures = 0
        val errors = mutableListOf<String>()
        for (candidate in contacts) {
            try {
                val match = matching(candidate, existing)
                val ops = arrayListOf<ContentProviderOperation>()
                var rawId = match?.rawId
                if (match == null) {
                    // Null account inserts a local (device) raw contact.
                    ops.add(
                        ContentProviderOperation.newInsert(Raw.CONTENT_URI)
                            .withValue(Raw.ACCOUNT_TYPE, null)
                            .withValue(Raw.ACCOUNT_NAME, null)
                            .build()
                    )
                }

                fun addRow(mime: String, field: String, value: String) {
                    val op = ContentProviderOperation.newInsert(Data.CONTENT_URI)
                    if (match == null) {
                        op.withValueBackReference(Data.RAW_CONTACT_ID, 0)
                    } else {
                        op.withValue(Data.RAW_CONTACT_ID, rawId)
                    }
                    op.withValue(Data.MIMETYPE, mime)
                    op.withValue(field, value)
                    ops.add(op.build())
                }

                if (match == null) {
                    if (candidate.name.isNotBlank()) {
                        addRow(StructuredName.CONTENT_ITEM_TYPE, StructuredName.DISPLAY_NAME, candidate.name)
                    }
                }
                val newPhones = candidate.phones
                    .filter { phoneKey(it).isNotEmpty() && (match == null || !match.phones.contains(phoneKey(it))) }
                val newEmails = candidate.emails
                    .filter { emailKey(it).isNotEmpty() && (match == null || !match.emails.contains(emailKey(it))) }
                for (number in newPhones) addRow(Phone.CONTENT_ITEM_TYPE, Phone.NUMBER, number)
                for (address in newEmails) addRow(Email.CONTENT_ITEM_TYPE, Email.ADDRESS, address)

                if (match == null) {
                    candidate.organizations.firstOrNull()?.let {
                        addRow(Organization.CONTENT_ITEM_TYPE, Organization.COMPANY, it)
                    }
                    candidate.notes.firstOrNull()?.let {
                        addRow(Note.CONTENT_ITEM_TYPE, Note.NOTE, it)
                    }
                    for (address in candidate.addresses.take(6)) {
                        addRow(Postal.CONTENT_ITEM_TYPE, Postal.FORMATTED_ADDRESS, address)
                    }
                }
                if (match != null && newPhones.isEmpty() && newEmails.isEmpty()) {
                    unchanged++
                    continue
                }

                val response = resolver.applyBatch(ContactsContract.AUTHORITY, ops)
                if (match == null) {
                    rawId = response.firstOrNull()?.uri?.let(ContentUris::parseId)
                    val registered = Existing(rawId ?: -1L)
                    for (number in candidate.phones) registered.phones.add(phoneKey(number))
                    for (address in candidate.emails) registered.emails.add(emailKey(address))
                    for (number in candidate.phones) existing.byPhone[phoneKey(number)] = registered
                    for (address in candidate.emails) existing.byEmail[emailKey(address)] = registered
                    created++
                } else {
                    for (number in newPhones) {
                        val key = phoneKey(number)
                        match.phones.add(key)
                        existing.byPhone[key] = match
                    }
                    for (address in newEmails) {
                        val key = emailKey(address)
                        match.emails.add(key)
                        existing.byEmail[key] = match
                    }
                    expanded++
                }
            } catch (e: Exception) {
                failures++
                if (errors.size < 5) errors.add(e.message ?: e.javaClass.simpleName)
            }
        }
        return mapOf(
            "created" to created,
            "expanded" to expanded,
            "unchanged" to unchanged,
            "failed" to failures,
            "errors" to errors.joinToString("; ")
        )
    }
}
