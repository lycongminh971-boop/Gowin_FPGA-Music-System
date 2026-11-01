package com.epiano.ble.library

import com.epiano.ble.protocol.BUILTIN_SLOT
import com.epiano.ble.protocol.ChordEvent
import com.epiano.ble.protocol.MAX_EVENTS
import com.epiano.ble.protocol.Note
import com.epiano.ble.protocol.REST
import com.epiano.ble.protocol.SONG_COUNT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * 曲库/记账/同步规划单测（v2：和弦事件）。
 *
 * ★ 指纹期望值里的 v1 部分来自 `art1/app_protocol/library.py` 的实测输出
 *   （Python 侧跑出来的），不是手算的。v2 的算法不同，单独验证其性质。
 */
class LibraryTest {

    /** v2：解析成和弦事件。 */
    private fun smallStar() = parseMelody("C4 C4 G4 G4 A4 A4 G4:16")

    /** v1：同样是小星星，但是旧的单音音符列表（用于验证 v1 指纹与迁移）。 */
    private fun smallStarV1() = listOf(
        Note(0, 8), Note(0, 8), Note(7, 8), Note(7, 8),
        Note(9, 8), Note(9, 8), Note(7, 16),
    )

    // -----------------------------------------------------------------------
    // 指纹
    // -----------------------------------------------------------------------

    @Test
    fun `v1 指纹与 Python 实现逐字节一致`() {
        // python: app_protocol.library.fingerprint([...])  —— v1 每音 2 字节
        assertEquals("3ef8faa1b01188a8", fingerprintV1(smallStarV1()))
        assertEquals("7227cc2cdd3a2dcf", fingerprintV1(listOf(Note(0, 8))))
        assertEquals("300bf8c89c74580f", fingerprintV1(listOf(Note(REST, 4), Note(0, 8))))
        assertEquals("514bd9a6ef95e7e4", fingerprintV1(listOf(Note(0, 8), Note(2, 8))))
    }

    @Test
    fun `v2 指纹与 v1 必然不同 升级后自动全量重传`() {
        // 这是设计意图：格式变了 ⇒ 指纹变 ⇒ 旧曲库升级后自动重传一次，
        // 不需要用户手动清账。
        assertNotEquals(fingerprintV1(smallStarV1()), fingerprint(smallStar()))
    }

    @Test
    fun `指纹长度固定为 16 个 hex 字符`() {
        val fp = fingerprint(smallStar())
        assertEquals(FINGERPRINT_LEN, fp.length)
        assertTrue(fp.all { it in "0123456789abcdef" })
    }

    @Test
    fun `指纹只看会影响声音的部分`() {
        assertEquals(fingerprint(smallStar()), fingerprint(smallStar()))
        // 改一个时值 ⇒ 指纹必须变
        val changed = smallStar().toMutableList().also { it[0] = ChordEvent.single(0, 4) }
        assertNotEquals(fingerprint(smallStar()), fingerprint(changed))
        // 改一个键位 ⇒ 指纹必须变
        val changedKey = smallStar().toMutableList().also { it[2] = ChordEvent.single(9, 8) }
        assertNotEquals(fingerprint(smallStar()), fingerprint(changedKey))
    }

    @Test
    fun `和弦与单音是不同指纹`() {
        val single = listOf(ChordEvent.single(0, 8))
        val chord = listOf(ChordEvent.of(listOf(0, 4), 8))
        assertEquals(single.size, chord.size)
        assertNotEquals(fingerprint(single), fingerprint(chord))
    }

    @Test
    fun `长度前缀防止拼接歧义`() {
        // v1 的经典案例：(1,23) 与 (12,3) 的「每音 2 字节」拼接结果相同，
        // 若不先喂长度，两首不同的谱会算出同一个指纹。
        assertNotEquals(fingerprintV1(listOf(Note(1, 23))), fingerprintV1(listOf(Note(12, 3))))
        // v2 同样需要（每事件 4 字节）
        assertNotEquals(
            fingerprint(listOf(ChordEvent.single(1, 23))),
            fingerprint(listOf(ChordEvent.single(12, 3))),
        )
    }

    // -----------------------------------------------------------------------
    // 增删改查
    // -----------------------------------------------------------------------

    @Test
    fun `改名不改 entryId 也不改指纹`() {
        val lib = Library()
        val e = lib.add("旧名", smallStar())
        val renamed = lib.rename(e.entryId, "新名")
        assertEquals(e.entryId, renamed.entryId)
        assertEquals(e.fingerprint, renamed.fingerprint)
        assertEquals("新名", lib.get(e.entryId).name)
        // 按新名也能取到
        assertEquals(e.entryId, lib.get("新名").entryId)
    }

    @Test
    fun `删除会同时从曲单里摘掉`() {
        val lib = Library()
        val e = lib.add("要被删的", smallStar())
        lib.setPlaylist(listOf(e.entryId))
        assertEquals(1, lib.playlistEntries().size)
        lib.remove(e.entryId)
        assertEquals(0, lib.playlistEntries().size)
        assertNull(lib.playlist[0])
    }

    @Test
    fun `曲单最多 4 槽`() {
        val lib = Library()
        val ids = (1..5).map { lib.add("曲$it", smallStar()).entryId }
        lib.setPlaylist(ids.take(4))          // 恰好 4 个可以
        try {
            lib.setPlaylist(ids)              // 5 个必须被拒
            fail("5 槽应该被拒（板子只有 4 槽）")
        } catch (_: IllegalArgumentException) {
        }
    }

    @Test
    fun `曲单不足 4 个时其余槽为空`() {
        val lib = Library()
        val a = lib.add("A", smallStar())
        lib.setPlaylist(listOf(a.entryId))
        assertEquals(1, lib.playlistEntries().size)
        for (i in 1 until SONG_COUNT) assertNull(lib.playlist[i])
    }

    // -----------------------------------------------------------------------
    // 同步规划 —— 这是记账机制的核心判据
    // -----------------------------------------------------------------------

    @Test
    fun `首次同步默认全部下发 含槽0`() {
        // ★ 2026-10-28 语义变更：protectBuiltinSlot 默认改为 false，
        //   4 个槽都能用。原来这里断言「槽0被保护、只发2首」，
        //   正是"界面放小星星、板子播欢乐颂"的根源。
        val lib = Library()
        val a = lib.add("A", smallStar())
        val b = lib.add("B", parseMelody("C4 D4 E4"))
        val c = lib.add("C", parseMelody("G4 A4 B4"))
        lib.setPlaylist(listOf(a.entryId, b.entryId, c.entryId))

        val plan = lib.planSync()
        assertEquals(0, plan.builtinProtected.size)
        assertEquals(3, plan.uploadCount)
        assertEquals(listOf(0, 1, 2), plan.uploads.map { it.first })
    }

    @Test
    fun `显式开启保护时槽0才被跳过`() {
        val lib = Library()
        lib.protectBuiltinSlot = true
        val a = lib.add("A", smallStar())
        lib.setPlaylist(listOf(a.entryId))

        val plan = lib.planSync()
        assertEquals(1, plan.builtinProtected.size)
        assertEquals(BUILTIN_SLOT, plan.builtinProtected[0].first)
        assertEquals(0, plan.uploadCount)
    }

    @Test
    fun `记账一致时一帧不发`() {
        val lib = Library()
        val a = lib.add("A", smallStar())
        val b = lib.add("B", parseMelody("C4 D4 E4"))
        lib.setPlaylist(listOf(a.entryId, b.entryId))

        // 模拟同步成功后的记账
        lib.noteBoardState(0, a)
        lib.noteBoardState(1, b)

        val plan = lib.planSync()
        assertEquals(0, plan.uploadCount)
        // 2026-10-28：槽0 不再受保护，两个槽都记为「已是最新」
        assertEquals(0, plan.builtinProtected.size)
        assertEquals(2, plan.skips.size)
    }

    @Test
    fun `改谱会触发重传 改名不会`() {
        val lib = Library()
        val e = lib.add("原名", smallStar())
        lib.setPlaylist(listOf(e.entryId, e.entryId))     // 槽 0 与 1 都用它
        lib.noteBoardState(0, e)
        lib.noteBoardState(1, e)

        // 只改名 ⇒ 指纹不变 ⇒ 两槽都跳过
        lib.rename(e.entryId, "改过的名字")
        assertEquals(0, lib.planSync().uploadCount)

        // 改谱 ⇒ 指纹变 ⇒ 两槽都要重传（槽0 现在也受同一判据管辖）
        val e2 = lib.entries[e.entryId]!!
        lib.entries[e.entryId] = e2.copy(notes = parseMelody("C4 C4 C4 C4"))
        assertEquals(2, lib.planSync().uploadCount)
    }

    @Test
    fun `forceFull 无条件全传 槽0 也在内`() {
        val lib = Library()
        val a = lib.add("A", smallStar())
        val b = lib.add("B", parseMelody("C4 D4 E4"))
        lib.setPlaylist(listOf(a.entryId, b.entryId))
        lib.noteBoardState(0, a)
        lib.noteBoardState(1, b)

        // 平时一帧不发
        assertEquals(0, lib.planSync().uploadCount)

        // forceFull：两槽都重传（2026-10-28 起槽0 不再被保护）
        val plan = lib.planSync(forceFull = true)
        assertEquals(2, plan.uploadCount)
        assertEquals(0, plan.builtinProtected.size)
        // forceFull 时 skips 里不能还留着同一槽，两个列表不能自相矛盾
        assertTrue(plan.skips.none { it.first == 0 })
        assertTrue(plan.skips.none { it.first == 1 })
    }

    @Test
    fun `forceBuiltin 才能覆盖槽 0`() {
        val lib = Library()
        val a = lib.add("A", smallStar())
        lib.setPlaylist(listOf(a.entryId))
        val plan = lib.planSync(forceBuiltin = true)
        assertEquals(1, plan.uploadCount)
        assertEquals(BUILTIN_SLOT, plan.uploads[0].first)
        assertEquals(0, plan.builtinProtected.size)
    }

    @Test
    fun `关掉内置曲保护后槽 0 正常下发`() {
        val lib = Library()
        lib.protectBuiltinSlot = false
        val a = lib.add("A", smallStar())
        lib.setPlaylist(listOf(a.entryId))
        val plan = lib.planSync()
        assertEquals(1, plan.uploadCount)
        assertEquals(0, plan.builtinProtected.size)
    }

    @Test
    fun `忘记板内状态后全部重传`() {
        val lib = Library()
        val a = lib.add("A", smallStar())
        val b = lib.add("B", parseMelody("C4 D4 E4"))
        lib.setPlaylist(listOf(a.entryId, b.entryId))
        lib.noteBoardState(0, a)
        lib.noteBoardState(1, b)
        assertEquals(0, lib.planSync().uploadCount)

        lib.forgetBoard()
        assertNull(lib.boardState[0])
        assertNull(lib.boardState[1])
        assertEquals(2, lib.planSync().uploadCount)   // 两槽都重新下发
    }

    @Test
    fun `同步计划描述含字节数与预估秒数`() {
        val lib = Library()
        val a = lib.add("A", smallStar())
        lib.setPlaylist(listOf(a.entryId, a.entryId))
        val plan = lib.planSync()
        // 2026-10-28：槽0 不再受保护 ⇒ 两个槽都下发 ⇒ 字节数是单槽的 2 倍
        assertEquals(a.sizeBytes * 2, plan.totalBytes)
        assertTrue(plan.describe().contains("槽1"))
    }

    // -----------------------------------------------------------------------
    // 持久化
    // -----------------------------------------------------------------------

    @Test
    fun `JSON 往返保持全部字段`() {
        val lib = Library()
        val a = lib.add("小星星", smallStar(), tags = listOf("儿歌", "入门"))
        val b = lib.add("两只老虎", parseMelody("C4 D4 E4 C4"))
        lib.setPlaylist(listOf(a.entryId, b.entryId))
        lib.noteBoardState(1, b)
        lib.protectBuiltinSlot = false

        val text = lib.toJsonString()
        val back = Library.fromJsonString(text)

        assertEquals(2, back.size)
        assertEquals(lib.protectBuiltinSlot, back.protectBuiltinSlot)
        assertEquals(a.entryId, back.playlist[0])
        assertEquals(b.entryId, back.playlist[1])
        assertEquals(b.fingerprint, back.boardState[1])
        assertNull(back.boardState[0])

        val a2 = back.get(a.entryId)
        assertEquals("小星星", a2.name)
        assertEquals(listOf("儿歌", "入门"), a2.tags)
        // 音符逐个比对 —— 只要有一个字节错，指纹就会变，进而导致整库重传
        assertEquals(a.notes, a2.notes)
        assertEquals(a.fingerprint, a2.fingerprint)
    }

    @Test
    fun `JSON 是 UTF-8 中文可读且可 diff`() {
        val lib = Library()
        lib.add("中文曲名", smallStar())
        val text = lib.toJsonString()
        // 不能把中文转成 \uXXXX —— 那样就没法人工 diff 了
        assertTrue("中文应原样保留，实际：$text", text.contains("中文曲名"))
    }

    @Test
    fun `v1 老文件能迁移成 v2 事件`() {
        // v1：无 version 字段、曲单字段名是 play_list、音符在 notes_flat
        val v1 = """
            {
              "entries": [
                {"entry_id":"abc123","name":"老歌","notes_flat":[0,8,2,8],"tags":[]}
              ],
              "play_list": ["abc123", null, null, null]
            }
        """.trimIndent()
        val lib = Library.fromJsonString(v1)
        assertEquals(Library.FORMAT_VERSION, lib.version)
        assertEquals(1, lib.size)
        assertEquals("abc123", lib.playlist[0])
        assertEquals("老歌", lib.get("abc123").name)

        // 旧音符 0,2 应升级成两个**单键事件**（掩码 1<<0 和 1<<2）
        val migrated = lib.get("abc123").notes
        assertEquals(2, migrated.size)
        assertEquals(ChordEvent.single(0, 8), migrated[0])
        assertEquals(ChordEvent.single(2, 8), migrated[1])

        // 升级后走 v2 指纹（与 v1 指纹不同 ⇒ 下次连接会自动重传）
        assertEquals(fingerprint(migrated), lib.get("abc123").fingerprint)
        assertNotEquals(fingerprintV1(listOf(Note(0, 8), Note(2, 8))), lib.get("abc123").fingerprint)
    }

    @Test
    fun `v1 的休止 0x7F 迁移成全零掩码`() {
        val v1 = """
            {"entries":[{"entry_id":"r1","name":"带休止","notes_flat":[127,4,0,8],"tags":[]}],
             "playlist":["r1",null,null,null]}
        """.trimIndent()
        val lib = Library.fromJsonString(v1)
        val ev = lib.get("r1").notes
        assertEquals(2, ev.size)
        assertTrue("0x7F 应迁移成 keys=0 的休止", ev[0].isRest)
        assertEquals(4, ev[0].dur)
        assertEquals(ChordEvent.single(0, 8), ev[1])
    }

    @Test
    fun `损坏的 JSON 抛异常而不是静默返回空库`() {
        // 静默返回空库会让用户以为自己的曲库没了，比抛异常糟糕得多
        for (bad in listOf("{", "{\"a\":", "not json", "{\"entries\":[}", "[1,2")) {
            try {
                Library.fromJsonString(bad)
                fail("「$bad」应该抛异常")
            } catch (_: LibraryException) {
            }
        }
    }

    @Test
    fun `JSON 解析器处理转义与嵌套`() {
        val o = Json.parse("""{"s":"a\"b\\c\nd","n":-12,"b":true,"z":null,"a":[1,2]}""") as JsonValue.Obj
        assertEquals("a\"b\\c\nd", o.str("s"))
        assertEquals(-12L, o.num("n"))
        assertTrue(o.bool("b"))
        assertTrue(o.has("z"))
        assertEquals(2, o.arr("a").size)
    }

    // -----------------------------------------------------------------------
    // 简谱解析
    // -----------------------------------------------------------------------

    @Test
    fun `简谱解析支持默认时值 休止与显式时值`() {
        val n = parseMelody("C4 D4 - E4:16")
        assertEquals(4, n.size)
        // v2：单音事件的掩码 = 1 << 键号
        assertEquals(ChordEvent.single(0, 8), n[0])       // 默认时值 8
        assertEquals(ChordEvent.single(2, 8), n[1])
        assertEquals(ChordEvent.rest(8), n[2])            // `-` 是休止（keys=0）
        assertEquals(ChordEvent.single(4, 16), n[3])      // 显式时值
    }

    @Test
    fun `简谱解析拒绝非法时值`() {
        // 时值 0 在 RTL 里会让整块 DATA 被拒，必须在输入端就拦住
        for (bad in listOf("C4:0", "C4:128", "C4:-1")) {
            try {
                parseMelody(bad)
                fail("「$bad」应该被拒")
            } catch (_: LibraryException) {
            }
        }
    }

    @Test
    fun `简谱解析拒绝非法音名`() {
        try {
            parseMelody("H4")
            fail("H4 应该被拒")
        } catch (_: Exception) {
        }
    }

    @Test
    fun `默认曲库可播种且都能同步`() {
        val lib = Library.seedDefaults()
        assertEquals(6, lib.size)   // 2026-10-29：加了「音阶」「茉莉花」，共 6 首
        // 曲单只有 4 个槽，所以只下发前 4 首；其余留在曲库不下发
        lib.setPlaylist(lib.entries.keys.take(SONG_COUNT).toList())
        val plan = lib.planSync()
        assertEquals(4, plan.uploadCount)
        assertEquals(listOf(0, 1, 2, 3), plan.uploads.map { it.first })
        assertEquals(0, plan.builtinProtected.size)
    }


    @Test
    fun `小星星与文档示例一致`() {
        // 文档 §6.1：C4 C4 G4 G4 A4 A4 G4:16
        // 键号 0 0 7 7 9 9 7；v2 下每事件掩码 = 1<<键号
        val ev = smallStar()
        assertEquals(listOf(0, 0, 7, 7, 9, 9, 7), ev.map { Integer.numberOfTrailingZeros(it.keys) })
        assertEquals(listOf(8, 8, 8, 8, 8, 8, 16), ev.map { it.dur })
        // 都是单音事件
        assertTrue(ev.all { it.size == 1 })
    }

    @Test
    fun `简谱支持和弦 用加号`() {
        val ev = parseMelody("C4+E4+G4:16 B4+D5:8")
        assertEquals(2, ev.size)
        assertEquals(0x91, ev[0].keys)          // bit0|bit4|bit7
        assertEquals(16, ev[0].dur)
        assertEquals(0x4800, ev[1].keys)        // bit11|bit14
        assertEquals(8, ev[1].dur)
        assertEquals("C4+E4+G4", ev[0].name)
    }

    @Test
    fun `Entry 的派生属性与事件数一致`() {
        val lib = Library()
        val e = lib.add("A", smallStar())
        assertEquals(7, e.count)
        // v2：7 事件 × 4 字节 = 28 字节（v1 是 14）
        assertEquals(28, e.sizeBytes)
        assertEquals(28, e.payloadBytes.size)
    }

    @Test
    fun `曲库拒绝超过 127 事件的谱`() {
        val tooMany = List(MAX_EVENTS + 1) { ChordEvent.single(0, 8) }
        val lib = Library()
        try {
            lib.add("太长", tooMany)
            fail("超过 $MAX_EVENTS 事件应被拒")
        } catch (_: IllegalArgumentException) {
        }
    }

    @Test
    fun `search 按名字与标签过滤`() {
        val lib = Library()
        lib.add("小星星", smallStar(), tags = listOf("儿歌"))
        lib.add("练习曲", parseMelody("C4 D4"), tags = listOf("练习"))
        assertEquals(1, lib.search("星星").size)
        assertEquals(1, lib.search(tag = "练习").size)
        assertEquals(2, lib.search().size)
        assertEquals(0, lib.search("不存在").size)
    }

    @Test
    fun `曲库为空时同步计划是空的`() {
        val lib = Library()
        val plan = lib.planSync()
        assertEquals(0, plan.uploadCount)
        assertEquals(0, plan.totalBytes)
        assertFalse(plan.describe().isEmpty())
    }

    @Test
    fun `按槽位设置曲单时空槽必须保留位置`() {
        // 2026-10-28 回归用例：用户「点槽 3，曲子自己滑到槽 1」。
        // 根因是调用方为了传给 setPlaylist(List<String>) 而 filterNotNull()，
        // 把空槽压缩掉了。setSlots 必须原样保留 null 的位置。
        val lib = Library()
        val a = lib.add("A", smallStar())
        val b = lib.add("B", parseMelody("C4 D4"))

        // A 放槽 1，B 放槽 4（索引 0 和 3），中间空着
        lib.setSlots(listOf(a.entryId, null, null, b.entryId))
        assertEquals(a.entryId, lib.playlist[0])
        assertNull(lib.playlist[1])
        assertNull(lib.playlist[2])
        assertEquals(b.entryId, lib.playlist[3])
        assertEquals(
            listOf("A", null, null, "B"),
            lib.playlist.map { id -> id?.let { lib.get(it).name } },
        )
    }

    @Test
    fun `对比 filterNotNull 会把槽位压缩掉`() {
        // 说明这个 bug 的成因：同样的输入，filterNotNull 之后长度从 4 变 2，
        // 槽 4 的曲子被前移到了槽 2。
        val ids: List<String?> = listOf("a", null, null, "b")
        assertEquals(4, ids.size)
        assertEquals(listOf("a", "b"), ids.filterNotNull())

        val lib = Library()
        val a = lib.add("A", smallStar())
        val b = lib.add("B", parseMelody("C4 D4"))
        lib.setPlaylist(listOf(a.entryId, b.entryId))       // 这就是 bug 路径
        assertEquals(a.entryId, lib.playlist[0])
        assertEquals("B 会被前移到槽 2", b.entryId, lib.playlist[1])
        assertNull("槽 4 丢了", lib.playlist[3])
    }

    @Test
    fun `setSlots 越界拒绝`() {
        val lib = Library()
        try {
            lib.setSlots(List(SONG_COUNT + 1) { null })
            fail("超过 $SONG_COUNT 个槽应被拒")
        } catch (_: IllegalArgumentException) {
        }
    }
}
