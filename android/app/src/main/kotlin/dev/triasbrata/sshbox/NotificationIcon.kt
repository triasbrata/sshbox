package dev.triasbrata.sshbox

/**
 * The notification icon, named to flutter_local_notifications by its resource
 * id rather than by `@drawable/ic_stat_jeansh` (JEANSH-8).
 *
 * The plugin turns whatever name it is given into an id with
 * `Resources.getIdentifier`, at its start and at every notification. Given a
 * name, that goes down to `AssetManager2::GetResourceId` and
 * `LoadedPackage::FindEntryByName`, which on Android 8 to 11 walks every
 * configuration of the type as if its entries were dense: a type chunk
 * written sparse, as a Play-served APK can carry, is read past its end and
 * the process dies of a SIGSEGV no Java or Dart catch sees. Android 12 bounds
 * the reads, which is why only an Android 11 device ever reported it.
 *
 * `getIdentifier` first tries the name as a number and returns it unread, so
 * the id written out in decimal never reaches native code at all. The id is
 * this build's own and read afresh at every start; the reference from code
 * also keeps the drawable through resource shrinking.
 */
object NotificationIcon {
    fun name(): String = R.drawable.ic_stat_jeansh.toString()
}
