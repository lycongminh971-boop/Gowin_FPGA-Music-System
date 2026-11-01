package com.epiano.ble.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * 协议层单测。
 *
 * ★ 本文件里所有「期望 hex」都**不是手抄的**，而是从 `art1/app_protocol/protocol.py`
 *   （独立实现，用 `binascii.crc_hqx`）跑出来的实测值，再粘到这里当回归基线。
 *   手抄 hex 一旦和代码不一致，就变成「文档说能发、板子拒收」那种最难查的问题。
 *
 * 移植自 Python 侧同名判据；RTL 对齐部分见 RtlAlignmentTest。
 */
class ProtocolTest {

    // -----------------------------------------------------------------------
    // CRC16 / CCITT-FALSE
    // -----------------------------------------------------------------------

    @Test
    fun `CRC 已知向量 123456789 = 0x29B1`() {
        // 这是协议文档写死的判据。若算出 0x89F6 说明用的是 2026-10-22 的旧 LSB 口径。
        val v = crc16("123456789".toByteArray(Charsets.US_ASCII))
        assertEquals(0x29B1, v)
    }

    @Test
    fun `表驱动与逐位实现逐位一致`() {
        // 两种独立写法对拍。逐位版是 bt_link.v 里 rc_byte 状态机的直译。
        val samples = listOf(
            ByteArray(0),
            byteArrayOf(0x00),
            byteArrayOf(0xFF.toByte()),
            "123456789".toByteArray(Charsets.US_ASCII),
            ByteArray(256) { it.toByte() },
            byteArrayOf(0x02, 0x01, 0x00, 0x07),
        )
        for (s in samples) {
            assertEquals(
                "样本 ${hex(s)} 两种实现不一致",
                crc16Bitwise(s), crc16(s),
            )
        }
    }

    // -----------------------------------------------------------------------
    // 发送侧：与 Python 参考实现逐字节一致
    // -----------------------------------------------------------------------

    @Test
    fun `QUERY 帧与文档一致`() {
        // 文档里最快的心跳自检帧。一发出去就该回 5A 05 82 ... 共 10 字节。
        assertEquals("A5 00 06 C9 7D", hex(buildQuery()))
    }

    @Test
    fun `STOP 帧与文档一致`() {
        assertEquals("A5 00 05 AA 4D", hex(buildStop()))
    }

    @Test
    fun `BEGIN 帧与文档一致`() {
        // 小星星：槽 0，7 个音符
        assertEquals("A5 02 01 00 07 7F 2E", hex(buildBegin(0, 7)))
    }

    @Test
    fun `END 帧与文档一致`() {
        assertEquals("A5 01 03 00 FF AE", hex(buildEnd(0)))
    }

    @Test
    fun `PLAY 帧与文档一致`() {
        assertEquals("A5 01 04 00 68 37", hex(buildPlay(0)))
    }

    @Test
    fun `MODE 帧与 Python 参考一致`() {
        assertEquals("A5 02 07 02 01 7B 9A", hex(buildMode(MODE_AUTO, 1)))
    }

    @Test
    fun `SET 变调用偏置编码`() {
        // buildSetBend(0) ⇒ 偏置 12 = 0x0C
        assertEquals("A5 02 08 01 0C B4 32", hex(buildSetBend(0)))
        // +12 半音 ⇒ 24 = 0x18
        assertEquals("A5 02 08 01 18 01 60", hex(buildSetBend(12)))
        // -12 半音 ⇒ 0 = 0x00
        assertEquals("A5 02 08 01 00 38 F3", hex(buildSetBend(-12)))
    }

    @Test
    fun `SET 音色 颤音 延时与 Python 参考一致`() {
        assertEquals("A5 02 08 00 02 4B E0", hex(buildSet(SET_TONE, 2)))
        assertEquals("A5 02 08 02 03 08 96", hex(buildSet(SET_VIB, 3)))
        assertEquals("A5 02 08 03 01 7B 85", hex(buildSet(SET_DELAY, 1)))
    }

    @Test
    fun `PARA 与 RECINFO 与 Python 参考一致`() {
        assertEquals("A5 00 09 26 8C", hex(buildPara()))
        assertEquals("A5 00 0E C1 FC", hex(buildRecInfo()))
    }

    @Test
    fun `录音命令与 Python 参考一致`() {
        assertEquals("A5 00 0A 45 BC", hex(buildRecStart()))
        assertEquals("A5 00 0B 64 AC", hex(buildRecStop()))
        assertEquals("A5 01 0C 01 E0 AE", hex(buildRecCommit(1)))
        assertEquals("A5 03 0D 00 00 10 69 D4", hex(buildRecRead(0, 16)))
    }

    @Test
    fun `文档 6_1 小星星 v2 分帧`() {
        // 依据 蓝牙下载与演奏指引协议.md §6.1（v2 四字节事件）
        // 7 个事件 × 4 字节 = 28 字节，一帧刚好发完（n=28 是 4 的倍数，LEN=30 ≤ 34）
        val keys = listOf(0, 0, 7, 7, 9, 9, 7)              // 键号
        val durs = listOf(8, 8, 8, 8, 8, 8, 16)
        val hidden = keys.mapIndexed { i, k -> ChordEvent.single(k, durs[i]) }

        // 单帧能装下全部（perFrame 设成上限 8 ⇒ 8×4=32 ≥ 28）
        val seq = buildDownloadSequence(Song(hidden), songId = 0, perFrame = 7)
        assertEquals(3, seq.size)                            // BEGIN + 1×DATA + END
        assertEquals("A5 02 01 00 07 7F 2E", hex(seq[0]))
        assertEquals(
            "A5 1E 02 00 1C 01 00 00 08 01 00 00 08 80 00 00 08 80 00 00 08 " +
                "00 02 00 08 00 02 00 08 80 00 00 10 D6 F4",
            hex(seq[1]),
        )
        assertEquals("A5 01 03 00 FF AE", hex(seq[2]))
    }

    @Test
    fun `文档 6_2 复音和弦帧`() {
        // §6.2：槽 1，事件 C4+E4+G4 (时值16) 然后 B4+D5 (时值8)
        val events = listOf(
            ChordEvent.of(listOf(0, 4, 7), 16),        // C4(b0)+E4(b4)+G4(b7) = 0x91
            ChordEvent.of(listOf(11, 14), 8),          // B4(b11)+D5(b14)     = 0x4800
        )
        val seq = buildDownloadSequence(Song(events), songId = 1, perFrame = 2)
        assertEquals("A5 02 01 01 02 EB 4D", hex(seq[0]))
        assertEquals("A5 0A 02 00 08 91 00 00 10 00 48 00 08 4F A6", hex(seq[1]))
        assertEquals("A5 01 03 01 DE BE", hex(seq[2]))
        assertEquals("A5 01 04 01 49 27", hex(buildPlay(1)))
    }

    @Test
    fun `和弦事件字节布局`() {
        // C4+E4+G4 = bit0|bit4|bit7 = 0x91
        assertEquals("91 00 00 10", hex(ChordEvent.of(listOf(0, 4, 7), 16).toBytes()))
        // B4+D5 = bit11|bit14 = 0x4800
        assertEquals("00 48 00 08", hex(ChordEvent.of(listOf(11, 14), 8).toBytes()))
        // 休止 = 三字节全 0
        assertEquals("00 00 00 08", hex(ChordEvent.rest(8).toBytes()))
        // 最高键 B5 = bit23 = 0x800000
        assertEquals("00 00 80 08", hex(ChordEvent.single(23, 8).toBytes()))
    }

    @Test
    fun `休止不再是 0x7F 而是全零掩码`() {
        // v2 消掉了 v1 的魔法值：休止就是「没有键按下」
        val r = ChordEvent.rest(8)
        assertTrue(r.isRest)
        assertEquals(0, r.size)
        assertEquals("-", r.name)
        // v1 的 Note(0x7F) 升级后同样变成 keys=0
        assertEquals(0, Note(REST, 8).toChordEvent().keys)
    }

    @Test
    fun `事件名与键位列表`() {
        assertEquals("C4+E4+G4", ChordEvent.of(listOf(0, 4, 7), 8).name)
        assertEquals(listOf(0, 4, 7), ChordEvent.of(listOf(0, 4, 7), 8).keyList)
        assertEquals(3, ChordEvent.of(listOf(0, 4, 7), 8).size)
        assertEquals("C4", ChordEvent.single(0, 8).name)
    }

    @Test
    fun `字节流与事件互转往返一致`() {
        val events = listOf(
            ChordEvent.of(listOf(0, 4, 7), 16),
            ChordEvent.rest(4),
            ChordEvent.single(23, 8),
            ChordEvent.of(listOf(1, 2, 3, 4), 2),
        )
        val blob = eventsToBytes(events)
        assertEquals(events.size * 4, blob.size)
        assertEquals(events, bytesToEvents(blob))
    }

    @Test
    fun `和弦音名解析支持加号`() {
        assertEquals(0x91, namesToKeyMask("C4+E4+G4"))
        assertEquals(0x4800, namesToKeyMask("B4+D5"))
        assertEquals(0, namesToKeyMask("-"))
        assertEquals(0, namesToKeyMask(""))
        assertEquals("C4+E4+G4", keyMaskToNames(0x91))
        // 和弦里不能混休止
        try {
            namesToKeyMask("C4+-")
            fail("和弦里混休止应该被拒")
        } catch (_: ProtocolError) {
        }
    }

    // -----------------------------------------------------------------------
    // 发送侧：拒绝路径（RTL 会拒的，这里必须在构造期就拦住）
    // -----------------------------------------------------------------------

    @Test
    fun `payload 超过 34 必须拒绝`() {
        // RTL: pbuf[0:39]，`if(rx_data>34) → P_HUNT`，连 ACK 都不回
        try {
            buildFrame(CMD_DATA, ByteArray(35))
            fail("应该拒绝 35 字节 payload")
        } catch (e: ProtocolError) {
            assertTrue(e.message!!.contains("过长"))
        }
        // 34 是允许的边界
        buildFrame(CMD_DATA, ByteArray(34))
    }

    @Test
    fun `BEGIN 的 count 必须是 1到127 且 song 是 0到3`() {
        // v2：RTL bt_link.v:264 的 `pbuf[1]==0 || pbuf[1]>127` 即拒
        assertEquals("A5 02 01 00 7F E0 D1", hex(buildBegin(0, 127)))
        for (bad in listOf(0, 128, 255)) {
            try {
                buildBegin(0, bad)
                fail("count=$bad 应该被拒")
            } catch (_: IllegalArgumentException) {
            }
        }
        try {
            buildBegin(4, 1)
            fail("song=4 应该被拒")
        } catch (_: IllegalArgumentException) {
        }
    }

    @Test
    fun `DATA 的 n 必须是 4 的倍数且 4到32`() {
        // v2：RTL bt_link.v:284 — `plen<4 || pbuf[1]<4 || pbuf[1]>32 || |pbuf[1][1:0] || plen!=pbuf[1]+2`
        buildData(0, ByteArray(32))     // 上界可过
        buildData(0, ByteArray(4))      // 下界可过
        buildData(0, ByteArray(8))
        // 非 4 倍数必须被拒 —— v1 时偶数就行（2/6/10…），v2 不行
        for (bad in listOf(0, 1, 2, 3, 6, 10, 33, 34)) {
            try {
                buildData(0, ByteArray(bad))
                fail("n=$bad 应该被拒")
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    @Test
    fun `v2 的 2 字节偶数长度不再合法`() {
        // v1→v2 最容易漏的回归点：v1 的合法 DATA 长度在 v2 大多非法。
        // 注意 12 同时是 4 的倍数，在 v2 下**仍然合法**（= 3 个事件），
        // 所以只列真正的「偶数但不是 4 的倍数」与 <4 的值。
        for (v1Len in listOf(2, 6, 10, 14, 18, 22, 26, 30)) {
            try {
                buildData(0, ByteArray(v1Len))
                fail("v1 长度 $v1Len 在 v2 应被拒（不是 4 的倍数）")
            } catch (_: IllegalArgumentException) {
                // 期望
            }
        }
        // 12 是 v1 的 6 个音符，也是 v2 的 3 个事件 —— 两者都合法
        buildData(0, ByteArray(12))
    }

    @Test
    fun `SET 各参数的范围校验按 RTL`() {
        // RTL: (param==0 && v>3) || (param==1 && v>24) || (param==2 && v>3) || (param==3 && v>1)
        buildSet(SET_TONE, 3); buildSet(SET_BEND, 24); buildSet(SET_VIB, 3); buildSet(SET_DELAY, 1)
        for ((p, v) in listOf(SET_TONE to 4, SET_BEND to 25, SET_VIB to 4, SET_DELAY to 2)) {
            try {
                buildSet(p, v)
                fail("param=$p value=$v 应该被拒")
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    @Test
    fun `REC_READ 越界必须拒绝`() {
        // RTL: addr+n > 2048 → result 3（防 11 位地址回绕读到队首垃圾）
        buildRecRead(2048 - 16, 16)     // 恰好贴边，可过
        try {
            buildRecRead(2048 - 16, 17)
            fail("越界应该被拒")
        } catch (_: IllegalArgumentException) {
        }
        for (bad in listOf(0, 17)) {
            try {
                buildRecRead(0, bad)
                fail("n=$bad 应该被拒")
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    @Test
    fun `和弦事件校验 时值 0 非法 掩码越界非法`() {
        // v2：RTL A_VALIDATE 只检查每组第 4 字节（时值）1..127，
        //     前 3 字节键位掩码**任意值都合法**（24 位全用满）。
        ChordEvent(0, 1); ChordEvent(0xFFFFFF, 127); ChordEvent.rest(1)
        for ((k, d) in listOf(0x1000000 to 8, -1 to 8, 0 to 0, 0 to 128)) {
            try {
                ChordEvent(k, d)
                fail("ChordEvent($k, $d) 应该被拒")
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    @Test
    fun `v1 音符仍可构造并升级为事件`() {
        // 保留 v1 Note 是为了读旧曲库；它必须能无损升级
        assertEquals(1, Note(0, 8).toChordEvent().keys)
        assertEquals(8, Note(0, 8).toChordEvent().dur)
        assertEquals(0, Note(REST, 4).toChordEvent().keys)      // 休止 → keys=0
        Note(23, 127); Note(REST, 1)
        for ((k, d) in listOf(24 to 8, 127 to 0, 0 to 0, 0 to 128, -1 to 8)) {
            try {
                Note(k, d)
                fail("Note($k, $d) 应该被拒")
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    // -----------------------------------------------------------------------
    // 接收侧：回帧解析
    // -----------------------------------------------------------------------

    /** 造一条板 → 手机的合法回帧。 */
    private fun reply(cmd: Int, payload: ByteArray): ByteArray {
        val body = byteArrayOf(payload.size.toByte(), cmd.toByte()) + payload
        val c = crc16(body)
        return byteArrayOf(SOF_OUT.toByte()) + body +
            byteArrayOf((c and 0xFF).toByte(), ((c shr 8) and 0xFF).toByte())
    }

    @Test
    fun `解析 ACK`() {
        val r = parseReply(reply(R_ACK, byteArrayOf(CMD_QUERY.toByte(), RES_OK.toByte()))) as Ack
        assertEquals(CMD_QUERY, r.cmd)
        assertEquals(RES_OK, r.result)
        assertTrue(r.ok)
    }

    @Test
    fun `解析 STATUS 并正确拆 ready_mask`() {
        // state=2 READY, song=1, done=12, ready=0b0011
        val p = byteArrayOf(2, 1, 12, 0, 0b0011)
        val s = parseReply(reply(R_STATUS, p)) as Status
        assertEquals(2, s.state)
        assertEquals(1, s.song)
        assertEquals(12, s.done)
        assertTrue(s.ready(0)); assertTrue(s.ready(1))
        assertFalse(s.ready(2)); assertFalse(s.ready(3))
    }

    @Test
    fun `解析 STATUS 的 done 是 16 位小端`() {
        // done_lo=0x00, done_hi=0x02 ⇒ 512
        val s = parseReply(reply(R_STATUS, byteArrayOf(1, 0, 0x00, 0x02, 0x01))) as Status
        assertEquals(512, s.done)
    }

    @Test
    fun `解析 PARAM 时变调要减去偏置`() {
        val p = parseReply(reply(R_PARAM, byteArrayOf(1, 12, 2, 1))) as Param
        assertEquals(1, p.tone)
        assertEquals(12, p.bend)
        assertEquals(0, p.bendSemitones)     // 偏置 12 ⇒ 真实 0 半音
        assertEquals(2, p.vib)
        assertEquals(1, p.delay)

        val low = parseReply(reply(R_PARAM, byteArrayOf(0, 0, 0, 0))) as Param
        assertEquals(-12, low.bendSemitones)
    }

    @Test
    fun `解析 RECINFO 时三位状态要逐位读`() {
        // busy=0, ready=1, full=1 这个组合是真实可能的：
        // recorder.v 里 rec_full 只有复位或下一次 REC_START 才清。
        val i = parseReply(reply(R_RECINFO, byteArrayOf(0b110, 0x20, 0x00))) as RecInfo
        assertFalse(i.busy)
        assertTrue(i.ready)
        assertTrue(i.full)
        assertEquals(32, i.bytes)
        // v2：32 字节 = 8 个事件（v1 时 = 16 个音符）
        assertEquals(8, i.events)
        assertEquals(8, i.notes)   // 兼容名，同样返回事件数
    }

    @Test
    fun `解析 RECDATA`() {
        val payload = byteArrayOf(0x10, 0x00, 2, 0x05, 0x08)
        val d = parseReply(reply(R_DATA, payload)) as RecData
        assertEquals(16, d.addr)
        assertTrue(d.data.contentEquals(byteArrayOf(0x05, 0x08)))
    }

    @Test
    fun `回帧 CRC 错必须抛异常`() {
        val good = reply(R_ACK, byteArrayOf(CMD_QUERY.toByte(), RES_OK.toByte()))
        val bad = good.copyOf()
        bad[bad.size - 2] = (bad[bad.size - 2] + 1).toByte()
        try {
            parseReply(bad)
            fail("CRC 错应该抛")
        } catch (e: ProtocolError) {
            assertTrue(e.message!!.contains("CRC"))
        }
    }

    @Test
    fun `回帧 SOF 错必须抛异常`() {
        val bad = reply(R_ACK, byteArrayOf(1, 0)).copyOf()
        bad[0] = 0xA5.toByte()
        try {
            parseReply(bad)
            fail("SOF 错应该抛")
        } catch (e: ProtocolError) {
            assertTrue(e.message!!.contains("SOF"))
        }
    }

    @Test
    fun `未知回帧 CMD 必须抛异常`() {
        try {
            parseReply(reply(0x99, byteArrayOf(1, 2)))
            fail("未知 CMD 应该抛")
        } catch (e: ProtocolError) {
            assertTrue(e.message!!.contains("未知"))
        }
    }

    @Test
    fun `ACK 的 LEN 不是 2 要抛`() {
        try {
            parseReply(reply(R_ACK, byteArrayOf(1)))
            fail("LEN=1 的 ACK 应该抛")
        } catch (e: ProtocolError) {
            assertTrue(e.message!!.contains("LEN"))
        }
    }

    // -----------------------------------------------------------------------
    // FrameSplitter：分片与粘包
    // -----------------------------------------------------------------------

    @Test
    fun `STATUS 被拆成三段仍能拼回`() {
        // BLE 实测会把 10 字节 STATUS 拆开。这是必须容忍的第一类情况。
        val frame = reply(R_STATUS, byteArrayOf(2, 1, 12, 0, 0b0011))
        val sp = FrameSplitter()
        assertTrue(sp.feed(frame.copyOfRange(0, 3)).isEmpty())
        assertTrue(sp.feed(frame.copyOfRange(3, 7)).isEmpty())
        val out = sp.feed(frame.copyOfRange(7, frame.size))
        assertEquals(1, out.size)
        assertEquals(12, (out[0] as Status).done)
    }

    @Test
    fun `两条 ACK 粘在一起能拆出两条`() {
        val a = reply(R_ACK, byteArrayOf(CMD_BEGIN.toByte(), RES_OK.toByte()))
        val b = reply(R_ACK, byteArrayOf(CMD_DATA.toByte(), RES_OK.toByte()))
        val out = FrameSplitter().feed(a + b)
        assertEquals(2, out.size)
        assertEquals(CMD_BEGIN, (out[0] as Ack).cmd)
        assertEquals(CMD_DATA, (out[1] as Ack).cmd)
    }

    @Test
    fun `前置垃圾字节会被跳过`() {
        val a = reply(R_ACK, byteArrayOf(CMD_END.toByte(), RES_OK.toByte()))
        val out = FrameSplitter().feed(byteArrayOf(0x00, 0x11, 0x22) + a)
        assertEquals(1, out.size)
        assertEquals(CMD_END, (out[0] as Ack).cmd)
    }

    @Test
    fun `坏帧被丢弃且不中断后续解析`() {
        // 真机上抛异常等于「一条噪声把整个会话打断」，所以这里是丢帧不抛。
        val bad = reply(R_ACK, byteArrayOf(1, 0)).copyOf().also { it[it.size - 2] = 0x00 }
        val good = reply(R_ACK, byteArrayOf(CMD_PLAY.toByte(), RES_OK.toByte()))
        val sp = FrameSplitter()
        val out = sp.feed(bad + good)
        assertEquals(1, out.size)
        assertEquals(CMD_PLAY, (out[0] as Ack).cmd)
        assertTrue(sp.badFrames >= 1)
    }

    @Test
    fun `strict 模式下坏帧抛异常`() {
        val bad = reply(R_ACK, byteArrayOf(1, 0)).copyOf().also { it[it.size - 2] = 0x00 }
        try {
            FrameSplitter(strict = true).feed(bad)
            fail("strict 应该抛")
        } catch (_: ProtocolError) {
        }
    }

    @Test
    fun `reset 清空残留`() {
        val frame = reply(R_ACK, byteArrayOf(1, 0))
        val sp = FrameSplitter()
        sp.feed(frame.copyOfRange(0, 3))
        sp.reset()
        // 重置后再喂整条，应该完整解析出来
        assertEquals(1, sp.feed(frame).size)
    }

    // -----------------------------------------------------------------------
    // 屏幕字符串：与 rgb_scope.v 的 btcode 表逐字符对齐
    // -----------------------------------------------------------------------

    @Test
    fun `屏幕字符串复刻 btcode 表`() {
        val ready1 = Status(state = ST_IDLE, song = 0, done = 0, readyMask = 0b0001)

        // 就绪：RDY n/4
        assertEquals("RDY 1/4  ", btDisplayString(ready1))
        // 没货：NO DATA 与 --  n/4 是同一状态的两个闪烁相位
        val noStock = Status(state = ST_IDLE, song = 0, done = 0, readyMask = 0)
        assertEquals("--  1/4  ", btDisplayString(noStock, blink = true))
        assertEquals("NO DATA  ", btDisplayString(noStock, blink = false))

        // 下载中
        assertEquals("RX012/128", btDisplayString(Status(ST_RXING, 0, 12, 0), total = 128))
        // 错误
        assertEquals("RX ERROR ", btDisplayString(Status(ST_ERROR, 0, 0, 0)))
        // GUIDE / AUTO
        assertEquals("G012/048 ", btDisplayString(noStock, guideBusy = true, total = 48, idx = 12))
        assertEquals("A012/048 ", btDisplayString(noStock, guideBusy = true, auto = true, total = 48, idx = 12))
        // 录音三态，且优先级最高（压过就绪与播放）
        assertEquals("REC021   ", btDisplayString(ready1, recBusy = true, recBytes = 42))
        assertEquals("REC FULL ", btDisplayString(ready1, recBusy = true, recFull = true, recBytes = 2048))
        assertEquals("REC RDY  ", btDisplayString(ready1, recReady = true))
    }

    @Test
    fun `屏幕字符串恒为 9 字符`() {
        // rgb_scope 的字段宽度是固定的；长度错了整个版面会串位。
        val cases = listOf(
            btDisplayString(Status(0, 0, 0, 1)),
            btDisplayString(Status(0, 0, 0, 0), blink = false),
            btDisplayString(Status(1, 0, 5, 0), total = 100),
            btDisplayString(Status(3, 0, 0, 0)),
            btDisplayString(Status(0, 0, 0, 0), guideBusy = true, total = 999, idx = 999),
            btDisplayString(Status(0, 0, 0, 0), recBusy = true, recBytes = 1998),
            btDisplayString(Status(0, 0, 0, 0), recReady = true),
        )
        for (s in cases) assertEquals("「$s」长度应为 9", 9, s.length)
    }

    @Test
    fun `录音计数封顶 999`() {
        // RTL: if(rnv>999) rnv=999
        assertEquals("REC999   ", btDisplayString(Status(0, 0, 0, 0), recBusy = true, recBytes = 4096))
    }

    // -----------------------------------------------------------------------
    // 音名与键位
    // -----------------------------------------------------------------------

    @Test
    fun `键位表是 C4 到 B5`() {
        assertEquals(24, KEY_NAMES.size)
        assertEquals("C4", KEY_NAMES[0])
        assertEquals("B4", KEY_NAMES[11])
        assertEquals("C5", KEY_NAMES[12])
        assertEquals("B5", KEY_NAMES[23])
    }

    @Test
    fun `音名解析往返一致`() {
        for (k in 0..23) assertEquals(k, nameToKey(KEY_NAMES[k]))
        assertEquals(REST, nameToKey("-"))
        // 大小写不敏感
        assertEquals(0, nameToKey("c4"))
        assertEquals(1, nameToKey("C#4"))
    }

    @Test
    fun `MIDI 到键位是减 60`() {
        assertEquals(0, midiToKey(60))       // C4
        assertEquals(23, midiToKey(83))      // B5
        assertEquals(9, midiToKey(69))       // A4 = 440Hz
        try {
            midiToKey(59); fail("59 应该被拒")
        } catch (_: IllegalArgumentException) {
        }
        try {
            midiToKey(84); fail("84 应该被拒")
        } catch (_: IllegalArgumentException) {
        }
    }

    @Test
    fun `曲长上限 127 事件`() {
        // v2：512 B ÷ 4 B = 128，但 RTL 把 count 卡在 127
        Song(List(MAX_EVENTS) { ChordEvent.single(0, 8) })
        try {
            Song(List(MAX_EVENTS + 1) { ChordEvent.single(0, 8) })
            fail("${MAX_EVENTS + 1} 事件应该被拒")
        } catch (_: IllegalArgumentException) {
        }
        try {
            Song(emptyList())
            fail("空曲应该被拒")
        } catch (_: IllegalArgumentException) {
        }
    }

    @Test
    fun `v1 的 255 音符曲子在 v2 容量下装不下`() {
        // 这是容量腰斩的直接体现：v1 能装 255 音，v2 只能 127 事件
        val manyEvents = List(200) { ChordEvent.single(it % 24, 8) }
        try {
            Song(manyEvents)
            fail("200 事件超过 v2 上限，应被拒")
        } catch (_: IllegalArgumentException) {
        }
    }

    @Test
    fun `每帧最多 8 个事件`() {
        assertEquals(8, MAX_EVENTS_PER_FRAME)
        // perFrame 超过 8 应被拒
        val song = Song(List(20) { ChordEvent.single(0, 8) })
        try {
            buildDownloadSequence(song, songId = 0, perFrame = 9)
            fail("perFrame=9 应被拒")
        } catch (_: IllegalArgumentException) {
        }
        // 8 可以，且 20 个事件应分成 3 帧（8+8+4）
        val frames = buildDownloadSequence(song, songId = 0, perFrame = 8)
        assertEquals(3 + 2, frames.size)   // BEGIN + 3×DATA + END
    }
}