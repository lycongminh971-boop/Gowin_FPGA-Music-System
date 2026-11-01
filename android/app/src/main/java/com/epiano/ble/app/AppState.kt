package com.epiano.ble.app

import android.content.Context
import com.epiano.ble.library.Library
import com.epiano.ble.session.Session
import com.epiano.ble.session.SessionError
import com.epiano.ble.session.SyncReport
import com.epiano.ble.session.Transport
import com.epiano.ble.ble.BleException
import com.epiano.ble.ble.BleTransport
import com.epiano.ble.protocol.MAX_EVENTS
import com.epiano.ble.protocol.SONG_BYTES
import com.epiano.ble.protocol.EVENT_BYTES
import com.epiano.ble.protocol.ChordEvent
import com.epiano.ble.protocol.Param
import com.epiano.ble.protocol.RecInfo
import com.epiano.ble.protocol.Status
import java.io.File

/**
 * 应用状态中心 —— 把曲库、BLE 通道、会话层缝在一起，并负责持久化。
 *
 * UI 只跟这一层打交道，不直接碰协议细节。
 */
object AppState {

    private const val LIB_FILE = "library.json"

    lateinit var appContext: Context
        private set

    /** 曲库（主库）。 */
    var library: Library = Library()
        private set

    /** BLE 通道。 */
    var ble: BleTransport? = null
        private set

    /** 当前会话（连接就绪后才有）。 */
    var session: Session? = null
        private set

    var lastStatus: Status? = null
    var lastParam: Param? = null
    var lastRecInfo: RecInfo? = null
    var lastSyncReport: SyncReport? = null
    var lastError: String? = null

    /** 状态变化通知（UI 订阅）。 */
    var onChanged: (() -> Unit)? = null

    private fun libFile(): File = File(appContext.filesDir, LIB_FILE)

    fun init(context: Context) {
        appContext = context.applicationContext
        library = loadLibrary()
    }

    // -----------------------------------------------------------------------
    // 持久化
    // -----------------------------------------------------------------------

    private fun loadLibrary(): Library = try {
        val f = libFile()
        if (f.exists()) {
            Library.fromJsonString(f.readText())
        } else {
            Library.seedDefaults().also { saveLibrary(it) }
        }
    } catch (e: Exception) {
        // 曲库损坏时**不能静默清空** —— 那等于把用户的曲子丢了。
        // 改名备份后重新播种，并在 UI 上明确告诉用户。
        lastError = "曲库文件损坏（${e.message}），已备份为 library.json.bak 并重建"
        try {
            libFile().renameTo(File(appContext.filesDir, "$LIB_FILE.bak"))
        } catch (_: Exception) {
        }
        Library.seedDefaults()
    }

    fun saveLibrary(lib: Library = library) {
        try {
            // 原子写：先写临时文件再替换，避免写一半断电导致曲库损坏
            val tmp = File(appContext.filesDir, "$LIB_FILE.tmp")
            tmp.writeText(lib.toJsonString())
            val dst = libFile()
            if (dst.exists()) dst.delete()
            tmp.renameTo(dst)
        } catch (e: Exception) {
            lastError = "保存曲库失败：${e.message}"
        }
        notifyChanged()
    }

    fun notifyChanged() {
        onChanged?.invoke()
    }

    // -----------------------------------------------------------------------
    // 连接
    // -----------------------------------------------------------------------

    fun createTransport(context: Context): BleTransport {
        val t = BleTransport(
            context,
            BleTransport.CharSelector.Auto,
        )
        ble = t
        return t
    }

    /** 在 BLE 通道就绪后创建会话。 */
    fun attachSession(transport: Transport): Session {
        val s = Session(
            transport = transport,
            lib = library,
            settle = 0.0,
            ackTimeout = 0.5,
            maxRetries = 3,
            log = { /* 需要时可打到 Logcat */ },
        )
        session = s
        return s
    }

    fun detachSession() {
        session = null
        lastStatus = null
    }

    // -----------------------------------------------------------------------
    // 后台执行
    // -----------------------------------------------------------------------

    /**
     * 所有 BLE 会话操作共用的后台线程。
     *
     * ★ 为什么必须有它（真机实测：点「刷新状态」界面卡死）：
     *   [Session.sendFrame] 是**阻塞**的 —— 它内部用 `Thread.sleep(0.001)`
     *   轮询回帧，单帧最长等 `ackTimeout`(0.5s)，失败还要重试 `maxRetries`(3) 次。
     *   也就是说一次操作最坏阻塞约 **2 秒**。
     *   之前这些调用直接写在按钮的 `setOnClickListener` 里 ⇒ **跑在 UI 线程上**
     *   ⇒ 主线程被卡住，界面没有响应、日志也不刷新，看起来就是「卡死」。
     *
     * 现在统一丢到这个单线程 executor 上跑，完成后用 [mainHandler] 回主线程刷新 UI。
     * 用**单线程**而不是线程池：BLE 会话是串行的（停等协议），
     * 并发发帧会让 seq 与 ACK 对应关系错乱。
     */
    private val ioExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "epiano-ble-io").apply { isDaemon = true }
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    // =======================================================================
    // 命令队列
    //
    // ★ 2026-10-30 修「停止后点槽还在播上一首」：
    //
    //   原来 runAsync 里有一句 if (busy) { 记一条错误; return } ——
    //   也就是上一个 BLE 操作没做完时，**新命令被直接丢掉**。
    //   而 play/setMode/stop 每个都要发一帧再查一次状态，busy 会持续几百毫秒，
    //   于是用户很快地点「停止 -> 槽2」时，这两条命令都可能被静默丢弃：
    //     停止没发出去 ⇒ 上一首继续响
    //     点槽没发出去 ⇒ 界面看起来像"点了槽却还在放之前的"
    //
    //   ioExecutor 本来就是**单线程**，命令天然串行，丢掉毫无必要。
    //   现在改成排队：按点击顺序逐条执行，不再丢弃。
    //   busy 只用于 UI 禁用按钮，语义变成"队列里还有命令"。
    // =======================================================================
    private val pendingOps = java.util.concurrent.atomic.AtomicInteger(0)

    /** 是否有命令在排队或执行中（UI 据此禁用按钮）。 */
    val busy: Boolean
        get() = pendingOps.get() > 0

    /**
     * 在后台线程执行 BLE 操作，完成后回主线程刷新 UI。
     *
     * @param what 操作名，用于日志与 [lastError] 文案。
     */
    fun runAsync(what: String, block: () -> Unit) {
        pendingOps.incrementAndGet()
        notifyChanged()
        ioExecutor.execute {
            try {
                block()
            } catch (e: SessionError) {
                lastError = "$what 失败：${e.message}"
            } catch (e: BleException) {
                lastError = "$what 失败：${e.message}"
            } catch (e: Exception) {
                lastError = "$what 失败：${e.message ?: e.toString()}"
            } finally {
                pendingOps.decrementAndGet()
                mainHandler.post { notifyChanged() }
            }
        }
    }

    // -----------------------------------------------------------------------
    // 常用操作（统一把异常转成 lastError，UI 不必到处 try）
    // -----------------------------------------------------------------------

    /** 同步执行（仅供已在后台线程的调用方使用，不要在 UI 线程直接调）。 */
    fun run(block: () -> Unit) {
        try {
            lastError = null
            block()
        } catch (e: SessionError) {
            lastError = e.message
        } catch (e: BleException) {
            lastError = e.message
        } catch (e: Exception) {
            lastError = e.message ?: e.toString()
        }
        notifyChanged()
    }

    // ---- 以下是给 UI 用的**异步**入口：一律跑在后台线程 ----
    // 命名规矩：`xxxAsync` = 可安全从 UI 线程调用；无后缀的 `xxx` = 阻塞，需已在后台线程。

    fun refreshStatusAsync() = runAsync("刷新状态") {
        // ★ 三个查询必须放在**同一个后台任务**里串行发出。
        //   早先是连调三个 xxxAsync()，但 runAsync 有 busy 防重入，
        //   后两个会被直接忽略 —— 表现成「只刷新了状态，参数和录音永远是旧的」。
        lastStatus = requireSession().query()
        lastParam = requireSession().para()
        lastRecInfo = requireSession().recInfo()
    }
    fun refreshParamAsync() = runAsync("读回参数") { refreshParam() }
    fun refreshRecInfoAsync() = runAsync("查询录音状态") { refreshRecInfo() }
    fun syncAsync(forceFull: Boolean = false, forget: Boolean = false) =
        runAsync("同步曲单") { sync(forceFull, forget) }
    fun playAsync(slot: Int) = runAsync("播放槽${slot + 1}") { play(slot) }
    fun stopAsync() = runAsync("停止") { stop() }
    fun setModeAsync(mode: Int, slot: Int) = runAsync("切换播放模式") { setMode(mode, slot) }
    fun setParamAsync(param: Int, value: Int) = runAsync("设置参数") { setParam(param, value) }
    fun recStartAsync() = runAsync("开始录音") { recStart() }
    fun recStopAsync() = runAsync("停止录音") { recStop() }
    fun recCommitAsync(slot: Int) = runAsync("保存录音") { recCommit(slot) }

    // ---- 2026-10-29 新增：清空槽位 ----

    /** 清空一个槽位（板子 + App 记账 + 曲单）。 */
    fun clearSlotAsync(slot: Int) = runAsync("清空槽${slot + 1}") {
        requireSession().clearSlot(slot)
        // 曲单里对应位置也清掉，避免界面仍显示一个已经不存在的曲子
        val cur = library.playlist.toMutableList()
        cur[slot] = null
        library.setSlots(cur)
        saveLibrary()
        lastStatus = requireSession().query()
    }

    /** 清空全部 4 个槽位。 */
    fun clearAllAsync() = runAsync("清空全部槽位") {
        requireSession().clearAll()
        library.setSlots(listOf(null, null, null, null))
        saveLibrary()
        lastStatus = requireSession().query()
    }

    /** 回读录音事件（异步）。结果写进 [lastRecNotes]。 */
    val lastRecNotes = mutableListOf<ChordEvent>()

    fun recReadAsync() = runAsync("回读录音") {
        val notes = recReadAll()
        lastRecNotes.clear()
        lastRecNotes.addAll(notes)
    }

    fun refreshStatus() = run {
        lastStatus = requireSession().query()
    }

    fun refreshParam() = run {
        lastParam = requireSession().para()
        // 2026-10-28：顺带把节奏也读回来，否则滑块永远停在默认值，
        //   用户看到的值会和板子实际节奏不一致。
        lastTempo = requireSession().tempo()
    }

    fun refreshRecInfo() = run {
        lastRecInfo = requireSession().recInfo()
    }

    /**
     * 同步曲单。
     *
     * @param forceFull 无视记账，全部重传
     * @param forget    **先清空板内记账**（2026-10-28 新增）
     *
     * ## forget 解决什么问题
     *
     * 旧的同步只比对「本地曲库指纹」与「App 记账里的指纹」，**从不校验板内真实内容**。
     * 一旦某次把错误曲谱写进板子，记账就会记住那个错误指纹；
     * 之后哪怕曲库改对了，只要本地没再变，就永远显示「已是最新」而不重发 ——
     * 错误内容永久留在板子里，表现为「名字和听到的不是一首歌」。
     *
     * `forget=true` 先把记账清空，逼着每一槽都重发一遍，从而真正覆盖板内内容。
     * 这就是「强制全量重传」按钮背后的语义。
     */
    fun sync(forceFull: Boolean = false, forget: Boolean = false) = run {
        if (forget) library.forgetBoard()
        // ★ 2026-10-28：forceFull 时**同时**强制覆盖内置槽（forceBuiltin）。
        //
        //   原来只传 forceFull，而 `planSync` 里内置槽保护是**独立判断**的：
        //       if (protectBuiltinSlot && slot == BUILTIN_SLOT && !forceBuiltin) → 跳过
        //   于是「强制全量重传」也覆盖不了槽1，用户看到的就是
        //   「槽1 是内置槽，烧不进别的歌」。
        //   现在 forceFull ⇒ 必定连槽1 一起重发，名实相符。
        lastSyncReport = requireSession().sync(
            forceFull = forceFull,
            forceBuiltin = forceFull,
        )
        lastStatus = requireSession().query()
    }

    fun play(slot: Int) = run {
        requireSession().play(slot)
        lastStatus = requireSession().query()
    }

    fun stop() = run {
        requireSession().stop()
        lastStatus = requireSession().query()
    }

    fun setMode(mode: Int, slot: Int) = run {
        requireSession().setMode(mode, slot)
        lastStatus = requireSession().query()
    }

    fun setParam(param: Int, value: Int) = run {
        requireSession().setParam(param, value)
        lastParam = requireSession().para()
    }

    /** 当前节奏（2026-10-28 新增）。 */
    var lastTempo: com.epiano.ble.protocol.Tempo? = null
        private set

    fun setTempo(index: Int) = run {
        requireSession().setTempo(index)
        lastTempo = requireSession().tempo()
    }

    fun refreshTempo() = run {
        lastTempo = requireSession().tempo()
    }

    fun recStart() = run {
        requireSession().recStart()
        lastRecInfo = requireSession().recInfo()
    }

    fun recStop() = run {
        requireSession().recStop()
        lastRecInfo = requireSession().recInfo()
    }

    /**
     * 录音写入某个槽。
     *
     * ★ 2026-10-28 补齐：**同时更新本地曲单与曲库**。
     *
     *   原来这里只把录音写进板子，曲单一个字都不动 ——
     *   于是「录音存到槽1」之后，界面仍显示那个槽原来的名字，
     *   而板子里已经是录音内容，名字和声音又对不上。
     *
     *   现在的做法：
     *     1) 把录音回读成事件列表（**只回读音符，绝不涉及音频**）
     *     2) 以「录音N」为名加入曲库（若同名已存在则覆盖它的内容）
     *     3) 把这个条目放进目标槽的曲单
     *     4) 记账：板内该槽 = 这个新条目
     *
     *   所以操作完立刻就能看到槽位名字变了，且与板内内容一致。
     */
    fun recCommit(slot: Int) = run {
        val s = requireSession()
        s.recCommit(slot)
        lastRecInfo = s.recInfo()
        lastStatus = s.query()

        // ==================================================================
        // 回读板内该槽的真实内容，并把它变成曲库里的一条曲目
        //
        // ★ 2026-10-29 二次审查发现三个真问题，这里一并修掉：
        //
        // 【问题1】回读长度原来用 rec_bytes（录音区总字节），但 COMMIT
        //   只把**前 512 字节**（=128 事件）拷进曲谱槽（RTL 里
        //   `cm_total <= rec_bytes>512 ? 512 : rec_bytes`）。
        //   录得久一点，App 就会把槽里不存在的内容也读进来，
        //   曲库里的事件数比板子里多 ⇒ 名字和声音又对不上。
        //   ⇒ 现在按 COMMIT 的实际拷贝长度取。
        //
        // 【问题2】即使 512 字节，那也是 **128 个事件**，而协议规定
        //   BEGIN.count 最大 **127**（MAX_EVENTS）。原样塞进曲库会在
        //   `library.add` 里抛 IllegalArgumentException，用户只看到一条
        //   "值必须在 1..127" 的莫名错误。
        //   ⇒ 现在显式截到 MAX_EVENTS。
        //
        // 【问题3】按**名字**找已有条目（`firstOrNull { it.name == name }`）
        //   会撞车：曲库里可能有两首同名（用户手加的和种子曲同名）。
        //   ⇒ 改成按"该槽当前绑定的 entryId"找，语义才唯一。
        // ==================================================================
        val recBytes = lastRecInfo?.bytes ?: 0
        val copyBytes = minOf(recBytes, SONG_BYTES)          // COMMIT 实际拷多少
        val maxBytes = MAX_EVENTS * EVENT_BYTES              // 协议上限 127 事件

        if (recBytes > SONG_BYTES) {
            lastError = "录音 ${recBytes} 字节，超过单槽容量 ${SONG_BYTES} 字节，" +
                "只保存了前 ${SONG_BYTES / EVENT_BYTES} 个事件（后面的被截断）"
        }

        val events = try {
            s.recReadNotes(minOf(copyBytes, maxBytes))
        } catch (e: Exception) {
            lastError = "录音已写入板子，但回读失败：${e.message}（曲库没有更新，可点「回读音符」重试）"
            null
        }

        if (events != null && events.isNotEmpty()) {
            // 名字：沿用该槽原有名字（内容被录音替换），没有就用「录音N」
            val slotEntryId = library.playlist.getOrNull(slot)
            val oldName = slotEntryId?.let { library.entries[it]?.name }
            val name = oldName ?: nextRecName()

            // 按 entryId 找该槽原来的条目，而不是按名字（避免同名撞车）
            val entry = if (slotEntryId != null && library.entries.containsKey(slotEntryId)) {
                library.replaceNotes(slotEntryId, events)
            } else {
                library.add(name, events)
            }
            val cur = library.playlist.toMutableList()
            cur[slot] = entry.entryId
            library.setSlots(cur)
            // 板内该槽现在就是这份内容，记账写对，避免下次同步白跑
            library.noteBoardState(slot, entry)
            saveLibrary()
        }
    }

    /** 生成一个不重名的「录音N」名字。 */
    private fun nextRecName(): String {
        val used = library.entries.values.map { it.name }.toSet()
        var n = 1
        while ("录音$n" in used) n++
        return "录音$n"
    }

    /** 回读录音的**事件**（和弦，不是音频）。 */
    fun recReadAll(): List<ChordEvent> {
        var events: List<ChordEvent> = emptyList()
        run {
            val info = requireSession().recInfo()
            lastRecInfo = info
            events = requireSession().recReadNotes(info.bytes)
        }
        return events
    }

    /** 数据通道诊断：发/收字节数，用于区分「写没送达」与「板子没回」。 */
    fun linkStats(): String {
        val t = ble ?: return "通道未建立"
        return "TX=${t.bytesWritten}B  RX=${t.bytesReceived}B  MTU=${t.mtu}"
    }

    private fun requireSession(): Session =
        session ?: throw BleException("尚未连接板子")

    // -----------------------------------------------------------------------
    // 曲库编辑
    // -----------------------------------------------------------------------

    fun addSong(name: String, melody: String) = run {
        val notes = com.epiano.ble.library.parseMelody(melody)
        library.add(name, notes)
        saveLibrary()
    }

    fun setPlaylistSlots(keys: List<String>) = run {
        library.setPlaylist(keys)
        saveLibrary()
    }

    /** 按槽位设置曲单（`null` = 该槽留空，位置原样保留）。 */
    fun setSlots(slots: List<String?>) = run {
        library.setSlots(slots)
        saveLibrary()
    }

    fun removeSong(entryId: String) = run {
        library.remove(entryId)
        saveLibrary()
    }

    fun renameSong(entryId: String, newName: String) = run {
        library.rename(entryId, newName)
        saveLibrary()
    }

    /** 当前曲单（槽位 → 曲名）。 */
    fun playlistNames(): List<String?> =
        library.playlist.map { id -> id?.let { library.entries[it]?.name } }

    /** 每首最多事件数（v2：127）。 */
    fun maxEvents(): Int = MAX_EVENTS
}
