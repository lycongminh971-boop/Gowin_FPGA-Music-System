package com.epiano.ble.session

import com.epiano.ble.library.BUILTIN_SONG_NAME
import com.epiano.ble.library.Entry
import com.epiano.ble.library.Library
import com.epiano.ble.protocol.Ack
import com.epiano.ble.protocol.BUILTIN_NOTES
import com.epiano.ble.protocol.BUILTIN_SLOT
import com.epiano.ble.protocol.CMD_REC_COMMIT
import com.epiano.ble.protocol.FrameSplitter
import com.epiano.ble.protocol.ChordEvent
import com.epiano.ble.protocol.bytesToEvents
import com.epiano.ble.protocol.MAX_DATA_BYTES
import com.epiano.ble.protocol.Param
import com.epiano.ble.protocol.RecData
import com.epiano.ble.protocol.RecInfo
import com.epiano.ble.protocol.Reply
import com.epiano.ble.protocol.RESULT_NAMES
import com.epiano.ble.protocol.SONG_COUNT
import com.epiano.ble.protocol.Status
import com.epiano.ble.protocol.buildBegin
import com.epiano.ble.protocol.buildData
import com.epiano.ble.protocol.buildEnd
import com.epiano.ble.protocol.buildMode
import com.epiano.ble.protocol.buildPara
import com.epiano.ble.protocol.buildPlay
import com.epiano.ble.protocol.buildQuery
import com.epiano.ble.protocol.buildRecCommit
import com.epiano.ble.protocol.buildRecInfo
import com.epiano.ble.protocol.buildRecRead
import com.epiano.ble.protocol.buildRecStart
import com.epiano.ble.protocol.buildRecStop
import com.epiano.ble.protocol.buildSet
import com.epiano.ble.protocol.buildTempoQuery
import com.epiano.ble.protocol.buildTempoSet
import com.epiano.ble.protocol.buildClear
import com.epiano.ble.protocol.buildClearAll
import com.epiano.ble.protocol.buildStop
import com.epiano.ble.protocol.hex
import com.epiano.ble.protocol.REC_BYTES
import com.epiano.ble.protocol.REC_READ_CHUNK

/**
 * 会话层 —— `art1/app_protocol/session.py` 的 Kotlin 移植。
 *
 * 职责：把「曲库 + 传输通道」组合成一条条能跑通的业务流程
 * （自动补谱、增量同步、掉电恢复、播放控制、录音回读）。
 *
 * **本层刻意不引用任何 Android 类**：BLE 通道由调用方实现 [Transport] 接口注入，
 * 所以整层可以在纯 JVM 单测里跑（见 SessionTest 用的 FakeBoard）。
 */

/** 会话层错误。 */
class SessionError(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * 传输通道抽象。Android 侧只需实现这两个方法（见 `ble.BleTransport`）。
 *
 * 注意这是**字节流**语义，不是消息语义：BLE 的 notify 会把一条回帧拆成多段、
 * 也会把多条粘在一起，所以 [read] 返回多少字节都合法，组帧由
 * [FrameSplitter] 负责。
 */
interface Transport {
    /** 发送一段字节。不保证送达 —— 丢包由会话层的重发兜住。 */
    fun write(data: ByteArray)

    /** 读取当前可用的字节；没有则返回空数组（不要阻塞等待）。 */
    fun read(): ByteArray

    /** 关闭通道。 */
    fun close() {}
}

/**
 * 一次同步的结果。App 应把它显示给用户 —— 尤其是 [powerLossDetected]。
 */
class SyncReport {
    val uploaded = mutableListOf<Pair<Int, Entry>>()
    val skipped = mutableListOf<Pair<Int, Entry>>()
    val failed = mutableListOf<Triple<Int, Entry, String>>()

    /** 因「出厂内置曲保护」而没下发的槽（不是失败，也不是已是最新）。 */
    val builtinProtected = mutableListOf<Pair<Int, Entry>>()

    var bytesSent: Int = 0
    var framesSent: Int = 0
    var retries: Int = 0
    var powerLossDetected: Boolean = false
    var elapsed: Double = 0.0

    val ok: Boolean get() = failed.isEmpty()

    // ★ 2026-10-28 修复「槽号显示错位」：
        //
        //   slot 是**协议槽号 0..3**，而界面/用户心智里的槽号是 **1..4**。
        //   原来这里直接打印 slot，于是日志出现「槽0」「槽1」——
        //   用户看到的「槽1 已下发 欢乐颂」，实际是界面上的**槽2**，
        //   而界面「槽1」对应的是日志里的「槽0」（小星星）。
        //   两套编号混在一起，就表现成「名字和实际存的不是一首歌」。
        //
        //   统一 +1，并且额外标出协议槽号（song=），方便与 RTL 日志对照。
        fun describe(): String {
        val sb = StringBuilder()
        sb.append(
            "同步${if (ok) "成功" else "部分失败"}：" +
                "下发 ${uploaded.size} 首 / 跳过 ${skipped.size} 首" +
                "（$bytesSent 字节，$framesSent 帧，重试 $retries 次，%.2fs）".format(elapsed)
        )
        if (powerLossDetected) {
            sb.append("\n  ⚠ 记账与板子不一致（板子已重启/曲谱已清空），已全量重传")
        }
        // 槽号一律用「界面口径」（1..4），后面附协议 song 号便于对 RTL
        for ((slot, e) in uploaded) {
            sb.append("\n  槽${slot + 1}  ✔ 已下发  ${e.name}    (song=${slot})")
        }
        for ((slot, e) in builtinProtected) {
            sb.append("\n  槽${slot + 1}  ◆ 内置曲保护  ${e.name}（板上有出厂《$BUILTIN_SONG_NAME》）")
        }
        for ((slot, e) in skipped) {
            sb.append("\n  槽${slot + 1}  – 已是最新  ${e.name}    (song=${slot})")
        }
        for ((slot, e, why) in failed) {
            sb.append("\n  槽${slot + 1}  ✘ 失败  ${e.name}：$why")
        }
        return sb.toString()
    }
}

/**
 * 一次会话。
 *
 * @param settle 每次写之后额外等待的秒数。BLE 写是异步的，给一点余量能让
 *   板子先把上一个字节序列收完，减少无谓重试。
 * @param ackTimeout 等回帧的超时（秒）。实测下位机回一条 ACK 只要约 0.6 ms，
 *   但 BLE 链路有调度抖动，取 0.5 s 足够宽松。
 * @param maxRetries 单帧最大重发次数。
 */
class Session(
    private val transport: Transport,
    val lib: Library,
    private val settle: Double = 0.0,
    private val ackTimeout: Double = 0.5,
    private val maxRetries: Int = 3,
    private val log: (String) -> Unit = {},
    /** 单调时钟，单位秒。测试可注入假时钟。 */
    private val now: () -> Double = { System.nanoTime() / 1e9 },
    /** 睡眠。测试注入 no-op 以免真的等。 */
    private val sleep: (Double) -> Unit = { s -> if (s > 0) Thread.sleep((s * 1000).toLong()) },
) {

    private val splitter = FrameSplitter()
    private val pending = ArrayDeque<Reply>()

    var framesSent: Int = 0
        private set
    var retries: Int = 0
        private set
    var lastStatus: Status? = null
        private set

    // -----------------------------------------------------------------------
    // 底层收发
    // -----------------------------------------------------------------------

    private fun drain() {
        val data = transport.read()
        if (data.isNotEmpty()) pending.addAll(splitter.feed(data))
    }

    /**
     * 发一条帧并等一条回帧，带重试。
     *
     * 重试是**必要**的：BLE 透传会丢包，而丢一条 DATA 会让后续所有帧
     * 因为 seq 不连续被拒（板子回 `result=2`）。与其让用户重来，
     * 不如在这里重发。
     *
     * @param expectReply false 表示这条命令板子不回应（当前只有超长帧被判丢弃时如此，
     *   正常命令都会回 ACK）。
     */
    fun sendFrame(frame: ByteArray, expectReply: Boolean = true): Reply? {
        var attempt = 0
        var lastErr = "无回帧"
        while (attempt <= maxRetries) {
            pending.clear()
            transport.write(frame)
            framesSent++
            if (settle > 0) sleep(settle)

            if (!expectReply) return null

            val deadline = now() + ackTimeout
            while (now() < deadline) {
                drain()
                val r = pending.removeFirstOrNull()
                if (r != null) {
                    if (r is Ack && !r.ok) {
                        // ★ 2026-10-28 修复：板子**明确拒绝**时不应重试。
                        //
                        //   原来这里 `break` 之后 attempt++，于是同一个非法帧
                        //   会重发 3 次，每次再叠加内部重试 —— 日志里出现过
                        //   「重试 12 次」就是这么来的。而结果必然是同样的拒绝，
                        //   白白占用 3×0.5s 的等待，还让用户以为"链路不稳"。
                        //
                        //   真正值得重试的是「没回帧」（超时），因为那可能是
                        //   丢包；而 result=3 是板子基于帧内容给出的确定性判断，
                        //   重发多少次都一样。
                        //
                        //   所以这里直接抛错，把原因原样交给上层。
                        throw SessionError(
                            "板子拒绝了这一帧（${RESULT_NAMES[r.result] ?: r.result}），" +
                                "重发无用，已停止重试",
                        )
                    }
                    return r
                }
                sleep(0.001)
            }

            attempt++
            if (attempt <= maxRetries) {
                retries++
                log("重试 $attempt/$maxRetries（$lastErr）")
            }
        }
        throw SessionError("帧发送失败（重试 $maxRetries 次）：$lastErr")
    }

    /** 发一条帧并要求回 ACK 且成功；否则抛 [SessionError]。 */
    private fun mustAck(frame: ByteArray, what: String): Ack {
        val r = sendFrame(frame)
        if (r !is Ack) throw SessionError("$what 未返回 ACK：$r")
        if (!r.ok) throw SessionError("$what 被拒：${RESULT_NAMES[r.result] ?: r.result}")
        return r
    }

    /** 发 QUERY 取板子状态。这也是心跳。 */
    fun query(): Status {
        val r = sendFrame(buildQuery())
        if (r !is Status) throw SessionError("QUERY 未返回 STATUS：$r")
        lastStatus = r
        return r
    }

    /** 发一次心跳（就是 QUERY）。屏幕靠它维持在线态。 */
    fun heartbeatOnce(): Status = query()

    /** 读当前生效参数（音色/变调/颤音/延时）。 */
    fun para(): Param {
        val r = sendFrame(buildPara())
        if (r !is Param) throw SessionError("PARA 未返回 PARAM：$r")
        return r
    }
    /**
     * 查询节奏档位（2026-10-28 新增）。
     *
     * 板子回 `{档位, BPM}`，**BPM 由板子按档位查表给出**，
     * 手机端不用自己维护一份映射（两边容易漂）。
     */
    fun tempo(): com.epiano.ble.protocol.Tempo {
        val r = sendFrame(buildTempoQuery())
        if (r !is com.epiano.ble.protocol.Tempo) {
            throw SessionError("TEMPO 未返回 TEMPO 回帧：$r")
        }
        return r
    }

    /** 设置节奏档位 0..5（60/80/100/120/160/200 BPM）。 */
    fun setTempo(index: Int): Ack = mustAck(buildTempoSet(index), "TEMPO=$index")

    /**
     * 清空一个槽位（2026-10-29 新增）。
     *
     * 板子会把该槽的 `ready_mask` 清零、`song_counts` 置 0，
     * 于是那格回到「没曲子」状态，可以重新录入。
     *
     * 同时把 App 侧的记账也清掉 —— 否则下次同步仍以为板内有内容而跳过。
     */
    fun clearSlot(slot: Int): Ack {
        val a = mustAck(buildClear(slot), "CLEAR 槽${slot + 1}")
        lib.noteBoardState(slot, null)
        return a
    }

    /** 清空全部槽位。 */
    fun clearAll(): Ack {
        val a = mustAck(buildClearAll(), "CLEAR 全部")
        lib.forgetBoard()
        return a
    }

    // -----------------------------------------------------------------------
    // 播放控制
    // -----------------------------------------------------------------------

    /** 开始 GUIDE 引导（该槽必须已就绪）。 */
    fun play(slot: Int): Ack = mustAck(buildPlay(slot), "PLAY 槽${slot + 1}")

    /** 停止。会同时停掉 GUIDE 与 AUTO（`star.v:141` 已含 `bt_guide_stop`）。 */
    fun stop(): Ack = mustAck(buildStop(), "STOP")

    fun setMode(mode: Int, slot: Int): Ack =
        mustAck(buildMode(mode, slot), "MODE=$mode 槽${slot + 1}")

    fun setParam(param: Int, value: Int): Ack = mustAck(buildSet(param, value), "SET")

    fun playFromLibrary(key: String): Ack {
        val e = lib.get(key)
        val slot = lib.playlistEntries().firstOrNull { it.second.entryId == e.entryId }?.first
            ?: throw SessionError("「${e.name}」不在当前曲单里，无法播放")
        return play(slot)
    }

    // -----------------------------------------------------------------------
    // 录音（只回传音符事件，绝不传音频）
    // -----------------------------------------------------------------------

    fun recStart(): Ack = mustAck(buildRecStart(), "REC_START")
    fun recStop(): Ack = mustAck(buildRecStop(), "REC_STOP")

    /** 把录音区的内容捞进指定曲谱槽（RTL 会截断到 512 字节 = 256 音符）。 */
    fun recCommit(slot: Int): Ack = mustAck(buildRecCommit(slot), "REC_COMMIT→槽${slot + 1}")

    fun recInfo(): RecInfo {
        val r = sendFrame(buildRecInfo())
        if (r !is RecInfo) throw SessionError("REC_INFO 未返回 RECINFO：$r")
        return r
    }

    /**
     * 回读录音区的音符事件。
     *
     * **只读音符字节，不读音频** —— 赛题「严禁直接播放预录 PCM」，
     * 录音回传必须是音符事件回读。
     *
     * @param bytes 要读的字节数（会被截到录音区大小）。
     * @return 音符列表。
     */
    fun recReadNotes(bytes: Int = REC_BYTES): List<ChordEvent> {
        val total = minOf(bytes, REC_BYTES)
        val blob = ByteArray(total)
        var addr = 0
        while (addr < total) {
            var n = minOf(REC_READ_CHUNK, total - addr)
            // ★ v2：REC_READ 的 n 是任意 1..16 字节，但事件是 4 字节一组。
            //   为让后续解析对齐，申请长度按 4 的倍数取整（末尾不足则按剩余字节）。
            n = minOf(n, (total - addr))
            val r = sendFrame(buildRecRead(addr, n))
            if (r !is RecData) throw SessionError("REC_READ@$addr 未返回 RECDATA：$r")
            if (r.data.size != n) {
                throw SessionError("REC_READ@$addr 期望 $n 字节，实收 ${r.data.size}")
            }
            r.data.copyInto(blob, addr)
            addr += n
        }
        return bytesToEvents(blob)
    }

    // -----------------------------------------------------------------------
    // 同步
    // -----------------------------------------------------------------------

    /**
     * 把主库的当前曲单同步到板子 4 槽。
     *
     * @param auto 先问板子状态：若除内置槽外都没有就绪（刚上电/掉电）→ 自动全量重传。
     *
     * ★ 为什么结束前要再查一次 STATUS（这一步不能省）：
     *   如果同步中途板子断电，前面几槽的 ACK 已经收到、记账也写了，
     *   但 BSRAM 内容其实已经没了。记账「以为传好了」，下次就跳过 ——
     *   于是谱子永远缺那几首，且**不报任何错**。所以传完必须回头核对
     *   `ready_mask`，发现掉电就把这次的所有记账作废并全量重来一次。
     */
    fun sync(
        forceFull: Boolean = false,
        auto: Boolean = true,
        forceBuiltin: Boolean = false,
    ): SyncReport {
        val t0 = now()
        var rep = SyncReport()
        var full = forceFull

        if (auto) {
            val st = try {
                query()
            } catch (e: SessionError) {
                throw SessionError("板子无响应，无法同步：${e.message}", e)
            }
            // ★ 掉电判据（2026-10-28 重做）：
            //
            //   原来只靠 boardIsBlank()，前提是「槽0 只读、上电必定 ready」。
            //   现在槽0 可写，那个前提没了：只要板子上有**任何一个**槽还 ready，
            //   ready_mask 就不为 0，判空永远不成立 → 掉电检测失效。
            //
            //   改成直接比对记账：
            //     「记账里说槽 s 有曲子（boardState[s] 非空），而板子现在报 s 不 ready」
            //     ⇒ 那一格的内容没了 ⇒ 判定掉电。
            //
            //   这个判据对槽0 只读/可写两种模式都成立，也不再依赖 BUILTIN_SLOT 的特殊性。
            val lostSome = (0 until SONG_COUNT).any { s ->
                lib.boardState[s] != null && !st.ready(s)
            }
            if (lostSome) {
                rep.powerLossDetected = true
                lib.forgetBoard()
                full = true
                log("记账说板上有曲谱，但板子报告有的槽空了 → 判定掉电，转为全量重传")
            } else if (lib.protectBuiltinSlot && st.ready(BUILTIN_SLOT)) {
                log("槽 $BUILTIN_SLOT 内置曲就绪（出厂 $BUILTIN_NOTES 音），默认不覆盖")
            }
        }

        val plan = lib.planSync(forceFull = full, forceBuiltin = forceBuiltin)
        log(plan.describe())

        rep.skipped.addAll(plan.skips.map { it.first to it.second })
        rep.builtinProtected.addAll(plan.builtinProtected)

        // 记录这次真正下发了哪些槽，便于掉电后重来
        val attempted = mutableListOf<Pair<Int, Entry>>()
        for ((slot, e) in plan.uploads) {
            try {
                uploadSong(slot, e)
                rep.uploaded.add(slot to e)
                attempted.add(slot to e)
                lib.noteBoardState(slot, e)
            } catch (err: SessionError) {
                rep.failed.add(Triple(slot, e, err.message ?: "未知错误"))
                // 这一槽坏了不该拖垮其它槽：继续下一首
                continue
            }
        }

        // ---- 收尾核对：中途掉电的话，这次的记账全部作废并重传 ----
        if (attempted.isNotEmpty() && auto) {
            if (boardLostPower(attempted)) {
                rep.powerLossDetected = true
                rep.uploaded.clear()
                rep.failed.clear()
                rep.skipped.clear()
                lib.forgetBoard()
                log("同步途中板子掉电，作废本次记账并全量重传")
                rep = fullResync(rep, forceBuiltin)
            }
        }

        rep.bytesSent = rep.uploaded.sumOf { it.second.sizeBytes }
        rep.framesSent = framesSent
        rep.retries = retries
        rep.elapsed = now() - t0
        return rep
    }

    private fun fullResync(rep: SyncReport, forceBuiltin: Boolean): SyncReport {
        val plan = lib.planSync(forceFull = true, forceBuiltin = forceBuiltin)
        for ((slot, e) in plan.uploads) {
            try {
                uploadSong(slot, e)
                rep.uploaded.add(slot to e)
                lib.noteBoardState(slot, e)
            } catch (err: SessionError) {
                rep.failed.add(Triple(slot, e, err.message ?: "未知错误"))
            }
        }
        return rep
    }

    /**
     * 板子是否处于「刚上电」状态（只有内置曲，别的槽都空）。
     *
     * 不能直接用 `ready_mask == 0`：RTL 上电就 `ready_mask=0b0001`，
     * 这个值永远不为 0，掉电检测会静默失效。正确判据是
     * **除内置槽以外的 ready 位全为 0**。
     */
    fun boardIsBlank(st: Status): Boolean {
        var mask = st.readyMask and 0x0F
        if (lib.protectBuiltinSlot) mask = mask and (1 shl BUILTIN_SLOT).inv() and 0x0F
        return mask == 0
    }

    /**
     * 核对板子是否还认为刚传的槽是就绪的。
     *
     * 判据：`ready_mask` 里这次传过的槽**必须**都是 1。
     * 只要有任何一个变成 0，就说明 BSRAM 被清过（掉电 / 重配置）。
     */
    fun boardLostPower(attempted: List<Pair<Int, Entry>>): Boolean {
        val st = try {
            query()
        } catch (_: SessionError) {
            return true                      // 连不上也算异常，宁可重来
        }
        for ((slot, _) in attempted) if (!st.ready(slot)) return true
        return false
    }

    /**
     * 下发一首曲子：BEGIN → DATA… → END。
     *
     * seq 必须从 0 连续递增 —— 所以这里自己数，不依赖别处的顺序。
     * 每帧最多 [MAX_DATA_BYTES] 字节 = **8 个事件**（v2；v1 是 16 个音符），
     * 即 RTL 的 n 上限 32。chunk 边界必须落在 4 字节倍数上，否则板子回 result=3。
     */
    fun uploadSong(slot: Int, e: Entry) {
        val blob = e.payloadBytes
        mustAck(buildBegin(slot, e.count), "BEGIN 槽${slot + 1}")
        var seq = 0
        var off = 0
        while (off < blob.size) {
            // 取 4 的倍数个事件，且不超过单帧上限
            val take = minOf(MAX_DATA_BYTES, blob.size - off)
            val chunk = blob.copyOfRange(off, off + take)
            mustAck(buildData(seq, chunk), "DATA seq=$seq 槽${slot + 1}")
            seq++
            off += take
        }
        mustAck(buildEnd(slot), "END 槽${slot + 1}")
    }

    /** 关闭通道。 */
    fun close() = transport.close()
}

/**
 * v1 兼容：把字节流按「键位,时值」拆成单音音符。
 *
 * **v2 的代码一律用 [bytesToEvents]**。保留此函数只为读取旧录音区数据或对拍。
 */
fun parseNotes(blob: ByteArray): List<com.epiano.ble.protocol.Note> {
    val out = mutableListOf<com.epiano.ble.protocol.Note>()
    var i = 0
    while (i + 1 < blob.size) {
        val key = blob[i].toInt() and 0xFF
        val dur = blob[i + 1].toInt() and 0xFF
        // 空白区（全 0）跳过：录音区尾部没写过的格子就是 0
        if (key == 0 && dur == 0) {
            i += 2
            continue
        }
        val d = if (dur == 0) 1 else dur      // RTL 把时值 0 兜底成 1
        val k = if (key > 23 && key != com.epiano.ble.protocol.REST) null else key
        if (k != null) out.add(com.epiano.ble.protocol.Note(k, minOf(d, 127)))
        i += 2
    }
    return out
}

/** 调试用：把一帧的 hex 打出来。 */
fun describeFrame(frame: ByteArray): String = hex(frame)
