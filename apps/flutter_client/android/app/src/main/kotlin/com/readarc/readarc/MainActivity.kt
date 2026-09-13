package com.readarc.readarc

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val channelName = "readarc/library_storage"
    private val chooseRootRequest = 4901
    private var pendingRootResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler(::handleLibraryCall)
    }

    private fun handleLibraryCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "chooseRoot" -> chooseRoot(result)
                "refreshRoot" -> {
                    val tree = rootUri(call)
                    when (rootStatus(tree)) {
                        "available" -> result.success(call.argument<Map<String, Any?>>("root"))
                        "permissionLost" -> throw SecurityException("Persisted SAF permission was lost")
                        "missing" -> throw java.io.FileNotFoundException("Library root is missing")
                        else -> throw java.io.IOException("Library root is temporarily unavailable")
                    }
                }
                "status" -> result.success(rootStatus(rootUri(call)))
                "listEntries" -> result.success(listEntries(rootUri(call)))
                "contentSha256" -> result.success(hash(resolveDocument(rootUri(call), relative(call))))
                "materialize" -> result.success(materialize(rootUri(call), relative(call), call.argument<String>("targetPath")!!))
                "importFile" -> result.success(importFile(rootUri(call), call.argument<String>("sourcePath")!!, call.argument<String>("preferredName")!!))
                "deleteEntry" -> {
                    DocumentsContract.deleteDocument(contentResolver, resolveDocument(rootUri(call), relative(call)))
                    result.success(null)
                }
                "containsFile" -> result.success(false)
                else -> result.notImplemented()
            }
        } catch (error: SecurityException) {
            result.error("permissionLost", error.message, null)
        } catch (error: java.io.FileNotFoundException) {
            result.error("missing", error.message, null)
        } catch (error: Throwable) {
            result.error("temporarilyUnavailable", error.message, null)
        }
    }

    private fun chooseRoot(result: MethodChannel.Result) {
        if (pendingRootResult != null) {
            result.error("busy", "Library picker is already open", null)
            return
        }
        pendingRootResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        startActivityForResult(intent, chooseRootRequest)
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != chooseRootRequest) return
        val pending = pendingRootResult
        pendingRootResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending?.success(null)
            return
        }
        val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        contentResolver.takePersistableUriPermission(uri, flags)
        pending?.success(
            mapOf(
                "kind" to "androidTreeUri",
                "locator" to uri.toString(),
                "displayName" to queryName(DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))),
            ),
        )
    }

    private fun rootUri(call: MethodCall): Uri {
        val root = call.argument<Map<String, Any?>>("root") ?: error("root is required")
        return Uri.parse(root["locator"] as String)
    }

    private fun relative(call: MethodCall): String {
        val value = call.argument<String>("relativeLocation") ?: error("relativeLocation is required")
        val segments = value.split('/')
        require(value.isNotEmpty() && !value.startsWith('/') && '\u0000' !in value)
        require(segments.none { it.isEmpty() || it == "." || it == ".." })
        return value
    }

    private fun rootStatus(tree: Uri): String {
        contentResolver.persistedUriPermissions.firstOrNull {
            it.uri == tree && it.isReadPermission && it.isWritePermission
        }
            ?: return "permissionLost"
        return try {
            val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            contentResolver.query(root, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use {
                if (it.moveToFirst()) "available" else "missing"
            } ?: "temporarilyUnavailable"
        } catch (_: SecurityException) {
            "permissionLost"
        } catch (_: java.io.FileNotFoundException) {
            "missing"
        } catch (_: Throwable) {
            "temporarilyUnavailable"
        }
    }

    private fun listEntries(tree: Uri): List<Map<String, Any?>> {
        when (rootStatus(tree)) {
            "available" -> Unit
            "permissionLost" -> throw SecurityException("Persisted SAF permission was lost")
            "missing" -> throw java.io.FileNotFoundException("Library root is missing")
            else -> throw java.io.IOException("Library root is temporarily unavailable")
        }
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val result = mutableListOf<Map<String, Any?>>()
        walk(tree, root, "", result)
        return result.sortedBy { it["relativeLocation"] as String }
    }

    private fun walk(tree: Uri, parent: Uri, prefix: String, output: MutableList<Map<String, Any?>>) {
        val parentId = DocumentsContract.getDocumentId(parent)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
        val cursor = contentResolver.query(children, projection, null, null, null)
            ?: throw java.io.IOException("Document provider returned no cursor for $prefix")
        cursor.use {
            while (cursor.moveToNext()) {
                val documentId = cursor.string(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val name = cursor.string(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mime = cursor.string(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val relative = if (prefix.isEmpty()) name else "$prefix/$name"
                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walk(tree, uri, relative, output)
                } else {
                    val flags = cursor.longOrZero(DocumentsContract.Document.COLUMN_FLAGS)
                    val isPartial = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                        flags and DocumentsContract.Document.FLAG_PARTIAL.toLong() != 0L
                    output += mapOf(
                        "relativeLocation" to relative,
                        "sizeBytes" to cursor.longOrZero(DocumentsContract.Document.COLUMN_SIZE),
                        "modifiedAt" to cursor.longOrZero(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                            .takeIf { it > 0 }?.let(::isoTimestamp),
                        "availability" to if (isPartial) "requiresMaterialization" else "available",
                    )
                }
            }
        }
    }

    private fun resolveDocument(tree: Uri, relative: String): Uri {
        var current = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        for (segment in relative.split('/').filter { it.isNotEmpty() }) {
            current = findChild(tree, current, segment)?.first ?: throw java.io.FileNotFoundException(relative)
        }
        return current
    }

    private fun findChild(tree: Uri, parent: Uri, name: String): Pair<Uri, String>? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(parent))
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        val cursor = contentResolver.query(children, projection, null, null, null)
            ?: throw java.io.IOException("Document provider returned no cursor while resolving a child")
        cursor.use {
            while (cursor.moveToNext()) {
                if (cursor.string(DocumentsContract.Document.COLUMN_DISPLAY_NAME) == name) {
                    return DocumentsContract.buildDocumentUriUsingTree(
                        tree,
                        cursor.string(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                    ) to cursor.string(DocumentsContract.Document.COLUMN_MIME_TYPE)
                }
            }
        }
        return null
    }

    private fun hash(uri: Uri): String {
        val digest = MessageDigest.getInstance("SHA-256")
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Cannot open $uri" }
            val buffer = ByteArray(256 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun materialize(tree: Uri, relative: String, targetPath: String): String {
        val target = File(targetPath)
        target.parentFile?.mkdirs()
        contentResolver.openInputStream(resolveDocument(tree, relative)).use { input ->
            requireNotNull(input) { "Cannot open $relative" }
            target.outputStream().use { output -> input.copyTo(output) }
        }
        return target.path
    }

    private fun importFile(tree: Uri, sourcePath: String, preferredName: String): String {
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val dot = preferredName.lastIndexOf('.')
        val base = if (dot > 0) preferredName.substring(0, dot) else preferredName
        val extension = if (dot > 0) preferredName.substring(dot) else ""
        var name = preferredName
        var suffix = 2
        while (findChild(tree, root, name) != null) name = "$base ($suffix)${extension}".also { suffix += 1 }
        val source = File(sourcePath)
        val sourceSha = hashFile(source)
        val temporaryName = ".$name.readarc-partial-${System.nanoTime()}"
        var staged: Uri? = DocumentsContract.createDocument(
            contentResolver,
            root,
            "application/octet-stream",
            temporaryName,
        ) ?: error("Cannot create import staging document")
        try {
            FileInputStream(source).use { input ->
                contentResolver.openOutputStream(staged!!, "w").use { output ->
                    requireNotNull(output) { "Cannot stage $name" }
                    input.copyTo(output)
                    output.flush()
                }
            }
            check(hash(staged!!) == sourceSha) { "Imported copy failed SHA-256 verification" }
            check(findChild(tree, root, name) == null) { "Import destination appeared during copy" }
            val committed = DocumentsContract.renameDocument(contentResolver, staged!!, name)
                ?: throw java.io.IOException("Document provider cannot atomically commit an import")
            staged = null
            if (hash(committed) != sourceSha) {
                DocumentsContract.deleteDocument(contentResolver, committed)
                throw java.io.IOException("Committed import failed SHA-256 verification")
            }
            return queryName(committed)
        } finally {
            staged?.let { runCatching { DocumentsContract.deleteDocument(contentResolver, it) } }
        }
    }

    private fun hashFile(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(256 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun queryName(uri: Uri): String = contentResolver.query(
        uri,
        arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
        null,
        null,
        null,
    )?.use { if (it.moveToFirst()) it.string(DocumentsContract.Document.COLUMN_DISPLAY_NAME) else "ReadArc" } ?: "ReadArc"

    private fun Cursor.string(column: String): String = getString(getColumnIndexOrThrow(column)) ?: ""
    private fun Cursor.longOrZero(column: String): Long {
        val index = getColumnIndex(column)
        return if (index < 0 || isNull(index)) 0 else getLong(index)
    }

    private fun isoTimestamp(milliseconds: Long): String {
        val format = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US)
        format.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return format.format(java.util.Date(milliseconds))
    }
}
