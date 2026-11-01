package com.epiano.ble.protocol

/**
 * FPGA 电子琴 蓝牙下载/演奏指引协议 —— 手机端协议层（Kotlin 实现）。
 *
 * 本文件是 `art1/app_protocol/protocol.py` 的一对一移植，而 `protocol.py` 又是
 * `src/bt_link.v` + `src/guide_player.v` + `src/song_ram.v` 的手机端对偶实现。
 * 所有语义都从 RTL 逐行核对得出，**以 RTL 为准**。
 *
 * 本包（protocol）刻意**不引用任何 Android 类**，因此可以在纯 JVM 单测里直接跑
 * `gradle test`，不需要模拟器。BLE 相关代码全部隔离在 `ble` 包里。
 *
 * 设计约束（来自 RTL，不是可选项）：
 *
 *  * 帧格式 `0xA5 | LEN | CMD | PAYLOAD[LEN] | CRC_LO | CRC_HI`
 *    LEN 只数 PAYLOAD，不含 CMD、不含 0xA5、不含 CRC。
 *  * CRC16-CCITT-FALSE  poly=0x1021 init=0xFFFF refin=false refout=false xorout=0，
 *    覆盖 LEN + CMD + PAYLOAD（**不含 0xA5**）。逐字节、**每字节 MSB 先**算，与 RTL 的
 *        rxcrc   <= {rxcrc[14:0],1'b0} ^ ((rc_byte[7]^rxcrc[15]) ? 16'h1021 : 0)
 *        rc_byte <= {rc_byte[6:0],1'b0}
 *    完全等价。已知向量 CRC("123456789") = 0x29B1。
 *    **不要用 java.util.zip.CRC32** —— 那不是 CRC16。
 *  * 回帧
 *        `0x5A | LEN | 0x81 | {原cmd, result} | CRC_LO | CRC_HI`              ACK
 *        `0x5A | LEN | 0x82 | {state,song,done_lo,done_hi,ready} | CRC`       STATUS
 *        `0x5A | LEN | 0x83 | {tone,bend,vib,delay} | CRC`                    PARAM
 *        `0x5A | LEN | 0x84 | {status,bytes_lo,bytes_hi} | CRC`               RECINFO
 *        `0x5A | LEN | 0x85 | {a_lo,a_hi,n,b0..bn-1} | CRC`                   RECDATA
 *  * 每个音符 2 字节 = 键位(0..23，0x7F=休止) + 时值(1..127，单位 1/16 音符)。
 *    两个字节 RTL 都会读，**两个都必须发**：
 *      · guide_player.v（GUIDE）拿第 2 字节做超时强制前进的时限；
 *      · auto_player.v （AUTO） 拿第 2 字节决定发声长度，中点抬键断音。
 *    时值写 0 会被 RTL 拒绝（整块 result=3），**0 是"这格没写"的标记，不是合法音符**。
 *
 * 与文档的差异（以 RTL 为准）：
 *  1. 文档写「每首最多 255 音符」——对。RTL 有 512 字节容量，但 BEGIN 的 count 是
 *     **单字节**，最大只能表达 255，所以实际可达上限就是 255。
 *  2. `END` 的就绪判据是 `wr_idx >= song_cnt*2`（收到字节数够 count 个音符的 2 倍）。
 *  3. `PLAY` 若该首未就绪，RTL 回 result=3（与"长度错"同码）——语义上更像
 *     「未就绪」，但 RTL 沿用 3，本实现照抄不改，调用方须先用 QUERY 预检。
 *
 * 2026-10-27 对 RTL 的核对要点（本实现据此写）：
 *  · `result=3` 是**多义**的：长度错 / 槽未就绪 / 已在录音 / 没在录音 / 录音区空。
 *  · DATA 重传判据是 `wr_idx!=0 && seq==exp_seq-1 && 整帧CRC==last_data_crc`，
 *    **必须逐字节相同**；同 seq 不同内容 ⇒ result=2。
 *  · `LEN>34` 板子**连 ACK 都不回**，只把 state 置 ERROR。
 *  · 板子**从不主动发帧**（无心跳、无进度推送），一切靠 QUERY 轮询。
 */

// ---------------------------------------------------------------------------
// 常量：全部取自 bt_link.v 的 localparam
// ---------------------------------------------------------------------------

/** 手机 → 板的方向字节。 */
const val SOF_IN = 0xA5

/** 板 → 手机的方向字节。 */
const val SOF_OUT = 0x5A

const val R_ACK = 0x81
const val R_STATUS = 0x82
const val R_PARAM = 0x83
const val R_RECINFO = 0x84
const val R_TEMPO = 0x86
const val R_DATA = 0x85

const val CMD_BEGIN = 0x01
const val CMD_DATA = 0x02
const val CMD_END = 0x03
const val CMD_PLAY = 0x04
const val CMD_STOP = 0x05
const val CMD_QUERY = 0x06
/** 2026-10-26 新增：手机端补齐对播放模式、参数、录音的全部控制权。 */
const val CMD_MODE = 0x07
const val CMD_SET = 0x08
const val CMD_PARA = 0x09
const val CMD_REC_START = 0x0A
const val CMD_REC_STOP = 0x0B
const val CMD_REC_COMMIT = 0x0C
const val CMD_REC_READ = 0x0D
const val CMD_REC_INFO = 0x0E

/**
 * TEMPO（0x0F）：读写节奏档位。**2026-10-28 新增。**
 *
 * payload 为空 ⇒ 查询，板子回 `0x86` `{档位, BPM}`；
 * payload = `{档位}` 且 0..5 ⇒ 设置，回 ACK。
 *
 * 为什么单独开一条命令而不是塞进 SET：SET 只能写不能读，
 * 而 PARA 的 4 字节回帧已被音色/变调/颤音/延时占满，再加要破坏既有帧格式。
 */
const val CMD_TEMPO = 0x0F

/**
 * CLEAR（0x10）：清空槽位。**2026-10-29 新增。**
 *
 * payload = `{song}` ⇒ 清那一个槽；payload 为空 ⇒ 清全部 4 个槽。
 *
 * 板子端做的事：`ready_mask` 对应位清零、`song_counts` 对应位置 0，
 * 并停掉正在播放的 GUIDE/AUTO。
 *
 * ★ 为什么必须有这条命令：
 *   `ready_mask` 一旦被置 1，**除了复位没有任何办法清回 0**。
 *   于是某槽写进内容后就永远"有曲子"，用户没法让它回到空状态 ——
 *   表现为「重开软件旧信息还在、无法重新录」。
 */
const val CMD_CLEAR = 0x10

/** 节奏档位 → BPM。必须与 `beat_gen.v` 的查表顺序一致。 */
val TEMPO_BPMS: List<Int> = listOf(60, 80, 100, 120, 160, 200)

/** 默认档位（120BPM），与板子复位值一致。 */
const val TEMPO_DEFAULT = 3

/** 命令名表，用于日志与错误信息。 */
val CMD_NAMES: Map<Int, String> = mapOf(
    CMD_BEGIN to "BEGIN", CMD_DATA to "DATA", CMD_END to "END",
    CMD_PLAY to "PLAY", CMD_STOP to "STOP", CMD_QUERY to "QUERY",
    CMD_MODE to "MODE", CMD_SET to "SET", CMD_PARA to "PARA",
    CMD_REC_START to "REC_START", CMD_REC_STOP to "REC_STOP",
    CMD_REC_COMMIT to "REC_COMMIT", CMD_REC_READ to "REC_READ",
    CMD_REC_INFO to "REC_INFO",
    CMD_TEMPO to "TEMPO", CMD_CLEAR to "CLEAR",
)

/** 播放模式（0x07 MODE 的 mode 字段）。 */
const val MODE_STOP = 0
const val MODE_GUIDE = 1
const val MODE_AUTO = 2
val MODE_NAMES: Map<Int, String> = mapOf(MODE_STOP to "STOP", MODE_GUIDE to "GUIDE", MODE_AUTO to "AUTO")

/** 参数种类（0x08 SET 的 param 字段）。 */
const val SET_TONE = 0
const val SET_BEND = 1
const val SET_VIB = 2
const val SET_DELAY = 3

/**
 * SET param=4：节奏档位（0..5 → 60/80/100/120/160/200 BPM）。
 *
 * 板子实际上更推荐用 `TEMPO`（0x0F）命令，因为那条能**读回**；
 * 这里保留是为了与 SET 的通用路径一致。
 */
const val SET_TEMPO = 4

/**
 * SET param=5：**GUIDE 严格节奏模式**（0=等待按键，1=到时限强制前进并记 miss）。
 *
 * 2026-10-29 新增。配合曲谱里的休止（空帧），GUIDE 就能严格按节拍走：
 * 休止期间不亮任何键，只按拍推进。
 */
const val SET_STRICT = 5

val SET_NAMES: Map<Int, String> = mapOf(
    SET_TONE to "TONE", SET_BEND to "BEND", SET_VIB to "VIB",
    SET_DELAY to "DELAY", SET_TEMPO to "TEMPO", SET_STRICT to "STRICT",
)

/**
 * 变调用**无符号偏置**编码：真实半音 = 值 - 12。
 *
 * 为什么不让手机直接发有符号字节：payload 是字节，传负数要靠补码，手机端一不留神
 * 就写错；偏置 12 之后手机只要 +12 就行。RTL 侧校验范围是 0..24。
 */
const val BEND_OFFSET = 12
const val BEND_MIN = -12
const val BEND_MAX = 12

/** 录音区字节数（1 块 18Kb BSRAM = 2048 字节 = 1024 音符）。 */
const val REC_BYTES = 2048
const val REC_MAX_NOTES = REC_BYTES / 2

/** REC_READ 一次最多读 16 字节（RTL：`pbuf[2]>16` 即拒）。 */
const val REC_READ_CHUNK = 16

/** REC_COMMIT 会把录音区**截断到 512 字节 = 256 音符**，因为一个曲谱槽只有 512 字节。 */
const val REC_COMMIT_MAX_NOTES = 256

// result 码
const val RES_OK = 0
const val RES_CRC = 1
const val RES_SEQ = 2
/** 长度 / 参数 / 状态错。注意它**不止**长度错，见文件头说明。 */
const val RES_LEN = 3
const val RES_UNKNOWN = 4

val RESULT_NAMES: Map<Int, String> = mapOf(
    RES_OK to "成功", RES_CRC to "CRC错", RES_SEQ to "序号错",
    RES_LEN to "参数/状态错", RES_UNKNOWN to "未知命令",
)

// state 码
const val ST_IDLE = 0
const val ST_RXING = 1
const val ST_READY = 2
const val ST_ERROR = 3
val STATE_NAMES: Map<Int, String> =
    mapOf(ST_IDLE to "IDLE", ST_RXING to "RXING", ST_READY to "READY", ST_ERROR to "ERROR")

// 容量（v2：每事件 4 字节）
/** 4 首（槽位）。 */
const val SONG_COUNT = 4

/** 每首 512 字节（RTL：`wr_base = {song,9'd0}`）。 */
const val SONG_BYTES = 512

/** 每个事件 4 字节：{LO, MID, HI, DUR}。 */
const val EVENT_BYTES = 4

/**
 * 每首最多 **127 个事件**（v2）。
 *
 * 512 字节 ÷ 4 = 128，但 BEGIN.count 的合法上限由 RTL 卡在 127
 * （`bt_link.v:264` 的 `pbuf[1]>127` 即拒）。留 4 字节余量。
 *
 * ⚠️ v1 时这里是 255（音符）。**含义从「音符数」变成「事件数」，数值也变了。**
 */
const val MAX_EVENTS = 127

/** 每帧最多 32 字节 = **8 个事件**（v1 时是 16 个音符）。 */
const val MAX_DATA_BYTES = 32

/** DATA 的 n 下限 4（RTL：`pbuf[1]<4` 即拒，必须至少凑成 1 个事件）。 */
const val MIN_DATA_BYTES = 4

/**
 * 每帧最多携带的事件数 = 32 / 4 = 8。
 *
 * 注意这比 v1 的 16 少一半，所以**同样长度的曲子 DATA 帧数翻倍**，
 * 下载时间也翻倍。这是位掩码格式的必然代价（换来的是和弦能力）。
 */
const val MAX_EVENTS_PER_FRAME = MAX_DATA_BYTES / EVENT_BYTES

/** payload 上限 34（RTL：pbuf[0:39] 且 `if(rx_data>34) → P_HUNT`）。 */
const val MAX_PAYLOAD = 34

/** 整帧上限 = LEN + 5（A5 + LEN + CMD + CRC×2）。 */
const val MAX_FRAME = MAX_PAYLOAD + 5

/**
 * v1 的休止魔法值。
 *
 * **v2 已不再使用** —— 休止现在是 `ChordEvent.keys == 0`（三个键位字节全 0）。
 * 只保留给旧曲谱文件解析与音名解析用。
 */
const val REST = 0x7F

/** 键位上限 23（C4..B5，键位 = MIDI - 60）。 */
const val MAX_KEY = 23

/** 键位总数（24 键，两八度）。 */
const val KEYS_COUNT = 24

/** 24 位键位掩码的全 1 值。 */
const val KEY_MASK = 0xFFFFFF

// 内置曲
const val BUILTIN_SLOT = 0
const val BUILTIN_READY_MASK = 0b0001

/**
 * 出厂内置曲《欢乐颂》的事件数。
 *
 * ⚠️ 数值仍是 62（与 v1 相同），但**含义从「音符数」变成「事件数」**。
 * v2 下占 62×4 = 248 字节，仍在槽 0 的 512 字节内。
 */
const val BUILTIN_NOTES = 62

/** v1 每首最多 255 个音符 —— 仅用于旧数据校验。 */
const val MAX_NOTES = 255

// 时限（与 RTL 对齐，见协议文档）
/** 同帧内字节间隔上限：1 秒（RTL `frame_idle >= CLK_HZ-1 → P_HUNT`）。 */
const val FRAME_IDLE_TIMEOUT_SECONDS = 1.0

/** 5 秒无 CRC 通过的帧，屏幕掉回 NO DATA（RTL `hb_cnt >= CLK_HZ*5`）。 */
const val LINK_TIMEOUT_SECONDS = 5.0

// ---------------------------------------------------------------------------
// 异常与数据结构
// ---------------------------------------------------------------------------

/** 协议层错误。发送侧构造非法帧、或单帧解析失败时抛出。 */
class ProtocolError(message: String) : Exception(message)

/**
 * 一个**和弦事件**（v2 格式）：24 位键位掩码 + 时值（单位 1/16 音符）。
 *
 * ## v2 改动（2026-10-27）
 *
 * v1 是 `Note(key: Int, dur: Int)` —— 一个字节只装得下一个键位，
 * **结构上只能是单音旋律**。要让录音/回放/GUIDE 都支持和弦，必须换成位掩码：
 *
 * ```
 * 字节0 = keys[7:0]    键位 0..7   （bit0=C4,  bit7=G4）
 * 字节1 = keys[15:8]   键位 8..15  （bit0=G#4, bit7=D#5）
 * 字节2 = keys[23:16]  键位 16..23 （bit0=E5,  bit7=B5）
 * 字节3 = dur          1..127
 * ```
 *
 * **三个键位字节全 0 = 休止**。v1 的 `0x7F` 魔法值被彻底消掉了。
 *
 * @property keys 24 位位图，bit k 对应键位 k（0=C4 .. 23=B5）。
 * @property dur 时值 1..127；**0 非法**（板子回 result=3）。
 */
data class ChordEvent(val keys: Int, val dur: Int) {
    init {
        require(keys in 0..KEY_MASK) { "键位掩码必须是 0..0x${KEY_MASK.toString(16)}，实为 $keys" }
        require(dur in 1..127) { "时值必须是 1..127（0 不是合法事件），实为 $dur" }
    }

    /** 是否是休止（没有任何键按下）。 */
    val isRest: Boolean get() = keys == 0

    /** 这个事件包含的键位列表（升序）。 */
    val keyList: List<Int> get() = (0 until KEYS_COUNT).filter { (keys shr it) and 1 == 1 }

    /** 同时发声音数。 */
    val size: Int get() = Integer.bitCount(keys)

    /** 序列化成 4 字节 `{LO, MID, HI, DUR}`。 */
    fun toBytes(): ByteArray = byteArrayOf(
        (keys and 0xFF).toByte(),
        ((keys shr 8) and 0xFF).toByte(),
        ((keys shr 16) and 0xFF).toByte(),
        dur.toByte(),
    )

    /** 显示名，如 `C4+E4+G4` / `-`（休止）。 */
    val name: String
        get() = if (isRest) "-" else keyList.joinToString("+") { KEY_NAMES[it] }

    companion object {
        /** 单音事件的便捷构造。 */
        fun single(key: Int, dur: Int): ChordEvent {
            require(key in 0..MAX_KEY) { "键位必须是 0..$MAX_KEY，实为 $key" }
            return ChordEvent(1 shl key, dur)
        }

        /** 和弦事件的便捷构造。 */
        fun of(keys: List<Int>, dur: Int): ChordEvent {
            var mask = 0
            for (k in keys) {
                require(k in 0..MAX_KEY) { "键位必须是 0..$MAX_KEY，实为 $k" }
                mask = mask or (1 shl k)
            }
            return ChordEvent(mask, dur)
        }

        /** 休止事件。 */
        fun rest(dur: Int): ChordEvent = ChordEvent(0, dur)
    }
}

/**
 * v1 的单音音符 —— **仅用于兼容旧曲谱文件的读取与升级**。
 *
 * 新的代码路径一律用 [ChordEvent]。保留它是为了让已存在的
 * `library.json`（v2 曲库格式里的 `notes_flat`）还能读出来并转换。
 */
data class Note(val key: Int, val dur: Int) {
    init {
        require(key in 0..MAX_KEY || key == REST) {
            "键位必须是 0..$MAX_KEY 或 $REST(休止)，实为 $key"
        }
        require(dur in 1..127) { "时值必须是 1..127（0 不是合法音符），实为 $dur" }
    }

    fun toBytes(): ByteArray = byteArrayOf(key.toByte(), dur.toByte())

    val name: String get() = if (key == REST) "-" else KEY_NAMES[key]

    /** 升级成 v2 事件。休止（0x7F）转成 keys=0。 */
    fun toChordEvent(): ChordEvent =
        if (key == REST) ChordEvent(0, dur) else ChordEvent(1 shl key, dur)
}

/** 一条曲子：若干和弦事件。 */
data class Song(val events: List<ChordEvent>) {
    init {
        require(events.size in 1..MAX_EVENTS) {
            "事件数必须在 1..$MAX_EVENTS，实为 ${events.size}"
        }
    }

    /** 兼容旧调用：v1 里叫 notes。 */
    val notes: List<ChordEvent> get() = events

    /** 事件数（BEGIN.count 用的就是这个）。 */
    val count: Int get() = events.size

    fun payloadBytes(): ByteArray = eventsToBytes(events)

    companion object {
        /** 从 v1 音符列表升级。 */
        fun fromNotes(notes: List<Note>): Song = Song(notes.map { it.toChordEvent() })
    }
}

/** ACK 回帧：`{原cmd, result}`。 */
data class Ack(val cmd: Int, val result: Int) : Reply {
    val ok: Boolean get() = result == RES_OK
    override fun toString(): String =
        "ACK(${CMD_NAMES[cmd] ?: "0x%02X".format(cmd)}) result=$result " +
            "${RESULT_NAMES[result] ?: "?"}"
}

/** STATUS 回帧。 */
data class Status(val state: Int, val song: Int, val done: Int, val readyMask: Int) : Reply {
    /** 第 slot 槽是否就绪（可播放）。 */
    fun ready(slot: Int): Boolean = (readyMask shr slot) and 1 == 1
    override fun toString(): String =
        "STATUS(state=${STATE_NAMES[state] ?: state}, song=$song, done=$done, " +
            "ready=0b${readyMask.toString(2).padStart(4, '0')})"
}

/** PARAM 回帧。bend 是 0..24 偏置编码，真实半音 = bend - 12。 */
data class Param(val tone: Int, val bend: Int, val vib: Int, val delay: Int) : Reply {
    val bendSemitones: Int get() = bend - BEND_OFFSET
    override fun toString(): String =
        "PARAM(tone=$tone, bend=$bendSemitones, vib=$vib, delay=$delay)"
}

/** RECINFO 回帧。 */
data class RecInfo(val status: Int, val bytes: Int) : Reply {
    val busy: Boolean get() = (status and 1) != 0
    val ready: Boolean get() = (status and 2) != 0

    /**
     * ⚠️ `rec_full` 在 RTL 里**只有复位或下一次 REC_START 才清**（recorder.v:98 是唯一的清）。
     * 所以 REC_STOP 之后可能出现 `busy=0, ready=1, full=1` 这种组合，
     * **不要把 status 当成互斥枚举来读**，逐位读。
     */
    val full: Boolean get() = (status and 4) != 0

    /** 已录**事件数**（v2：字节数 ÷ 4；v1 是 ÷ 2）。 */
    val events: Int get() = bytes / EVENT_BYTES

    /** ⚠️ v1 遗留名，现在返回事件数。新代码请用 [events]。 */
    val notes: Int get() = events
    override fun toString(): String =
        "RECINFO(busy=$busy, ready=$ready, full=$full, bytes=$bytes, events=$events)"
}

/** RECDATA 回帧（REC_READ 的回复）。 */
data class RecData(val addr: Int, val data: ByteArray) : Reply {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RecData) return false
        return addr == other.addr && data.contentEquals(other.data)
    }

    override fun hashCode(): Int = 31 * addr + data.contentHashCode()
    override fun toString(): String = "RECDATA(addr=$addr, n=${data.size})"
}

/** 任意一种回帧。 */
sealed interface Reply

/**
 * TEMPO 回帧：`{档位, BPM}`。**2026-10-28 新增。**
 *
 * 板子同时给出档位与 BPM，手机端不必自己维护「档位→BPM」映射
 * （两边各写一份很容易漂）。
 */
data class Tempo(val index: Int, val bpm: Int) : Reply {
    override fun toString(): String = "TEMPO(档位=$index, ${bpm}BPM)"
}

// ---------------------------------------------------------------------------
// CRC16 / CCITT-FALSE
// ---------------------------------------------------------------------------

private val CRC_TABLE: IntArray = IntArray(256) { i ->
    var c = i shl 8
    repeat(8) {
        c = if ((c and 0x8000) != 0) ((c shl 1) xor 0x1021) and 0xFFFF else (c shl 1) and 0xFFFF
    }
    c
}

/**
 * 单字节更新 CRC（RTL 的 `rc_byte[7]` 逐位等价，**MSB 先**）。
 *
 * 表驱动版本与逐位版本逐位等价，单测里两者对拍过（见 ProtocolTest）。
 */
fun crc16Byte(b: Int, crc: Int = 0xFFFF): Int {
    val idx = ((crc shr 8) xor (b and 0xFF)) and 0xFF
    return ((crc shl 8) xor CRC_TABLE[idx]) and 0xFFFF
}

/**
 * 逐位版本，**故意保留**：它是 RTL `bt_link.v` 里 rc_byte 状态机的直译，
 * 单测用它给表驱动版本做交叉验证（两种独立写法都错的可能性远低于一种）。
 */
fun crc16Bitwise(data: ByteArray, init: Int = 0xFFFF): Int {
    var c = init and 0xFFFF
    for (b in data) {
        val v = b.toInt() and 0xFF
        for (k in 7 downTo 0) {
            val bit = (v shr k) and 1
            c = if (((c shr 15) and 1) xor bit != 0) ((c shl 1) xor 0x1021) and 0xFFFF
            else (c shl 1) and 0xFFFF
        }
    }
    return c
}

/** 对一串字节依次更新 CRC。 */
fun crc16(data: ByteArray, init: Int = 0xFFFF): Int {
    var c = init and 0xFFFF
    for (b in data) c = crc16Byte(b.toInt() and 0xFF, c)
    return c
}

// ---------------------------------------------------------------------------
// 发送侧：构造帧
// ---------------------------------------------------------------------------

/**
 * 构造一帧：`A5 | LEN | CMD | PAYLOAD | CRC_LO | CRC_HI`。
 *
 * CRC 覆盖 LEN、CMD、PAYLOAD（**不含 SOF**），与 RTL 的 P_LEN 起算一致：
 * RTL 在 P_LEN/P_CMD/P_PAY 三态才 rc_start 喂字节，P_HUNT 收到 A5 只清 CRC。
 *
 * payload 超长直接抛异常：RTL 对 LEN>34 的帧**连 ACK 都不回**，
 * 所以在构造期就拦住，不要让一个永远等不到回应的帧上线。
 */
fun buildFrame(cmd: Int, payload: ByteArray = ByteArray(0)): ByteArray {
    if (payload.size > MAX_PAYLOAD) {
        throw ProtocolError(
            "payload 过长：${payload.size} > $MAX_PAYLOAD" +
                "（RTL 的 pbuf 只有 40 字节，LEN>34 的帧被直接丢弃且不回帧）"
        )
    }
    val body = ByteArray(2 + payload.size)
    body[0] = payload.size.toByte()
    body[1] = cmd.toByte()
    payload.copyInto(body, 2)
    val c = crc16(body)
    // 整帧 = A5 | body(LEN,CMD,PAYLOAD) | CRClo | CRChi
    val frame = ByteArray(1 + body.size + 2)
    frame[0] = SOF_IN.toByte()
    body.copyInto(frame, 1)
    frame[1 + body.size] = (c and 0xFF).toByte()
    frame[2 + body.size] = ((c shr 8) and 0xFF).toByte()
    return frame
}

/**
 * BEGIN：开始传第 [song] 首。
 *
 * @param count **事件数** 1..127（v2；v1 时是音符数 1..255）。
 *   RTL `bt_link.v:264`：`pbuf[1]==0 || pbuf[1]>127` → result=3。
 */
fun buildBegin(song: Int, count: Int): ByteArray {
    require(song in 0 until SONG_COUNT) { "song 必须 0..${SONG_COUNT - 1}，实为 $song" }
    require(count in 1..MAX_EVENTS) {
        "count（事件数）必须 1..$MAX_EVENTS，实为 $count" +
            "（v2 每事件 4 字节，512B 槽位只能装 128 个，RTL 卡在 127）"
    }
    return buildFrame(CMD_BEGIN, byteArrayOf(song.toByte(), count.toByte()))
}

/**
 * 构造一个 DATA 帧。`seq` 从 0 开始连续递增。
 *
 * `data` 必须是 **4 的倍数、4..32**（v2 每事件 4 字节）。
 * RTL `bt_link.v:284`：`plen<4 || pbuf[1]<4 || pbuf[1]>32 || |pbuf[1][1:0] || plen!=pbuf[1]+2` → result=3。
 */
fun buildData(seq: Int, data: ByteArray): ByteArray {
    require(seq in 0..0xFF) { "seq 是单字节，实为 $seq" }
    require(data.size in MIN_DATA_BYTES..MAX_DATA_BYTES) {
        "DATA 数据字节数必须 $MIN_DATA_BYTES..$MAX_DATA_BYTES，实为 ${data.size}"
    }
    require(data.size % EVENT_BYTES == 0) {
        "DATA 数据字节数必须是 $EVENT_BYTES 的倍数（一个事件 4 字节），实为 ${data.size}"
    }
    return buildFrame(CMD_DATA, byteArrayOf(seq.toByte(), data.size.toByte()) + data)
}

fun buildEnd(song: Int): ByteArray = buildFrame(CMD_END, byteArrayOf(song.toByte()))

fun buildPlay(song: Int): ByteArray = buildFrame(CMD_PLAY, byteArrayOf(song.toByte()))

/** STOP：空载荷。会同时停掉 GUIDE 与 AUTO（`star.v:141` 已含 `bt_guide_stop`）。 */
fun buildStop(): ByteArray = buildFrame(CMD_STOP)

/** QUERY：空载荷，回 STATUS。心跳用它。 */
fun buildQuery(): ByteArray = buildFrame(CMD_QUERY)

/** MODE：0=停（GUIDE 与 AUTO 一起停）、1=指引、2=自动演奏。 */
fun buildMode(mode: Int, song: Int): ByteArray {
    require(mode in 0..2) { "mode 必须 0..2，实为 $mode" }
    require(song in 0 until SONG_COUNT) { "song 必须 0..${SONG_COUNT - 1}，实为 $song" }
    return buildFrame(CMD_MODE, byteArrayOf(mode.toByte(), song.toByte()))
}

fun buildSet(param: Int, value: Int): ByteArray {
    // 2026-10-29：param 扩到 0..5（新增 4=节奏、5=严格节奏），与 RTL 的
    // `pbuf[0]>5` 判据一致。
    require(param in 0..5) { "param 必须 0..5，实为 $param" }
    val max = when (param) {
        SET_TONE -> 3
        SET_BEND -> 24
        SET_VIB -> 3
        SET_TEMPO -> 5
        else -> 1        // SET_DELAY / SET_STRICT 都是 0..1
    }
    require(value in 0..max) { "param=${SET_NAMES[param]} 的值必须 0..$max，实为 $value" }
    return buildFrame(CMD_SET, byteArrayOf(param.toByte(), value.toByte()))
}

/** 变调便捷入口：传真实半音 -12..+12，内部转成 0..24 偏置。 */
fun buildSetBend(semitones: Int): ByteArray {
    require(semitones in BEND_MIN..BEND_MAX) {
        "变调必须 $BEND_MIN..$BEND_MAX 半音，实为 $semitones"
    }
    return buildSet(SET_BEND, semitones + BEND_OFFSET)
}

fun buildPara(): ByteArray = buildFrame(CMD_PARA)
fun buildRecStart(): ByteArray = buildFrame(CMD_REC_START)
fun buildRecStop(): ByteArray = buildFrame(CMD_REC_STOP)
fun buildRecCommit(song: Int): ByteArray = buildFrame(CMD_REC_COMMIT, byteArrayOf(song.toByte()))

/** REC_READ：读录音区 [addr, addr+n)，n 为 1..16。 */
fun buildRecRead(addr: Int, n: Int): ByteArray {
    require(n in 1..REC_READ_CHUNK) { "n 必须 1..$REC_READ_CHUNK，实为 $n" }
    require(addr >= 0 && addr + n <= REC_BYTES) {
        "读取区间 [${addr}, ${addr + n}) 越界（录音区 $REC_BYTES 字节）"
    }
    return buildFrame(
        CMD_REC_READ,
        byteArrayOf((addr and 0xFF).toByte(), ((addr shr 8) and 0xFF).toByte(), n.toByte())
    )
}

fun buildRecInfo(): ByteArray = buildFrame(CMD_REC_INFO)

/**
 * TEMPO 查询：空 payload，板子回 `0x86` `{档位, BPM}`。
 */
fun buildTempoQuery(): ByteArray = buildFrame(CMD_TEMPO)

/**
 * TEMPO 设置：`{档位}`，档位 0..5 → 60/80/100/120/160/200 BPM。
 */
fun buildTempoSet(index: Int): ByteArray {
    require(index in 0..5) { "节奏档位必须 0..5，实为 $index" }
    return buildFrame(CMD_TEMPO, byteArrayOf(index.toByte()))
}

/**
 * CLEAR：清空一个槽位（`slot` 0..3）。
 */
fun buildClear(slot: Int): ByteArray {
    require(slot in 0 until SONG_COUNT) { "slot 必须 0..${SONG_COUNT - 1}，实为 $slot" }
    return buildFrame(CMD_CLEAR, byteArrayOf(slot.toByte()))
}

/** CLEAR：清空全部 4 个槽位（空 payload）。 */
fun buildClearAll(): ByteArray = buildFrame(CMD_CLEAR)

/**
 * 生成「下载整首曲子」的完整帧序列：BEGIN → DATA×N → END。
 *
 * `perFrame` 是每个 DATA 帧携带的**事件数**，默认 4 ⇒ 16 字节 ⇒ 整帧 23 字节。
 *
 * ⚠️ v2 注意：默认值从 6 改成 4，因为一个事件 4 字节（v1 音符是 2 字节）。
 * 若要保持「整帧 ≤ 20 字节、适配 BLE 默认 MTU 不协商」，就必须 ≤ 4 个事件
 * （4×4=16 字节数据 + seq + n + A5 + LEN + CMD + CRC×2 = 23 字节整帧，
 *  实际需要 MTU 26；本 App 会主动协商 MTU 247，所以这不是问题）。
 */
fun buildDownloadSequence(song: Song, songId: Int, perFrame: Int = 4): List<ByteArray> {
    require(perFrame in 1..MAX_EVENTS_PER_FRAME) {
        "每帧事件数必须 1..$MAX_EVENTS_PER_FRAME，实为 $perFrame"
    }
    val frames = mutableListOf<ByteArray>()
    frames += buildBegin(songId, song.count)
    val blob = song.payloadBytes()
    var seq = 0
    var off = 0
    val chunkBytes = perFrame * EVENT_BYTES
    while (off < blob.size) {
        val block = blob.copyOfRange(off, minOf(off + chunkBytes, blob.size))
        frames += buildData(seq, block)
        seq++
        off += chunkBytes
    }
    frames += buildEnd(songId)
    return frames
}

/** 把和弦事件序列转成字节流（每事件 4 字节）。 */
fun eventsToBytes(events: List<ChordEvent>): ByteArray {
    val out = ByteArray(events.size * EVENT_BYTES)
    events.forEachIndexed { i, e ->
        val b = e.toBytes()
        b.copyInto(out, i * EVENT_BYTES)
    }
    return out
}

/** 从字节流解析和弦事件（4 字节一组；不足一组的尾部字节被忽略）。 */
fun bytesToEvents(blob: ByteArray): List<ChordEvent> {
    val out = mutableListOf<ChordEvent>()
    var i = 0
    while (i + EVENT_BYTES <= blob.size) {
        val keys = (blob[i].toInt() and 0xFF) or
            ((blob[i + 1].toInt() and 0xFF) shl 8) or
            ((blob[i + 2].toInt() and 0xFF) shl 16)
        val dur = blob[i + 3].toInt() and 0xFF
        // 录音区尾部未写的格子是全 0：keys=0 且 dur=0 ⇒ 不是合法事件，跳过
        if (!(keys == 0 && dur == 0)) {
            out.add(ChordEvent(keys, if (dur == 0) 1 else minOf(dur, 127)))
        }
        i += EVENT_BYTES
    }
    return out
}

/** v1 兼容：把音符序列转成旧字节流。仅供旧数据导出/对拍用。 */
fun notesToBytes(notes: List<Note>): ByteArray {
    val out = ByteArray(notes.size * 2)
    notes.forEachIndexed { i, n ->
        out[i * 2] = n.key.toByte()
        out[i * 2 + 1] = n.dur.toByte()
    }
    return out
}

// ---------------------------------------------------------------------------
// 接收侧：单帧解析
// ---------------------------------------------------------------------------

/**
 * 解析一条板 → 手机的完整回帧（含 SOF 与 CRC），并校验 CRC。
 *
 * 校验覆盖 LEN、CMD、PAYLOAD（与发送侧同一口径）。
 * 单帧解析失败**抛异常**；流式解析请用 [FrameSplitter]，它容忍坏帧。
 */
fun parseReply(frameBytes: ByteArray): Reply {
    if (frameBytes.size < 5) {
        throw ProtocolError("回帧太短（${frameBytes.size} 字节）：${hex(frameBytes)}")
    }
    if ((frameBytes[0].toInt() and 0xFF) != SOF_OUT) {
        throw ProtocolError("回帧 SOF 应为 0x5A，实为 0x%02X".format(frameBytes[0].toInt() and 0xFF))
    }
    val ln = frameBytes[1].toInt() and 0xFF
    val total = 2 + 1 + ln + 2
    if (frameBytes.size < total) {
        throw ProtocolError("回帧长度不足：声明 $total，实际 ${frameBytes.size}")
    }
    val b = frameBytes.copyOfRange(0, total)
    val body = b.copyOfRange(1, 2 + 1 + ln)   // LEN + CMD + PAYLOAD
    val c = crc16(body)
    val gotLo = b[total - 2].toInt() and 0xFF
    val gotHi = b[total - 1].toInt() and 0xFF
    if (gotLo != (c and 0xFF) || gotHi != ((c shr 8) and 0xFF)) {
        throw ProtocolError(
            "回帧 CRC 不匹配：收到 %02X%02X，算出 %02X%02X"
                .format(gotHi, gotLo, (c shr 8) and 0xFF, c and 0xFF)
        )
    }
    val cmd = b[2].toInt() and 0xFF
    val payload = b.copyOfRange(3, 3 + ln)
    return when (cmd) {
        R_ACK -> {
            if (ln != 2) throw ProtocolError("ACK 的 LEN 应为 2，实为 $ln")
            Ack(cmd = payload[0].toInt() and 0xFF, result = payload[1].toInt() and 0xFF)
        }

        R_STATUS -> {
            if (ln != 5) throw ProtocolError("STATUS 的 LEN 应为 5，实为 $ln")
            Status(
                state = payload[0].toInt() and 0xFF,
                song = payload[1].toInt() and 0xFF,
                done = (payload[2].toInt() and 0xFF) or ((payload[3].toInt() and 0xFF) shl 8),
                readyMask = payload[4].toInt() and 0x0F,
            )
        }

        R_PARAM -> {
            if (ln != 4) throw ProtocolError("PARAM 的 LEN 应为 4，实为 $ln")
            Param(
                tone = payload[0].toInt() and 0xFF,
                bend = payload[1].toInt() and 0xFF,
                vib = payload[2].toInt() and 0xFF,
                delay = payload[3].toInt() and 0xFF,
            )
        }

        R_RECINFO -> {
            if (ln != 3) throw ProtocolError("RECINFO 的 LEN 应为 3，实为 $ln")
            RecInfo(
                status = payload[0].toInt() and 0xFF,
                bytes = (payload[1].toInt() and 0xFF) or ((payload[2].toInt() and 0xFF) shl 8),
            )
        }

        R_TEMPO -> {
            if (ln != 2) throw ProtocolError("TEMPO 的 LEN 应为 2，实为 $ln")
            Tempo(
                index = payload[0].toInt() and 0xFF,
                bpm = payload[1].toInt() and 0xFF,
            )
        }

        R_DATA -> {
            if (ln < 3) throw ProtocolError("DATA 回帧的 LEN 至少 3（addr 2 + n 1），实为 $ln")
            val n = payload[2].toInt() and 0xFF
            if (ln != 3 + n) throw ProtocolError("DATA 回帧 LEN=$ln 与 n=$n 不符")
            RecData(
                addr = (payload[0].toInt() and 0xFF) or ((payload[1].toInt() and 0xFF) shl 8),
                data = payload.copyOfRange(3, 3 + n),
            )
        }

        else -> throw ProtocolError("未知回帧 CMD 0x%02X".format(cmd))
    }
}

/**
 * 把连续字节流切成一条条回帧（流式解析，容忍分片与粘包）。
 *
 * 为什么需要它：BLE 的 notify 会把一条 10 字节 STATUS 拆成 1~3 个包，
 * 也会把两条 ACK 粘在一起。RTL 侧是逐字节状态机，天然容忍；
 * 手机侧必须自己重新组帧。
 *
 * 容错策略（与 RTL 的 P_HUNT 行为对齐）：
 *   · CRC 错的帧**丢弃并继续找下一个 SOF**，不抛异常 ——
 *     线路上的噪声、上电残字节、或者把发送方向的字节混进来，都会造成坏帧；
 *     真机上抛异常等于「一条噪声把整个会话打断」，那是错的。
 *   · 只有调用方主动用 [parseReply] 单帧解析时才抛 ProtocolError。
 */
class FrameSplitter(private val strict: Boolean = false) {
    private val buf = ArrayList<Int>()
    var badFrames: Int = 0
        private set

    /** 喂入一段字节，产出其中已完整的回帧。 */
    fun feed(data: ByteArray): List<Reply> {
        for (x in data) buf.add(x.toInt() and 0xFF)
        val out = mutableListOf<Reply>()
        while (true) {
            // 找到 SOF
            while (buf.isNotEmpty() && buf[0] != SOF_OUT) buf.removeAt(0)
            if (buf.size < 3) return out
            val ln = buf[1]
            val total = 2 + 1 + ln + 2
            if (buf.size < total) return out
            val frame = ByteArray(total) { buf[it].toByte() }
            val parsed = try {
                parseReply(frame)
            } catch (e: ProtocolError) {
                if (strict) {
                    repeat(total) { buf.removeAt(0) }
                    throw e
                }
                // 丢弃这个假 SOF（只前进 1 字节，让后面可能存在的真 SOF 有机会）
                badFrames++
                buf.removeAt(0)
                continue
            }
            repeat(total) { buf.removeAt(0) }
            out.add(parsed)
        }
    }

    /** 清空缓冲（重连时用）。 */
    fun reset() {
        buf.clear()
        badFrames = 0
    }
}

// ---------------------------------------------------------------------------
// 屏幕字符串复刻
// ---------------------------------------------------------------------------

/**
 * 复刻 `rgb_scope.v` 里 `<BT>` / `<AUTO>` 项共用的 9 字符值显示。
 *
 * 当前 RTL 的 `btcode` 表（4bit，共 11 态；`rgb_scope.v` 2026-10-26 版）：
 *
 * | btcode | 条件 | 显示 |
 * |---|---|---|
 * | 8  | 正在录音 | `RECddd   `（已录音符数，封顶 999）|
 * | 9  | 录音区满、自动停了 | `REC FULL ` |
 * | 10 | 录完且有内容、可提交 | `REC RDY  ` |
 * | 4  | 正在放 GUIDE | `Gddd/ttt ` |
 * | 7  | 正在放 AUTO | `Addd/ttt ` |
 * | 5  | `state==ERROR` | `RX ERROR ` |
 * | 2  | `state==RXING` | `RXddd/ttt` |
 * | 3  | 该槽已就绪 | `RDY n/4  ` |
 * | 6  | 该槽没货，且闪烁处在亮相位 | `--  n/4  ` |
 * | 0  | 该槽没货，且闪烁处在暗相位 | `NO DATA  ` |
 *
 * 三个关键点，别想当然：
 *
 *  1. **屏幕不显示 `OFFLINE` / `LINKED`。** 心跳判不出「蓝牙真的断开」
 *     （模块不报链路状态，只能看收没收到帧），所以 RTL 改成只显示「这首有没有货」。
 *     于是 `linkSeen` 参数**对显示已经没有影响**，保留只为兼容老调用。
 *  2. `NO DATA` 与 `--  n/4` 是**同一个状态的两个闪烁相位**，不是两种状态。
 *     传 `blink=false` 强制走暗相位，只用于截图对拍。
 *  3. **录音态优先级最高**，压过播放和下载。理由：录音时帧上其它状态全是旧值，
 *     不压住会显示成「正在下载」或「某首就绪」，用户完全看不出在录。
 */
fun btDisplayString(
    st: Status,
    linkSeen: Boolean = true,
    guideBusy: Boolean = false,
    total: Int? = null,
    auto: Boolean = false,
    idx: Int? = null,
    blink: Boolean = true,
    recBusy: Boolean = false,
    recReady: Boolean = false,
    recFull: Boolean = false,
    recBytes: Int = 0,
): String {
    // 1) 录音三态优先级最高
    if (recBusy) {
        if (recFull) return "REC FULL "
        var notes = recBytes / 2
        if (notes > 999) notes = 999          // RTL: if(rnv>999) rnv=999
        return "REC%03d   ".format(notes)
    }
    if (recReady) return "REC RDY  "

    // 2) 播放中
    if (guideBusy) {
        val prefix = if (auto) "A" else "G"
        val done = idx ?: st.done
        val den = total ?: done
        return "%s%03d/%03d ".format(prefix, done % 1000, den % 1000)
    }

    // 3) 错误 / 下载中
    when (st.state) {
        ST_ERROR -> return "RX ERROR "
        ST_RXING -> {
            val den = total ?: 0
            return "RX%03d/%03d".format(st.done % 1000, den % 1000)
        }
    }

    // 4) 就绪 / 没货
    val slot = st.song and 0x03
    return if (st.ready(slot)) {
        "RDY %d/4  ".format(slot + 1)
    } else {
        // NO DATA 与 `--  n/4` 是同一状态的两个闪烁相位
        if (blink) "--  %d/4  ".format(slot + 1) else "NO DATA  "
    }
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/** 把字节数组格式化成 `A5 00 06 C9 7D` 这种大写十六进制，便于与文档对拍。 */
fun hex(data: ByteArray): String =
    data.joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }

/** 音名表：键位 0..23 = C4..B5（键位 = MIDI - 60）。 */
val KEY_NAMES: List<String> = buildList {
    val names = listOf("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")
    for (octave in 4..5) for (n in names) add("$n$octave")
}

/** 音名 → 键位；`-` 表示休止（返回 [REST]，调用方应转成 keys=0）。大小写不敏感。 */
fun nameToKey(name: String): Int {
    val t = name.trim()
    if (t == "-" || t.equals("rest", ignoreCase = true)) return REST
    val idx = KEY_NAMES.indexOfFirst { it.equals(t, ignoreCase = true) }
    if (idx < 0) throw ProtocolError("无法识别的音名：$name（应为 C4..B5 或 -）")
    return idx
}

/**
 * 音名串 → 24 位键位掩码。支持和弦：`"C4+E4+G4"`。
 *
 * 这是 v2 新增的解析入口 —— v1 的 [nameToKey] 一次只能解析一个键。
 * `-` 或空串表示休止（掩码 0）。
 */
fun namesToKeyMask(names: String): Int {
    val t = names.trim()
    if (t.isEmpty() || t == "-") return 0
    var mask = 0
    for (part in t.split("+")) {
        val k = nameToKey(part.trim())
        if (k == REST) throw ProtocolError("和弦里不能混用休止符：$names（休止应整组为 `-`）")
        mask = mask or (1 shl k)
    }
    return mask
}

/** MIDI 音高 → 键位（键位 = MIDI - 60，范围 60..83）。 */
fun midiToKey(midi: Int): Int {
    require(midi in 60..83) { "MIDI 必须在 60..83（C4..B5），实为 $midi" }
    return midi - 60
}

/** 键位掩码 → 音名串，如 `C4+E4+G4`。 */
fun keyMaskToNames(mask: Int): String =
    if (mask == 0) "-" else (0 until KEYS_COUNT).filter { (mask shr it) and 1 == 1 }
        .joinToString("+") { KEY_NAMES[it] }
