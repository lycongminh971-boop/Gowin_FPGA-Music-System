package com.epiano.ble.session

import com.epiano.ble.library.Library
import com.epiano.ble.library.parseMelody
import com.epiano.ble.protocol.BUILTIN_NOTES
import com.epiano.ble.protocol.CMD_BEGIN
import com.epiano.ble.protocol.CMD_DATA
import com.epiano.ble.protocol.CMD_END
import com.epiano.ble.protocol.CMD_MODE
import com.epiano.ble.protocol.CMD_PLAY
import com.epiano.ble.protocol.CMD_QUERY
import com.epiano.ble.protocol.CMD_REC_COMMIT
import com.epiano.ble.protocol.CMD_REC_INFO
import com.epiano.ble.protocol.CMD_REC_READ
import com.epiano.ble.protocol.CMD_REC_START
import com.epiano.ble.protocol.CMD_REC_STOP
import com.epiano.ble.protocol.CMD_SET
import com.epiano.ble.protocol.CMD_STOP
import com.epiano.ble.protocol.MAX_DATA_BYTES
import com.epiano.ble.protocol.ChordEvent
import com.epiano.ble.protocol.Note
import com.epiano.ble.protocol.REST
import com.epiano.ble.protocol.RES_CRC
import com.epiano.ble.protocol.RES_LEN
import com.epiano.ble.protocol.RES_OK
import com.epiano.ble.protocol.RES_SEQ
import com.epiano.ble.protocol.RES_UNKNOWN
import com.epiano.ble.protocol.R_ACK
import com.epiano.ble.protocol.R_DATA
import com.epiano.ble.protocol.R_RECINFO
import com.epiano.ble.protocol.R_STATUS
import com.epiano.ble.protocol.SOF_IN
import com.epiano.ble.protocol.SOF_OUT
import com.epiano.ble.protocol.SONG_COUNT
import com.epiano.ble.protocol.ST_ERROR
import com.epiano.ble.protocol.ST_IDLE
import com.epiano.ble.protocol.ST_READY
import com.epiano.ble.protocol.ST_RXING
import com.epiano.ble.protocol.crc16
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * 会话层单测 —— 用一个**按 RTL 规则写死的假板子**当对端。
 *
 * ★ 这个假板子不是「随便回个 ACK」的空壳，它把 `bt_link.v` 的硬规则都实现了：
 *   CRC 校验、result 码、seq 连续性、END 的字节数判据、PLAY 的就绪门控、
 *   录音区状态。目的正是**防止「App 比 RTL 宽松」** —— 若假板子放行了真板子会拒的帧，
 *   那测试全绿也证明不了真机收得下（这正是 Python 侧第 5 层判据存在的理由）。
 */
private class FakeBoard {

    val songs = Array(SONG_COUNT) { ByteArray(512) }
    val counts = IntArray(SONG_COUNT)
    // 出厂内置曲：上电即就绪（RTL BUILTIN_READY = 0b0001，BUILTIN_NOTES = 62）
    val ready = booleanArrayOf(true, false, false, false)

    init {
        counts[0] = BUILTIN_NOTES
    }

    /** 收到的原始帧，用于断言。 */
    val receivedFrames = mutableListOf<ByteArray>()
    val log = mutableListOf<String>()

    /** 模拟掉电：清空 BSRAM 与就绪位，但内置曲随码流回来。 */
    fun powerCycle() {
        for (i in 0 until SONG_COUNT) {
            songs[i].fill(0)
            counts[i] = 0
        }
        // 出厂内置曲随码流 INIT 回来
        counts[0] = BUILTIN_NOTES
        ready[0] = true
        for (i in 1 until SONG_COUNT) ready[i] = false
    }

    /** 复位脉冲：内置曲不再恢复（RTL 的 builtin_dirty 行为）。 */
    fun softReset() {
        for (i in 0 until SONG_COUNT) ready[i] = false
        for (i in 0 until SONG_COUNT) counts[i] = 0
    }

    // --- 接收状态机（对应 bt_link.v 的 P_HUNT..P_CL1）---
    var state = ST_IDLE

    private var songId = 0
    private var wrBase = 0
    private var wrIdx = 0
    private var songCnt = 0
    private var expSeq = 0
    private var lastDataCrc = 0

    // 录音区
    val recArea = ByteArray(2048)
    var recBusy = false
    var recReady = false
    var recFull = false
    var recBytes = 0
    var recWritePos = 0

    private val out = mutableListOf<Byte>()

    fun takeOutput(): ByteArray {
        val a = out.toByteArray()
        out.clear()
        return a
    }

    /** 喂入一段字节流，返回产生的回帧字节。 */
    fun feed(data: ByteArray): ByteArray {
        var i = 0
        while (i < data.size) {
            val b = data[i].toInt() and 0xFF
            // 简化：只在帧边界处理（FakeBoard 假定上层一次喂一整帧）
            i++
            handleByte(b)
        }
        return takeOutput()
    }

    // 逐字节解析
    private var pst = 0
    private var plen = 0
    private var pcmd = 0
    private var pcnt = 0
    private val pbuf = IntArray(64)
    private var crcLo = 0
    private var rxBytes = mutableListOf<Int>()

    private fun handleByte(b: Int) {
        when (pst) {
            0 -> if (b == SOF_IN) {
                rxBytes = mutableListOf(); pst = 1
            }

            1 -> {
                plen = b; rxBytes.add(b); pst = 2
            }

            2 -> {
                pcmd = b; rxBytes.add(b); pcnt = 0
                pst = if (plen == 0) 4 else 3
            }

            3 -> {
                pbuf[pcnt] = b; rxBytes.add(b); pcnt++
                if (pcnt >= plen) pst = 4
            }

            4 -> {
                crcLo = b; rxBytes.add(b); pst = 5
            }

            5 -> {
                rxBytes.add(b)
                val body = rxBytes.subList(0, rxBytes.size - 2).toIntArray().map { it.toByte() }.toByteArray()
                val c = crc16(body)
                val gotLo = crcLo
                val gotHi = b
                pst = 0
                if (gotLo != (c and 0xFF) || gotHi != ((c shr 8) and 0xFF)) {
                    ack(pcmd, RES_CRC)
                } else {
                    execute()
                }
            }
        }
    }

    private fun execute() {
        receivedFrames.add(byteArrayOf(SOF_IN.toByte()) + rxBytes.map { it.toByte() }.toByteArray())
        when (pcmd) {
            CMD_BEGIN -> {
                if (plen != 2 || pbuf[0] > 3 || pbuf[1] == 0) return ack(pcmd, RES_LEN)
                songId = pbuf[0]; wrBase = songId * 512
                songs[songId].fill(0)
                songCnt = pbuf[1]; wrIdx = 0; expSeq = 0
                ready[songId] = false; counts[songId] = songCnt
                lastDataCrc = 0
                state = ST_RXING
                log.add("BEGIN song=$songId count=$songCnt")
                ack(pcmd, RES_OK)
            }

            CMD_DATA -> {
                val n = pbuf[1]
                // v2 RTL (bt_link.v:284):
                //   plen<4 || pbuf[1]<4 || pbuf[1]>32 || |pbuf[1][1:0] || plen!=pbuf[1]+2 → result 3
                if (plen < 4 || n < 4 || n > 32 || n % 4 != 0 || plen != n + 2) {
                    return ack(pcmd, RES_LEN)
                }
                val body = rxBytes.subList(0, rxBytes.size - 2).toIntArray().map { it.toByte() }.toByteArray()
                val frameCrc = crc16(body)
                // 重传：同一包（seq==expSeq-1 且 CRC 相同）只确认不重写
                if (wrIdx != 0 && pbuf[0] == expSeq - 1 && frameCrc == lastDataCrc) {
                    log.add("DATA 重传去重 seq=${pbuf[0]}")
                    return ack(pcmd, RES_OK)
                }
                if (pbuf[0] != expSeq) return ack(pcmd, RES_SEQ)
                // v2：每事件 4 字节 ⇒ 总字节 = count*4（v1 是 *2）
                if (state != ST_RXING || songCnt == 0 || wrIdx + n > songCnt * 4) {
                    return ack(pcmd, RES_LEN)
                }
                // v2 逐字节校验（RTL A_VALIDATE）：只有每 4 字节组的第 4 个（时值）要 1..127，
                // 前 3 个键位掩码字节**任意值都合法**。
                for (k in 0 until n) {
                    if (k % 4 == 3) {
                        val v = pbuf[2 + k]
                        if (v == 0 || v > 127) return ack(pcmd, RES_LEN)
                    }
                }
                for (k in 0 until n) {
                    // ★ 边界应该按「槽内偏移」判，不是按全局地址：
                    //   原来写 `wrBase + wrIdx < 512`，槽 0 的 wrBase=0 恰好能过，
                    //   槽 1~3（wrBase=512/1024/1536）永远为假 ⇒ 一个字节都不写，
                    //   于是上层的「逐字节核对」必然失败。这是测试替身的 bug，
                    //   不是产品代码的问题。真板子用 `wr_idx<10'd512` 判的是槽内偏移。
                    if (wrIdx < 512) songs[songId][wrIdx] = pbuf[2 + k].toByte()
                    wrIdx++
                }
                expSeq++; lastDataCrc = frameCrc
                log.add("DATA seq=${pbuf[0]} n=$n → wrIdx=$wrIdx")
                ack(pcmd, RES_OK)
            }

            CMD_END -> {
                // v2 RTL: wrIdx == songCnt*4（每事件 4 字节；v1 是 *2）
                if (plen == 1 && pbuf[0] == songId && songCnt != 0 && wrIdx == songCnt * 4) {
                    ready[songId] = true; state = ST_READY
                    log.add("END song=$songId ready")
                    ack(pcmd, RES_OK)
                } else ack(pcmd, RES_LEN)
            }

            CMD_PLAY -> {
                if (plen == 1 && pbuf[0] < 4 && ready[pbuf[0]]) {
                    log.add("PLAY song=${pbuf[0]}")
                    ack(pcmd, RES_OK)
                } else ack(pcmd, RES_LEN)
            }

            CMD_STOP -> if (plen == 0) {
                log.add("STOP"); ack(pcmd, RES_OK)
            } else ack(pcmd, RES_LEN)

            CMD_QUERY -> if (plen == 0) {
                status()
            } else ack(pcmd, RES_LEN)

            CMD_MODE -> {
                if (plen != 2 || pbuf[0] > 2 || pbuf[1] > 3) return ack(pcmd, RES_LEN)
                if (pbuf[0] == 0) {
                    log.add("MODE STOP"); return ack(pcmd, RES_OK)
                }
                if (!ready[pbuf[1]]) return ack(pcmd, RES_LEN)
                log.add("MODE ${pbuf[0]} song=${pbuf[1]}")
                ack(pcmd, RES_OK)
            }

            CMD_SET -> {
                if (plen != 2 || pbuf[0] > 3) return ack(pcmd, RES_LEN)
                val v = pbuf[1]
                val bad = (pbuf[0] == 0 && v > 3) || (pbuf[0] == 1 && v > 24) ||
                    (pbuf[0] == 2 && v > 3) || (pbuf[0] == 3 && v > 1)
                if (bad) ack(pcmd, RES_LEN) else {
                    log.add("SET p=${pbuf[0]} v=$v"); ack(pcmd, RES_OK)
                }
            }

            CMD_REC_START -> {
                if (plen != 0 || recBusy) return ack(pcmd, RES_LEN)
                recBusy = true; recReady = false; recFull = false
                recBytes = 0; recWritePos = 0; recArea.fill(0)
                log.add("REC_START"); ack(pcmd, RES_OK)
            }

            CMD_REC_STOP -> {
                if (plen != 0 || !recBusy) return ack(pcmd, RES_LEN)
                recBusy = false
                if (recBytes > 0) recReady = true
                log.add("REC_STOP bytes=$recBytes"); ack(pcmd, RES_OK)
            }

            CMD_REC_COMMIT -> {
                if (plen != 1 || pbuf[0] > 3) return ack(pcmd, RES_LEN)
                if (!recReady || recBytes == 0) return ack(pcmd, RES_LEN)
                val slot = pbuf[0]
                ready[slot] = false
                val total = minOf(recBytes, 512)
                songs[slot].fill(0)
                for (k in 0 until total) songs[slot][k] = recArea[k]
                // v2：每事件 4 字节 ⇒ 事件数 = 字节数 / 4（v1 是 /2）
                counts[slot] = total / 4
                ready[slot] = true; state = ST_READY
                log.add("REC_COMMIT slot=$slot total=$total")
                ack(pcmd, RES_OK)
            }

            CMD_REC_READ -> {
                if (plen != 3 || pbuf[2] == 0 || pbuf[2] > 16) return ack(pcmd, RES_LEN)
                val addr = pbuf[0] or (pbuf[1] shl 8)
                val n = pbuf[2]
                if (addr + n > 2048) return ack(pcmd, RES_LEN)
                dataReply(addr, recArea.copyOfRange(addr, addr + n))
            }

            CMD_REC_INFO -> if (plen == 0) {
                recInfoReply()
            } else ack(pcmd, RES_LEN)

            else -> ack(pcmd, RES_UNKNOWN)
        }
    }

    // --- 回帧构造 ---

    private fun emit(cmd: Int, payload: ByteArray) {
        val body = byteArrayOf(payload.size.toByte(), cmd.toByte()) + payload
        val c = crc16(body)
        out.add(SOF_OUT.toByte())
        body.forEach { out.add(it) }
        out.add((c and 0xFF).toByte())
        out.add(((c shr 8) and 0xFF).toByte())
    }

    private fun ack(cmd: Int, result: Int) {
        log.add("ACK cmd=$cmd result=$result")
        emit(R_ACK, byteArrayOf(cmd.toByte(), result.toByte()))
    }

    private fun status() {
        // v2 RTL: rx_done <= wr_idx[9:2]，即已收**事件数**（wrIdx/4）
        val done = wrIdx / 4
        var mask = 0
        for (i in 0 until SONG_COUNT) if (ready[i]) mask = mask or (1 shl i)
        emit(
            R_STATUS,
            byteArrayOf(
                state.toByte(), songId.toByte(),
                (done and 0xFF).toByte(), ((done shr 8) and 0xFF).toByte(),
                mask.toByte(),
            )
        )
    }

    private fun recInfoReply() {
        var s = 0
        if (recBusy) s = s or 1
        if (recReady) s = s or 2
        if (recFull) s = s or 4
        emit(R_RECINFO, byteArrayOf(s.toByte(), (recBytes and 0xFF).toByte(), ((recBytes shr 8) and 0xFF).toByte()))
    }

    private fun dataReply(addr: Int, data: ByteArray) {
        emit(
            R_DATA,
            byteArrayOf((addr and 0xFF).toByte(), ((addr shr 8) and 0xFF).toByte(), data.size.toByte()) + data
        )
    }
}

/** 把 FakeBoard 包成 Transport。 */
private class FakeTransport(val board: FakeBoard) : Transport {
    private var pendingOut = ByteArray(0)

    override fun write(data: ByteArray) {
        pendingOut += board.feed(data)
    }

    override fun read(): ByteArray {
        val a = pendingOut
        pendingOut = ByteArray(0)
        return a
    }
}

class SessionTest {

    private fun newSession(lib: Library = Library()): Triple<Session, FakeBoard, FakeTransport> {
        val board = FakeBoard()
        val tp = FakeTransport(board)
        // 单测里不真睡：注入 no-op sleep 与递增假时钟，避免 ackTimeout 空转
        var clock = 0.0
        val s = Session(
            transport = tp,
            lib = lib,
            settle = 0.0,
            ackTimeout = 0.5,
            maxRetries = 3,
            sleep = { clock += it },
            now = { clock },
        )
        return Triple(s, board, tp)
    }

    private fun libWith(playlist: List<Pair<String, String>>): Library {
        val lib = Library()
        for ((name, melody) in playlist) lib.add(name, parseMelody(melody))
        lib.setPlaylist(playlist.map { it.first })
        return lib
    }

    // -----------------------------------------------------------------------
    // 基本收发
    // -----------------------------------------------------------------------

    @Test
    fun `QUERY 返回 STATUS 且内置槽就绪`() {
        val (s, _, _) = newSession()
        val st = s.query()
        assertEquals(ST_IDLE, st.state)
        assertTrue("内置槽 0 上电应就绪", st.ready(0))
        assertFalse(st.ready(1))
    }

    @Test
    fun `心跳就是 QUERY`() {
        val (s, _, _) = newSession()
        assertNotNull(s.heartbeatOnce())
        assertNotNull(s.lastStatus)
    }

    @Test
    fun `单槽完整下发后板子就绪`() {
        val lib = libWith(listOf("A" to "C4 D4 E4 F4 G4"))
        val (s, board, _) = newSession(lib)
        // 曲单只有 A ⇒ 它在槽 0（受保护）；用 forceBuiltin 强制写下去以便逐字节核对
        s.uploadSong(0, lib.get("A"))
        assertTrue(board.ready[0])
        assertEquals(5, board.counts[0])
        // 逐字节核对：这与 Python 侧 assert_board_matches 的用意相同
        val expect = lib.get("A").payloadBytes
        assertTrue(
            "板内字节应与曲谱一致",
            expect.contentEquals(board.songs[0].copyOfRange(0, expect.size))
        )
    }

    @Test
    fun `DATA 分帧每帧不超过 32 字节且是 4 的倍数`() {
        val lib = Library()
        // v2：每事件 4 字节。20 个事件 = 80 字节 ⇒ 每帧最多 32 字节 ⇒ 3 帧（32+32+16）
        lib.add("长曲", List(20) { ChordEvent.single(it % 24, 8) })
        val (s, board, _) = newSession(lib)
        s.uploadSong(1, lib.get("长曲"))
        val dataFrames = board.receivedFrames.filter { (it[2].toInt() and 0xFF) == CMD_DATA }
        assertEquals(3, dataFrames.size)
        for (f in dataFrames) {
            val n = f[4].toInt() and 0xFF     // SOF,LEN,CMD,seq,n
            assertTrue("n=$n 应 ≤ $MAX_DATA_BYTES", n <= MAX_DATA_BYTES)
            assertEquals("v2 要求 n 是 4 的倍数", 0, n % 4)
        }
        assertTrue(board.ready[1])
    }

    @Test
    fun `和弦曲子能正确下发`() {
        val lib = Library()
        lib.add("和弦曲", listOf(
            ChordEvent.of(listOf(0, 4, 7), 16),
            ChordEvent.of(listOf(11, 14), 8),
        ))
        val (s, board, _) = newSession(lib)
        s.uploadSong(2, lib.get("和弦曲"))
        assertTrue(board.ready[2])
        assertEquals(2, board.counts[2])
        // 逐字节核对板内内容
        val expect = lib.get("和弦曲").payloadBytes
        assertTrue(expect.contentEquals(board.songs[2].copyOfRange(0, expect.size)))
    }

    @Test
    fun `PLAY 未就绪槽被拒`() {
        val (s, _, _) = newSession()
        try {
            s.play(2)
            fail("未就绪的槽应该被拒")
        } catch (e: SessionError) {
            // 板子回 result=3 时 sendFrame 会重试到上限再抛，
            // 所以这里拿到的是「发送失败」而不是「被拒」——
            // 这正是 result=3 多义性的直接后果：App 不能靠它区分原因。
            assertTrue("实际：${e.message}", e.message!!.contains("板子拒绝"))
        }
    }

    @Test
    fun `SET 与 MODE 能下发`() {
        val lib = libWith(listOf("A" to "C4 D4"))
        val (s, board, _) = newSession(lib)
        s.uploadSong(1, lib.get("A"))
        s.setParam(0, 2)
        s.setMode(1, 1)          // GUIDE
        s.setMode(2, 1)          // AUTO
        s.setMode(0, 1)          // STOP
        s.stop()
        assertTrue(board.log.any { it.contains("SET p=0 v=2") })
        assertTrue(board.log.any { it.contains("MODE 1") })
        assertTrue(board.log.any { it.contains("MODE STOP") })
    }

    @Test
    fun `MODE 对未就绪槽被拒`() {
        val (s, _, _) = newSession()
        try {
            s.setMode(2, 3)
            fail("未就绪槽的 MODE 应该被拒")
        } catch (e: SessionError) {
            assertTrue("实际：${e.message}", e.message!!.contains("板子拒绝"))
        }
    }

    // -----------------------------------------------------------------------
    // 同步：增量 / 全量 / 内置保护
    // -----------------------------------------------------------------------

    @Test
    fun `首次同步下发非内置槽并记账`() {
        val lib = libWith(listOf("A" to "C4 D4 E4", "B" to "G4 A4 B4", "C" to "C4 C4"))
        val (s, board, _) = newSession(lib)

        val rep = s.sync()
        assertTrue(rep.ok)
        // 曲单顺序是 A,B,C ⇒ 槽 0=A(受内置保护)、槽 1=B、槽 2=C
        // ★ 2026-10-28：槽0 不再受保护 ⇒ A,B,C 全部下发到槽 0,1,2
        assertEquals(3, rep.uploaded.size)
        assertEquals(0, rep.builtinProtected.size)
        assertTrue(board.ready[0])
        assertTrue(board.ready[1])
        // 记账已写入，且**按槽位对应正确的曲子**
        assertEquals(lib.get("A").fingerprint, lib.boardState[0])
        assertEquals(lib.get("B").fingerprint, lib.boardState[1])
        assertEquals(lib.get("C").fingerprint, lib.boardState[2])
        // 槽 0 被 A 覆盖 ⇒ 不再是出厂 62 事件
        assertEquals(3, board.counts[0])
    }

    @Test
    fun `记账一致时重连一帧不发`() {
        val lib = libWith(listOf("A" to "C4 D4 E4", "B" to "G4 A4 B4"))
        val (s, _, tp) = newSession(lib)
        s.sync()
        val before = s.framesSent
        val rep2 = s.sync()
        assertEquals(0, rep2.uploaded.size)
        assertEquals(2, rep2.skipped.size)      // 槽 0、1 都跳过
        // 只发了一条 QUERY（心跳/状态查询），不该有 BEGIN/DATA/END
        assertEquals(before + 1, s.framesSent)
    }

    @Test
    fun `掉电后背板子为空 自动全量重传`() {
        val lib = libWith(listOf("A" to "C4 D4 E4", "B" to "G4 A4 B4", "C" to "C4 C4"))
        val (s, board, _) = newSession(lib)
        s.sync()
        assertTrue(board.ready[1])

        // 板子断电：BSRAM 清空，只有内置曲回来
        board.powerCycle()
        assertFalse(board.ready[1])

        val rep = s.sync()
        assertTrue("应检测到掉电", rep.powerLossDetected)
        // ★ 2026-10-28：槽0 不再受保护，三个槽都要重传
        assertEquals(3, rep.uploaded.size)
        assertTrue(board.ready[1])
        assertTrue(board.ready[2])
    }

    @Test
    fun `掉电判据必须排除内置槽`() {
        val lib = libWith(listOf("A" to "C4 D4 E4"))
        // ★ 2026-10-28：槽0 现在默认**可写**，所以只有显式开启保护时，
        //   「ready_mask=0b0001」才等价于「板子刚上电」。
        //   不开保护时槽0 就是个普通槽，它 ready 不代表板子空 ——
        //   这时判空必须看全部 4 位。
        lib.protectBuiltinSlot = true
        val (s, _, _) = newSession(lib)
        val st = s.query()
        assertTrue("保护模式下 ready_mask=0b0001 应判为 blank", s.boardIsBlank(st))

        // 若误用 ready_mask==0 当判据，这里会得到 false（永不触发）——
        // 这正是 Python 侧修掉的那个静默失效 bug。
        assertTrue(st.readyMask != 0)
    }

    @Test
    fun `不保护槽0时 ready_mask=0b0001 不算板子空`() {
        val lib = libWith(listOf("A" to "C4 D4 E4"))
        lib.protectBuiltinSlot = false
        val (s, _, _) = newSession(lib)
        val st = s.query()
        assertFalse("槽0可写时它 ready 说明板上有内容，不能判空", s.boardIsBlank(st))
    }

    @Test
    fun `改谱触发重传 改名不触发`() {
        // 注意顺序：曲单按列表顺序填槽 0,1,2…，而槽 0 永远受内置曲保护，
        // 所以被改的这首必须放在**槽 1**（列表第二个）才可能触发重传。
        val lib = libWith(listOf("占位" to "C4 D4 E4", "目标" to "G4 A4", "C" to "C4 C4"))
        val (s, _, _) = newSession(lib)
        s.sync()

        // 只改名 ⇒ 指纹不变 ⇒ 一帧不发
        lib.rename("目标", "改名后")
        assertEquals(0, s.sync().uploaded.size)

        // 改谱 ⇒ 指纹变 ⇒ 槽 1 必须重传
        val e = lib.get("改名后")
        lib.entries[e.entryId] = e.copy(notes = parseMelody("C4 C4 C4 C4"))
        val rep = s.sync()
        assertEquals(1, rep.uploaded.size)
        assertEquals(1, rep.uploaded[0].first)
    }

    @Test
    fun `同步途中掉电 作废记账并重来`() {
        val lib = libWith(listOf("A" to "C4 D4 E4", "B" to "G4 A4 B4", "C" to "C4 C4"))
        val board = FakeBoard()
        var powerCycled = false

        // 用一层包装：在槽 2 传完之后模拟掉电，触发收尾核对失败
        val tp = object : Transport {
            private var out = ByteArray(0)
            override fun write(data: ByteArray) {
                out += board.feed(data)
                // 槽 1、2 都传完后立刻掉电（此时记账已写，但 BSRAM 被清）
                if (!powerCycled && board.ready[1] && board.ready[2]) {
                    powerCycled = true
                    board.powerCycle()
                }
            }

            override fun read(): ByteArray {
                val a = out; out = ByteArray(0); return a
            }
        }
        var clock = 0.0
        val s = Session(tp, lib, ackTimeout = 0.5, maxRetries = 3,
            sleep = { clock += it }, now = { clock })

        val rep = s.sync()
        assertTrue("应检测到同步途中掉电", rep.powerLossDetected)
        assertTrue("确实发生过掉电", powerCycled)
        // 重来之后板子必须是就绪的（这次不再掉电）
        assertTrue(board.ready[1])
        assertTrue(board.ready[2])
        // 且记账必须与板子真实状态一致
        assertEquals(lib.get("B").fingerprint, lib.boardState[1])
        assertEquals(lib.get("C").fingerprint, lib.boardState[2])
    }

    @Test
    fun `单槽失败不拖垮其它槽`() {
        val lib = libWith(listOf("A" to "C4 D4 E4", "B" to "G4 A4 B4", "C" to "C4 C4"))
        val board = FakeBoard()
        val tp = object : Transport {
            private var out = ByteArray(0)
            var beginCount = 0
            override fun write(data: ByteArray) {
                // 针对「槽 1」的 BEGIN 永远不回帧：模拟这一槽彻底失败。
                // ★ 必须按**载荷里的槽号**判断，不能按「第几次 BEGIN」——
                //   Session 会重发，只吞第一次的话重发就成功了，根本失败不了。
                if ((data[2].toInt() and 0xFF) == CMD_BEGIN) {
                    beginCount++
                    val slot = data[3].toInt() and 0xFF
                    if (slot == 1) return                // 吞掉，触发重试→最终失败
                }
                out += board.feed(data)
            }

            override fun read(): ByteArray {
                val a = out; out = ByteArray(0); return a
            }
        }
        var clock = 0.0
        val s = Session(tp, lib, ackTimeout = 0.2, maxRetries = 1,
            sleep = { clock += it }, now = { clock })

        val rep = s.sync()
        assertFalse("槽 1 应该失败", rep.ok)
        assertEquals(1, rep.failed.size)
        assertEquals(1, rep.failed[0].first)
        // 槽 0、2 仍然成功 —— 槽 1 坏了不该拖垮其它槽
        assertEquals(2, rep.uploaded.size)
        assertEquals(listOf(0, 2), rep.uploaded.map { it.first })
        assertTrue(board.ready[2])
        // 失败的槽绝不能记账（否则下次会误以为它已经传好）
        assertFalse(board.ready[1])
        assertTrue(rep.retries >= 1)
    }

    @Test
    fun `forceFull 强制重传`() {
        val lib = libWith(listOf("A" to "C4 D4 E4", "B" to "G4 A4", "C" to "C4 C4"))
        val (s, _, _) = newSession(lib)
        s.sync()
        assertEquals(0, s.sync().uploaded.size)
        // ★ 2026-10-28：槽0 不再受保护，三个槽全重传
        assertEquals(3, s.sync(forceFull = true).uploaded.size)
    }

    @Test
    fun `forceBuiltin 覆盖槽 0`() {
        val lib = libWith(listOf("A" to "C4 D4 E4"))
        val (s, board, _) = newSession(lib)
        val rep = s.sync(forceBuiltin = true)
        assertEquals(1, rep.uploaded.size)
        assertEquals(0, rep.builtinProtected.size)
        assertTrue(board.ready[0])
        // 槽 0 的字节被覆盖成 A 的内容（不再是内置曲）
        assertEquals(3, board.counts[0])
    }

    @Test
    fun `同步报告能描述结果`() {
        val lib = libWith(listOf("A" to "C4 D4 E4", "B" to "G4 A4"))
        val (s, _, _) = newSession(lib)
        val text = s.sync().describe()
        // 槽 0 受保护、槽 1 下发
        assertTrue("实际：$text", text.contains("下发 2 首"))
        assertTrue("实际：$text", text.contains("A"))
        assertTrue("实际：$text", text.contains("B"))
    }

    @Test
    fun `槽未就绪时板子回 result3 与长度错同码`() {
        // 这正是文档强调的多义性：result=3 既可能是长度错，也可能是「未就绪」。
        // App 必须先 QUERY 预检，不能等到 PLAY 被拒再猜原因。
        //
        // 这里直接观察板子的即时回帧：sendFrame 会因 result!=0 重试到上限，
        // 所以只看板子记下的日志，不看 session 的最终异常。
        val (s, board, _) = newSession()
        try {
            s.play(3)
        } catch (_: SessionError) {
            // 预期：重试到上限后抛
        }
        assertTrue(
            "板子应对 PLAY 未就绪槽回 result=3",
            board.log.any { it == "ACK cmd=$CMD_PLAY result=$RES_LEN" }
        )
        assertFalse(board.ready[3])
    }

    // -----------------------------------------------------------------------
    // 录音（只回传音符事件）
    // -----------------------------------------------------------------------

    @Test
    fun `录音开始 停止 与信息查询`() {
        val (s, board, _) = newSession()
        s.recStart()
        assertTrue(board.recBusy)
        // v2：模拟录了 3 个事件（每个 4 字节 {LO,MID,HI,DUR}）
        val evs = listOf(
            ChordEvent.single(0, 8),                  // C4
            ChordEvent.single(4, 8),                  // E4
            ChordEvent.of(listOf(7, 9), 16),          // G4+A4 和弦
        )
        evs.forEachIndexed { i, e -> e.toBytes().copyInto(board.recArea, i * 4) }
        board.recBytes = evs.size * 4
        s.recStop()
        val info = s.recInfo()
        assertFalse(info.busy)
        assertTrue(info.ready)
        assertEquals(12, info.bytes)
        assertEquals(3, info.events)              // v2：字节数 ÷ 4
    }

    @Test
    fun `回读录音能还原和弦事件`() {
        val (s, board, _) = newSession()
        s.recStart()
        val evs = listOf(
            ChordEvent.of(listOf(0, 4, 7), 16),       // C4+E4+G4
            ChordEvent.rest(4),                       // 休止
            ChordEvent.single(23, 8),                 // B5
        )
        evs.forEachIndexed { i, e -> e.toBytes().copyInto(board.recArea, i * 4) }
        board.recBytes = evs.size * 4
        s.recStop()
        assertEquals(evs, s.recReadNotes(evs.size * 4))
    }

    @Test
    fun `重复 REC_START 被拒`() {
        val (s, _, _) = newSession()
        s.recStart()
        try {
            s.recStart()
            fail("已在录音时 REC_START 应被拒")
        } catch (e: SessionError) {
            assertTrue("实际：${e.message}", e.message!!.contains("板子拒绝"))
        }
    }

    @Test
    fun `未录音时 REC_STOP 被拒`() {
        val (s, _, _) = newSession()
        try {
            s.recStop()
            fail("没在录音时 REC_STOP 应被拒")
        } catch (e: SessionError) {
            assertTrue("实际：${e.message}", e.message!!.contains("板子拒绝"))
        }
    }

    @Test
    fun `回读录音音符事件 不涉及音频`() {
        val (s, board, _) = newSession()
        s.recStart()
        // v2：4 字节/事件
        val events = listOf(
            ChordEvent.single(0, 8), ChordEvent.single(4, 8),
            ChordEvent.of(listOf(0, 4), 16), ChordEvent.rest(4),
        )
        events.forEachIndexed { i, e -> e.toBytes().copyInto(board.recArea, i * 4) }
        board.recBytes = events.size * 4
        s.recStop()

        assertEquals(events, s.recReadNotes(events.size * 4))
    }

    @Test
    fun `录音提交到曲谱槽后可播放`() {
        val (s, board, _) = newSession()
        s.recStart()
        // v2：录 2 个事件（第 2 个是和弦）
        val evs = listOf(ChordEvent.single(0, 8), ChordEvent.of(listOf(2, 6), 8))
        evs.forEachIndexed { i, e -> e.toBytes().copyInto(board.recArea, i * 4) }
        board.recBytes = evs.size * 4
        s.recStop()

        s.recCommit(1)
        assertTrue(board.ready[1])
        assertEquals(2, board.counts[1])
        // 提交后应能播放
        s.play(1)
        assertTrue(board.log.any { it.contains("PLAY song=1") })
    }

    @Test
    fun `未录音内容时 REC_COMMIT 被拒`() {
        val (s, _, _) = newSession()
        try {
            s.recCommit(1)
            fail("录音区为空时 COMMIT 应被拒")
        } catch (e: SessionError) {
            assertTrue("实际：${e.message}", e.message!!.contains("板子拒绝"))
        }
    }

    @Test
    fun `COMMIT 会截断到 512 字节`() {
        val (s, board, _) = newSession()
        s.recStart()
        // v2：造 150 个事件 = 600 字节，超过一个槽的 512
        for (i in 0 until 150) {
            ChordEvent.single(i % 24, 8).toBytes().copyInto(board.recArea, i * 4)
        }
        board.recBytes = 600
        s.recStop()
        s.recCommit(2)
        // RTL 截断到 512 字节 ⇒ v2 是 128 个事件（v1 曾是 256 音符）
        assertEquals(128, board.counts[2])
    }

    @Test
    fun `回读整片录音区会分多次读取`() {
        val (s, board, _) = newSession()
        s.recStart()
        // 20 个事件 = 80 字节
        for (i in 0 until 20) {
            ChordEvent.single(i % 24, 8).toBytes().copyInto(board.recArea, i * 4)
        }
        board.recBytes = 80
        s.recStop()

        val read = s.recReadNotes(80)
        // v2：80 字节 / 4 = 20 个事件（v1 时是 40 个音符）
        assertEquals(20, read.size)
        // 80 字节 / 每包 16 = 5 次读取
        val reads = board.receivedFrames.count { (it[2].toInt() and 0xFF) == CMD_REC_READ }
        assertEquals(5, reads)
    }

    // -----------------------------------------------------------------------
    // 重试与坏帧
    // -----------------------------------------------------------------------

    @Test
    fun `丢一帧会自动重发`() {
        val lib = libWith(listOf("A" to "C4 D4 E4"))
        val board = FakeBoard()
        val tp = object : Transport {
            private var out = ByteArray(0)
            var dropped = false
            override fun write(data: ByteArray) {
                // 第一次 DATA 丢掉（不回帧），靠重试补上
                if (!dropped && (data[2].toInt() and 0xFF) == CMD_DATA) {
                    dropped = true
                    return
                }
                out += board.feed(data)
            }

            override fun read(): ByteArray {
                val a = out; out = ByteArray(0); return a
            }
        }
        var clock = 0.0
        val s = Session(tp, lib, ackTimeout = 0.2, maxRetries = 3,
            sleep = { clock += it }, now = { clock })
        s.uploadSong(1, lib.get("A"))
        assertTrue(board.ready[1])
        assertTrue("应有重试", s.retries >= 1)
    }

    @Test
    fun `超过重试上限抛异常`() {
        val lib = libWith(listOf("A" to "C4 D4 E4"))
        val tp = object : Transport {
            override fun write(data: ByteArray) { /* 全吞，永不回帧 */ }
            override fun read(): ByteArray = ByteArray(0)
        }
        var clock = 0.0
        val s = Session(tp, lib, ackTimeout = 0.1, maxRetries = 2,
            sleep = { clock += it }, now = { clock })
        try {
            s.uploadSong(1, lib.get("A"))
            fail("应该抛 SessionError")
        } catch (e: SessionError) {
            assertTrue(e.message!!.contains("重试"))
        }
    }

    @Test
    fun `回帧被拆成多段仍能解析`() {
        // 通过一个会在每次 read 时只吐 1 字节的 Transport 模拟 BLE 分片
        val lib = libWith(listOf("A" to "C4 D4"))
        val board = FakeBoard()
        val queue = ArrayDeque<Byte>()
        val tp = object : Transport {
            override fun write(data: ByteArray) {
                board.feed(data).forEach { queue.add(it) }
            }

            override fun read(): ByteArray {
                if (queue.isEmpty()) return ByteArray(0)
                return byteArrayOf(queue.removeFirst())
            }
        }
        var clock = 0.0
        val s = Session(tp, lib, ackTimeout = 2.0, maxRetries = 2,
            sleep = { clock += it }, now = { clock })
        s.uploadSong(1, lib.get("A"))
        assertTrue(board.ready[1])
    }

    @Test
    fun `playFromLibrary 找不到曲单槽时报错`() {
        val lib = Library()
        lib.add("孤儿曲", parseMelody("C4 D4"))     // 没进曲单
        val (s, _, _) = newSession(lib)
        try {
            s.playFromLibrary("孤儿曲")
            fail("不在曲单里应该报错")
        } catch (e: SessionError) {
            assertTrue(e.message!!.contains("不在当前曲单"))
        }
    }

    @Test
    fun `parseNotes 跳过空白并兜底时值 0`() {
        // 录音区尾部没写过的格子是全 0，必须跳过
        val blob = byteArrayOf(0, 8, 4, 8, 0, 0, 0, 0)
        val notes = parseNotes(blob)
        assertEquals(2, notes.size)
        assertEquals(Note(0, 8), notes[0])
        assertEquals(Note(4, 8), notes[1])
    }

    @Test
    fun `parseNotes 忽略非法键位但保留合法音符`() {
        // 键位 200 非法（超 23 且不是休止符），应跳过而不是崩
        val blob = byteArrayOf(0, 8, 200.toByte(), 8, 7, 8)
        val notes = parseNotes(blob)
        assertEquals(2, notes.size)
        assertEquals(Note(0, 8), notes[0])
        assertEquals(Note(7, 8), notes[1])
    }
}
