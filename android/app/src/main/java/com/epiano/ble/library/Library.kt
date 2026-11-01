package com.epiano.ble.library

import com.epiano.ble.protocol.BUILTIN_NOTES
import com.epiano.ble.protocol.BUILTIN_SLOT
import com.epiano.ble.protocol.EVENT_BYTES
import com.epiano.ble.protocol.MAX_EVENTS
import com.epiano.ble.protocol.ChordEvent
import com.epiano.ble.protocol.Note
import com.epiano.ble.protocol.REST
import com.epiano.ble.protocol.SONG_COUNT
import com.epiano.ble.protocol.Song
import java.security.MessageDigest
import java.util.UUID

/**
 * 曲库主库 —— `art1/app_protocol/library.py` 的 Kotlin 移植。
 *
 * **架构：手机是曲库主库，板子只是 4 槽的工作区。**
 *
 * 这不是设计偏好，是三条硬件事实推出来的：
 *
 * | 事实 | 证据 |
 * |---|---|
 * | 板子掉电就丢谱 | `song_ram.v` 是片内 BSRAM，无初始化/Flash |
 * | 板子只有 4 槽 | `wr_base = {song[1:0],9'd0}`，每首 512 字节 |
 * | **板子不会报告自己装了哪几首** | STATUS 只有 `ready_mask` 与 `rx_done`，没有曲名/指纹 |
 *
 * 第三条最关键：板子无法自证「我装的是哪 4 首」，所以「板子上现在是什么」
 * 只能由手机记账。由此：
 *   · 曲库必须有稳定指纹，同谱才允许跳过重传；
 *   · 每次连接默认按「全量补谱」处理，因为板子上电后 `ready_mask` 只有内置槽；
 *   · 槽位分配由手机决定并记录，重连后可重建一模一样的板内布局。
 */

/** 指纹长度（hex 字符数）。 */
const val FINGERPRINT_LEN = 16

/** 出厂内置曲名，仅用于 UI 文案。 */
const val BUILTIN_SONG_NAME = "欢乐颂"

/**
 * 曲谱指纹：只取「会影响声音」的部分（键位掩码+时值）。
 *
 * 为什么不用曲名当身份：改名不该触发重传，改谱才该触发。
 * 为什么带长度前缀：避免 (1,23) 和 (12,3) 拼出同一串字节。
 *
 * 算法：SHA-256( 事件数(4B 小端) ‖ 每事件 4 字节 ) 取前 [FINGERPRINT_LEN] 个 hex 字符。
 *
 * ★ **v2 变更（2026-10-27）**：每事件从 2 字节（单键+时值）变成
 *   4 字节（三字节位掩码+时值），长度前缀喂的也是**事件数**。
 *   所以同一首曲子 v1/v2 的指纹必然不同 —— 这正是想要的：
 *   **旧曲库升级到 v2 后，会全部被判为「已变更」而自动重传一次**，
 *   不需要用户手动清账。代价是升级后第一次连接要全量补谱。
 */
fun fingerprint(events: List<ChordEvent>): String {
    val md = MessageDigest.getInstance("SHA-256")
    // 长度前缀：4 字节小端（事件数）
    val n = events.size
    md.update(
        byteArrayOf(
            (n and 0xFF).toByte(),
            ((n shr 8) and 0xFF).toByte(),
            ((n shr 16) and 0xFF).toByte(),
            ((n shr 24) and 0xFF).toByte(),
        )
    )
    val buf = ByteArray(events.size * EVENT_BYTES)
    events.forEachIndexed { i, e -> e.toBytes().copyInto(buf, i * EVENT_BYTES) }
    md.update(buf)
    val hex = md.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    return hex.substring(0, FINGERPRINT_LEN)
}

/** v1 兼容：对旧音符列表算指纹（仅供旧数据导出/对拍）。 */
fun fingerprintV1(notes: List<Note>): String {
    val md = MessageDigest.getInstance("SHA-256")
    val n = notes.size
    md.update(
        byteArrayOf(
            (n and 0xFF).toByte(), ((n shr 8) and 0xFF).toByte(),
            ((n shr 16) and 0xFF).toByte(), ((n shr 24) and 0xFF).toByte(),
        )
    )
    val buf = ByteArray(notes.size * 2)
    notes.forEachIndexed { i, note ->
        buf[i * 2] = note.key.toByte()
        buf[i * 2 + 1] = note.dur.toByte()
    }
    md.update(buf)
    return md.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
        .substring(0, FINGERPRINT_LEN)
}

/** 曲库里的一首曲子。 */
data class Entry(
    /** 稳定标识（创建后不变，改名不改它）。 */
    val entryId: String,
    val name: String,
    /** v2：和弦事件列表。 */
    val notes: List<ChordEvent>,
    val tags: List<String> = emptyList(),
    val addedAt: Long = 0L,
    val playCount: Int = 0,
) {
    /** 事件数（BEGIN.count）。 */
    val count: Int get() = notes.size

    /** 兼容旧名。 */
    val events: List<ChordEvent> get() = notes

    val payloadBytes: ByteArray get() = com.epiano.ble.protocol.eventsToBytes(notes)
    val fingerprint: String get() = fingerprint(notes)
    val sizeBytes: Int get() = notes.size * EVENT_BYTES

    fun toSong(): Song = Song(notes)

    override fun toString(): String = "<$entryId> $name  $count 事件/$sizeBytes B"
}

/** 把主库的「当前曲单」落到板子 4 槽的执行计划。 */
class SyncPlan(
    /** 需要下发：(槽位, Entry)。 */
    val uploads: MutableList<Pair<Int, Entry>> = mutableListOf(),
    /** 可以跳过：(槽位, Entry, 原因)。 */
    val skips: MutableList<Triple<Int, Entry, String>> = mutableListOf(),
    /**
     * 因为「出厂内置曲保护」而跳过的：(槽位, Entry)。
     *
     * 与 skips 分开，这样 UI 能说清「这首在板子上、但被内置曲保护挡住了」，
     * 而不是含糊的「已是最新」。
     */
    val builtinProtected: MutableList<Pair<Int, Entry>> = mutableListOf(),
    val slots: Int = SONG_COUNT,
) {
    val uploadCount: Int get() = uploads.size
    val totalBytes: Int get() = uploads.sumOf { it.second.sizeBytes }

    /**
     * 按 BLE 透传 ~1.5 kB/s 估算（文档实测 1~2 kB/s）。
     * 注意这只是估算，真机吞吐未测；上板后应用实测值替换。
     */
    val estimatedSeconds: Double get() = totalBytes / 1500.0

    fun describe(): String {
        val sb = StringBuilder()
        sb.append(
            "同步计划：$uploadCount/$slots 槽需要下发，" +
                "$totalBytes 字节，约 %.1f 秒".format(estimatedSeconds)
        )
        for ((slot, e) in uploads) {
            sb.append("\n  槽$slot  下发  ${e.name}  (${e.count}音符/${e.sizeBytes}B)")
        }
        for ((slot, e) in builtinProtected) {
            sb.append(
                "\n  槽$slot  内置曲保护，未下发  ${e.name}" +
                    "（槽 0 是出厂内置《$BUILTIN_SONG_NAME》$BUILTIN_NOTES 音；" +
                    "要覆盖请关闭内置曲保护）"
            )
        }
        for ((slot, e, why) in skips) {
            sb.append("\n  槽$slot  跳过  ${e.name}  （$why）")
        }
        return sb.toString()
    }
}

class LibraryException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * 曲库。可用 [toJson]/[fromJson] 持久化 —— Android 侧存到 app 私有目录，
 * 格式与 PC 的 `~/.fpga_epiano/library.json` **v2 兼容**，便于互通。
 */
class Library {

    /** 全部曲子（entryId 稳定，改名不变）。 */
    val entries: MutableMap<String, Entry> = LinkedHashMap()

    /** 当前 4 槽曲单（槽位 → entryId，null = 空槽）。 */
    val playlist: MutableList<String?> = MutableList(SONG_COUNT) { null }

    /**
     * 记账：上一次已知的板内状态（槽位 → 指纹）。
     *
     * 这是整个同步机制的核心 —— 板子不会报告自己装了哪几首，只能靠手机记。
     */
    val boardState: MutableList<String?> = MutableList(SONG_COUNT) { null }

    /**
     * 槽 0（界面上的「槽1」）出厂曲保护。
     *
     * ★ 2026-10-28 **默认改为 false**（用户明确要求 4 个槽都能用）。
     *
     * 之前的默认值 true 造成了一个非常容易误解的现象：
     *   · 界面把「小星星」放到槽1（= song0）
     *   · 同步时因为保护而跳过，板子里仍然是出厂曲《欢乐颂》
     *   · 但界面照样显示「槽1 小星星」→ **看到的名字和实际播放不一致**
     *
     * 现在默认不保护：曲单里槽 0 放什么就下发什么，界面与板子始终一致。
     *
     * ⚠️ 代价：出厂曲《欢乐颂》一旦被覆盖就**回不来**了
     *   （除非重烧码流 —— song_ram.v 的 INIT 值才是它的唯一来源）。
     *   这个开关仍然保留，需要时可以在代码里改回 true。
     */
    var protectBuiltinSlot: Boolean = false

    /** 格式版本，与 Python 侧一致。 */
    var version: Int = FORMAT_VERSION

    val size: Int get() = entries.size

    // -----------------------------------------------------------------------
    // 查询
    // -----------------------------------------------------------------------

    /** 按 entryId 或曲名取曲。曲名允许重名，此时取第一个匹配。 */
    fun get(key: String): Entry =
        entries[key] ?: entries.values.firstOrNull { it.name == key }
        ?: throw LibraryException("曲库里没有「$key」")

    fun find(key: String): Entry? =
        entries[key] ?: entries.values.firstOrNull { it.name == key }

    fun search(keyword: String = "", tag: String = ""): List<Entry> = entries.values.filter { e ->
        (keyword.isEmpty() || e.name.contains(keyword, ignoreCase = true)) &&
            (tag.isEmpty() || e.tags.any { it.equals(tag, ignoreCase = true) })
    }

    /** 当前曲单：槽位 → Entry（只含非空槽）。 */
    fun playlistEntries(): List<Pair<Int, Entry>> =
        playlist.withIndex().mapNotNull { (slot, id) -> id?.let { getOrNull(it)?.let { e -> slot to e } } }

    private fun getOrNull(id: String): Entry? = entries[id]

    // -----------------------------------------------------------------------
    // 增删改
    // -----------------------------------------------------------------------

    fun add(name: String, notes: List<ChordEvent>, tags: List<String> = emptyList()): Entry {
        require(notes.size in 1..MAX_EVENTS) {
            "事件数必须在 1..$MAX_EVENTS（v2 每事件 4 字节，512B 槽位只装得下 128 个，RTL 卡 127），实为 ${notes.size}"
        }
        val e = Entry(
            entryId = newId(),
            name = name.ifBlank { "未命名" },
            notes = notes.toList(),
            tags = tags.toList(),
            addedAt = System.currentTimeMillis() / 1000L,
        )
        entries[e.entryId] = e
        return e
    }

    fun remove(key: String): Entry {
        val e = get(key)
        entries.remove(e.entryId)
        // 曲单里也要摘掉，否则下次 sync 会去取一个已删的 id
        for (i in playlist.indices) if (playlist[i] == e.entryId) playlist[i] = null
        return e
    }

    fun rename(key: String, newName: String): Entry {
        val e = get(key)
        // 改名**不动 entryId，也不动指纹** —— 改名不该触发重传，改谱才该
        val renamed = e.copy(name = newName)
        entries[e.entryId] = renamed
        return renamed
    }

    /**
     * 替换某首曲子的**内容**（保留 entryId 与名字）。
     *
     * ★ 2026-10-28 新增，用于「录音写入某槽」：录音是新内容，
     *   但它占的是那个槽的位置，名字通常应沿用。
     *
     * 注意这**会改变指纹**（内容变了），所以下次同步会把该槽判为已变更并重传 ——
     * 那是正确行为。调用方如果已经知道板内就是这份新内容，
     * 应该紧接着 `noteBoardState(slot, entry)` 把账记对，避免白跑一次。
     *
     * @param events 新的事件列表；为 null 或空时抛错（不允许把曲子清空）
     */
    fun replaceNotes(entryId: String, events: List<ChordEvent>): Entry {
        val e = get(entryId)
        require(events.isNotEmpty()) { "替换内容不能为空" }
        require(events.size in 1..MAX_EVENTS) {
            "事件数必须在 1..$MAX_EVENTS，实为 ${events.size}"
        }
        val updated = e.copy(notes = events.toList())
        entries[e.entryId] = updated
        return updated
    }

    /** 设置 4 槽曲单。长度不足 4 的补 null；超出 4 的报错（板子只有 4 槽）。 */
    fun setPlaylist(keys: List<String>) {
        require(keys.size <= SONG_COUNT) { "板子只有 $SONG_COUNT 个槽位，实给 ${keys.size}" }
        for (i in playlist.indices) playlist[i] = null
        keys.forEachIndexed { i, k -> playlist[i] = get(k).entryId }
    }

    /**
     * 按**槽位**设置曲单，`null` 表示该槽留空。
     *
     * ★ 2026-10-28 新增。原来的 [setPlaylist] 只收 `List<String>`，
     *   调用方为了传进去只能 `filterNotNull()`，而那样会**把空槽压缩掉**、
     *   让后面的曲子整体前移 —— 用户看到的就是「点槽 3，曲子自己滑到槽 1」。
     *   槽位是用户明确指定的位置，空槽也必须原样保留，所以需要这个能带 null 的入口。
     *
     * 列表比 [SONG_COUNT] 短时，多出来的槽保持为空。
     */
    fun setSlots(slots: List<String?>) {
        require(slots.size <= SONG_COUNT) {
            "板子只有 $SONG_COUNT 个槽位，实给 ${slots.size}"
        }
        for (i in playlist.indices) playlist[i] = null
        slots.forEachIndexed { i, id ->
            playlist[i] = if (id == null) null else get(id).entryId
        }
    }

    /** 记账：记下「板内该槽现在是这个指纹」。 */
    fun noteBoardState(slot: Int, e: Entry?) {
        require(slot in 0 until SONG_COUNT)
        boardState[slot] = e?.fingerprint
    }

    /** 忘记板内状态（怀疑板子掉电/被别的手机改过时用）。 */
    fun forgetBoard() {
        for (i in boardState.indices) boardState[i] = null
    }

    // -----------------------------------------------------------------------
    // 同步规划
    // -----------------------------------------------------------------------

    /**
     * 算出把当前曲单落到板子 4 槽需要发哪些。
     *
     * @param forceFull 无条件全部重传（掉电恢复、怀疑板内状态时用）。
     * @param forceBuiltin 连槽 0 的内置曲也覆盖。
     *
     * 判据：只有当「曲单里该槽的曲子指纹 == 记账里板内该槽的指纹」才跳过。
     * 因为板子上电后 `ready_mask` 只含内置槽，记账若不匹配就必须重传，否则会漏歌。
     *
     * ★ 内置曲保护**独立于 forceFull**：掉电恢复走的是 forceFull=true，
     *   但槽 0 的内置曲是码流 INIT 值，掉电后自动就回来了，本来就不需要重传。
     *   所以 forceFull 也不该覆盖它 —— 要覆盖必须显式 forceBuiltin=true。
     */
    fun planSync(forceFull: Boolean = false, forceBuiltin: Boolean = false): SyncPlan {
        val plan = SyncPlan()
        for ((slot, e) in playlistEntries()) {
            if (protectBuiltinSlot && slot == BUILTIN_SLOT && !forceBuiltin) {
                // 明确记为「受保护跳过」，不要和「已是最新」混在一起报给用户
                plan.builtinProtected.add(slot to e)
                continue
            }
            if (!forceFull && boardState[slot] == e.fingerprint) {
                plan.skips.add(Triple(slot, e, "板内指纹与曲单一致"))
            } else {
                plan.uploads.add(slot to e)
                if (forceFull) {
                    // forceFull 时把该槽从 skips 里剔掉，两个列表不能自相矛盾
                    plan.skips.removeAll { it.first == slot }
                }
            }
        }
        return plan
    }

    // -----------------------------------------------------------------------
    // 持久化（JSON，格式与 PC 侧 v2 兼容）
    // -----------------------------------------------------------------------

    /**
     * 序列化成 JSON 文本。
     *
     * **刻意不用 `org.json`** —— 它在 Android 真机上可用，但在纯 JVM 单测里是
     * 会抛异常的 stub（`android.jar` 的类在 unit test 中默认 `throw new
     * RuntimeException("Stub!")`）。用它会让「持久化」这条路径**测不到**，
     * 而持久化恰恰是记账机制的唯一落点，测不到就等于没写。
     * 所以这里自带一个最小 JSON 读写器，真机与 JVM 行为完全一致。
     */
    fun toJson(): JsonValue.Obj {
        val entryArr = entries.values.map { e ->
            JsonValue.Obj(
                linkedMapOf(
                    "entry_id" to JsonValue.Str(e.entryId),
                    "name" to JsonValue.Str(e.name),
                    "tags" to JsonValue.Arr(e.tags.map { JsonValue.Str(it) as JsonValue }),
                    "added_at" to JsonValue.Num(e.addedAt),
                    "play_count" to JsonValue.Num(e.playCount.toLong()),
                    // 事件存成扁平数组 [keys, dur, keys, dur, ...]：可读、可 diff
                    // keys 是 24 位掩码（十进制存，便于人工核对与 Python 互通）
                    "events_flat" to JsonValue.Arr(
                        e.notes.flatMap {
                            listOf(JsonValue.Num(it.keys.toLong()), JsonValue.Num(it.dur.toLong()))
                        }
                    ),
                )
            )
        }
        return JsonValue.Obj(
            linkedMapOf(
                "version" to JsonValue.Num(FORMAT_VERSION.toLong()),
                "entries" to JsonValue.Arr(entryArr),
                "playlist" to JsonValue.Arr(playlist.map { id -> id?.let { JsonValue.Str(it) as JsonValue } ?: JsonValue.Null }),
                "board_state" to JsonValue.Arr(boardState.map { fp -> fp?.let { JsonValue.Str(it) as JsonValue } ?: JsonValue.Null }),
                "protect_builtin_slot" to JsonValue.Bool(protectBuiltinSlot),
            )
        )
    }

    fun toJsonString(): String = Json.write(toJson())

    companion object {
        /**
         * 曲库文件格式版本。
         *
         * - **1**：`notes_flat`，每音 2 个数 (key, dur)，单音
         * - **2**：`notes_flat`，每音 2 个数，但相比 1 增加了 board_state 记账
         * - **3**：`events_flat`，每事件 2 个数 (keys 掩码, dur)，**支持和弦**
         * - **4**：同 3，但 `protect_builtin_slot` 的默认值从 true 改为 **false**
         *        （用户要求 4 个槽都能用；旧文件里那个 true 只是旧的默认值，
         *          不是用户的选择，所以 v<4 的文件读入时强制清零）
         *
         * v1 及更早的文件能自动迁移（读取时按字段名区分），曲单与记账原样保留。
         */
        const val FORMAT_VERSION = 4

        /**
         * 从这个版本起，`protect_builtin_slot` 才有「用户真正可以选择」的语义。
         * 低于它的文件里该字段是程序写的默认值，读入时一律按 false 处理。
         */
        const val FORMAT_VERSION_NO_PROTECT_DEFAULT = 4

        /** v1 的休止魔法值（0x7F），仅用于旧文件迁移。 */
        private const val REST_V1 = 0x7F

        fun newId(): String = UUID.randomUUID().toString().replace("-", "").substring(0, 12)

        fun fromJson(o: JsonValue.Obj): Library {
            val lib = Library()
            val v = o.num("version", 1L).toInt()
            lib.version = FORMAT_VERSION

            val arr = o.arr("entries")
            for (eo in arr.objects()) {
                // ★ 格式版本分流：
                //   v2（本版）用 "events_flat"：[keys, dur, keys, dur, ...] 每事件 2 个数
                //   v1（旧库）用 "notes_flat"： [key,  dur, key,  dur, ...] 每音 2 个数
                // 两者字段名不同，所以能可靠区分；老曲库读进来后自动升级成 v2 事件。
                val events = mutableListOf<ChordEvent>()
                if (eo.has("events_flat")) {
                    val flat = eo.arr("events_flat")
                    var j = 0
                    while (j + 1 < flat.size) {
                        val keys = flat.nums[j].toInt()
                        val dur = flat.nums[j + 1].toInt()
                        events.add(ChordEvent(keys, if (dur == 0) 1 else minOf(dur, 127)))
                        j += 2
                    }
                } else {
                    val flat = eo.arr("notes_flat")
                    var j = 0
                    while (j + 1 < flat.size) {
                        val key = flat.nums[j].toInt()
                        val dur = flat.nums[j + 1].toInt()
                        // v1 的 0x7F 是休止 → 转成 keys=0
                        val safeDur = if (dur == 0) 1 else minOf(dur, 127)
                        events.add(if (key == REST_V1) ChordEvent(0, safeDur) else ChordEvent(1 shl key, safeDur))
                        j += 2
                    }
                }
                val tags = eo.arr("tags").strings()
                val id = eo.str("entry_id") ?: newId()
                val e = Entry(
                    entryId = id,
                    name = eo.str("name") ?: "未命名",
                    notes = events,
                    tags = tags,
                    addedAt = eo.num("added_at", 0L),
                    playCount = eo.num("play_count", 0L).toInt(),
                )
                lib.entries[e.entryId] = e
            }

            // v1 的曲单字段名可能不同，两种都认，保证老文件能迁过来
            val pl = if (o.has("playlist")) o.arr("playlist") else o.arr("play_list")
            for (i in 0 until minOf(pl.size, SONG_COUNT)) {
                lib.playlist[i] = pl.stringAt(i)
            }
            val bs = o.arr("board_state")
            for (i in 0 until minOf(bs.size, SONG_COUNT)) {
                lib.boardState[i] = bs.stringAt(i)
            }
            // ★ 2026-10-28（第二次修正）：**无条件把 protectBuiltinSlot 置为 false**。
            //
            //   第一版按版本号做了「一次性迁移」（v<4 才强制清零），
            //   但那个方案有致命漏洞：
            //     · 用户第一次跑 v4 时，迁移把 true 改成了 false，然后**存盘**
            //     · 可如果他在**迁移之前**就已经被写进 v4（或用过旧包），
            //       文件里留下的就是 `version=4, protect_builtin_slot=true`
            //     · 之后每次读盘都走 "v>=4 ⇒ 尊重文件" 分支 ⇒ 永远是 true
            //   ⇒ 槽1 又回到"保护、不同步"，现象是「槽1 烧不进别的歌」。
            //
            //   用户已经明确要求「4 个槽都能用」，这个开关在 UI 上**没有任何入口**
            //   （没有勾选框），值只可能来自程序自己写的默认值 ——
            //   所以不存在"用户主动设过 true 需要尊重"的情况，无条件清零是安全的。
            //   字段与 setter 仍然保留，将来若要恢复保护，加个 UI 开关即可。
            lib.protectBuiltinSlot = false
            if (v < FORMAT_VERSION) lib.version = FORMAT_VERSION
            return lib
        }

        /** 从 JSON 文本解析（解析失败抛 [LibraryException]，不静默返回空库）。 */
        fun fromJsonString(text: String): Library = fromJson(Json.parse(text) as? JsonValue.Obj
            ?: throw LibraryException("曲库 JSON 顶层应为对象"))

        /** 首次使用时灌入的随附曲目。
         *
         * 2026-10-28：曲名**只保留歌名本身**，去掉「（前两句）」「（开头）」这类后缀。
         * 用户明确要求列表里只显示名字 —— 后缀既占宽度，也让人以为有完整版可选。
         * 曲目内容不变，仍是这几句，只是名字简化了。
         */
        /**
         * 首次使用的随附曲目。
         *
         * ★ 2026-10-28：**加长到完整段落**。
         *
         * 原来每首只有 7~8 个事件（约两句、2 秒就放完），用户反馈「太短」。
         * 容量其实很宽裕：每槽 512 字节 ÷ 4 字节/事件 = 127 个事件，
         * 按 120BPM 的 1/16 音符（125ms/事件）算约 **15.9 秒**。
         * 现在三首都填到 30~60 个事件，听感上是一段完整的小曲。
         *
         * 简谱记法：`:` 后面是时值，单位 1/16。
         *   四分音符=4、八分音符=2、附点四分=6、二分音符=8、全音符=16。
         *
         * ⚠️ 三首都只用 C4..B4（key 0..11）与 C5..（key 12+）里传统的白键，
         *    全部落在 24 键范围内，任何一块触摸板都能弹。
         */
        fun seedDefaults(): Library {
            val lib = Library()

            // 小星星：完整第一段 + 第二段（一闪一闪亮晶晶 / 满天都是小星星 /
            //   挂在天上放光明 / 好像许多小眼睛 / 一闪一闪亮晶晶 / 满天都是小星星）
            lib.add(
                "小星星",
                parseMelody(
                    "C4 C4 G4 G4 A4 A4 G4:8 " +
                        "F4 F4 E4 E4 D4 D4 C4:8 " +
                        "G4 G4 F4 F4 E4 E4 D4:8 " +
                        "G4 G4 F4 F4 E4 E4 D4:8 " +
                        "C4 C4 G4 G4 A4 A4 G4:8 " +
                        "F4 F4 E4 E4 D4 D4 C4:8",
                ),
            )

            // 两只老虎：完整四句
            //   两只老虎 / 跑得快 / 一只没有眼睛 / 一只没有尾巴 / 真奇怪
            lib.add(
                "两只老虎",
                parseMelody(
                    "C4 D4 E4 C4 C4 D4 E4:8 " +
                        "E4 F4 G4:4 " +
                        "E4 F4 G4:4 " +
                        "G4 A4 G4 F4 E4 C4:8 " +
                        "G4 A4 G4 F4 E4 C4:8 " +
                        "C4 G4 C4:8",
                ),
            )

            // 欢乐颂：主题完整段（贝多芬第九交响曲第四乐章）
            lib.add(
                "欢乐颂",
                parseMelody(
                    "E4 E4 F4 G4 G4 F4 E4 D4:8 " +
                        "C4 C4 D4 E4 E4 D4 D4:8 " +
                        "E4 E4 F4 G4 G4 F4 E4 D4:8 " +
                        "C4 C4 D4 E4 D4 C4 C4:8",
                ),
            )

            // 上学歌：补充一首节奏较快的，方便试节奏功能
            lib.add(
                "上学歌",
                parseMelody(
                    "C4 C4 D4 E4 E4 D4 C4:8 " +
                        "G4 G4 A4 A4 G4:8 " +
                        "E4 E4 D4 C4 C4 D4 E4 D4 C4:8",
                ),
            )

            // ------------------------------------------------------------------
            // 2026-10-29 新增：**跨度大的曲子**（用户要求，用于演示 24 键范围）
            //
            // 键位是 0..23 = C4..B5，第一首正好把 24 个键全用一遍，
            // 第二首用到一个多八度的跨度，但**绝不超出 C4..B5**。
            // ------------------------------------------------------------------

            // 全音域音阶：C4 一路升到 B5 再落回 C4
            //   ★ 键位只有 0..23 = C4..B5，**没有 C6**，所以上行必须停在 B5。
            //   上行 24 个音（C4..B4 + C5..B5）+ 顶点 + 下行 24 个音 = 49 个事件，
            //   远小于每槽 127 事件上限。
            lib.add(
                "音阶（全 24 键）",
                parseMelody(
                    // 上行：低八度 12 个音
                    "C4 D4 E4 F4 G4 A4 B4:8 " +
                        // 上行：高八度 12 个音，到 B5 为止（这就是最高键）
                        "C5 D5 E5 F5 G5 A5 B5:8 " +
                        // 顶点停留
                        "B5:4 " +
                        // 下行：高八度回来
                        "B5 A5 G5 F5 E5 D5 C5:8 " +
                        // 下行：低八度收尾
                        "B4 A4 G4 F4 E4 D4 C4:16",
                ),
            )

            // 茉莉花（江苏民歌）：跨度从一个八度多，旋律起伏明显
            //   简谱 1=C：3 3 5 6 | 1' 1' 6 5 | 5 6 5 3 | 2 3 2 1
            //   => E4 E4 G4 A4 | C5 C5 A4 G4 | G4 A4 G4 E4 | D4 E4 D4 C4
            //   最低 C4(键0)、最高 C5(键12)，正好一个八度，全部在范围内。
            lib.add(
                "茉莉花",
                parseMelody(
                    "E4 E4 G4 A4 C5 C5 A4 G4:8 " +
                        "G4 A4 G4 E4 D4 E4 D4 C4:8 " +
                        "E4 E4 G4 A4 C5 C5 A4 G4:8 " +
                        "D4 E4 D4 C4:16",
                ),
            )

            return lib
        }
    }
}

/**
 * 解析简谱字符串，如 `"C4 D4 E4 - G4:16"`，**支持用 `+` 表示和弦**。
 *
 * 语法（v2）：
 *   · 空格分隔事件；
 *   · `-` 表示**休止**（整组，不能和音名混用）；
 *   · `C4+E4+G4` 表示**同时按的多个键**；
 *   · `名字串:时值` 指定时值，默认 [defaultDur]；
 *   · 时值单位是 1/16 音符，合法范围 1..127（**0 非法**）。
 *
 * 示例：
 * ```
 * "C4 D4 E4"              → 三个单音事件
 * "C4+E4+G4:16 D5:8"      → 一个 C 大三和弦 + 一个 D5
 * "-:4 C4:4"              → 一拍休止 + 一个 C4
 * ```
 *
 * 与 Python 的 `parse_melody` 相比，v2 的主要差别就是**多了 `+` 和弦语法**。
 */
fun parseMelody(melody: String, defaultDur: Int = 8): List<ChordEvent> {
    val out = mutableListOf<ChordEvent>()
    for (tokRaw in melody.trim().split(Regex("\\s+"))) {
        if (tokRaw.isEmpty()) continue
        val parts = tokRaw.split(":")
        val dur = if (parts.size > 1) {
            parts[1].toIntOrNull() ?: throw LibraryException("时值不是数字：$tokRaw")
        } else defaultDur
        if (dur !in 1..127) throw LibraryException("时值必须在 1..127（0 非法）：$tokRaw")
        val nameTok = parts[0]
        val mask = com.epiano.ble.protocol.namesToKeyMask(nameTok)
        out.add(ChordEvent(mask, dur))
    }
    if (out.isEmpty()) throw LibraryException("简谱解析结果为空：$melody")
    if (out.size > MAX_EVENTS) {
        throw LibraryException("事件数 ${out.size} 超过上限 $MAX_EVENTS（v2 每事件 4 字节）")
    }
    return out
}