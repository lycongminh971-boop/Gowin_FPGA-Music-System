package com.epiano.ble

import android.Manifest
import android.os.Build
import android.os.Bundle
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.RadioGroup
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.epiano.ble.app.AppState
import com.epiano.ble.ble.BleTransport
import com.epiano.ble.protocol.BEND_MAX
import com.epiano.ble.protocol.BEND_MIN
import com.epiano.ble.protocol.BEND_OFFSET
import com.epiano.ble.protocol.MODE_AUTO
import com.epiano.ble.protocol.MODE_GUIDE
import com.epiano.ble.protocol.MODE_STOP
import com.epiano.ble.protocol.SET_DELAY
import com.epiano.ble.protocol.SET_STRICT
import com.epiano.ble.protocol.SET_TONE
import com.epiano.ble.protocol.SET_VIB
import com.epiano.ble.protocol.buildSetBend
import com.epiano.ble.protocol.TEMPO_BPMS
import com.epiano.ble.protocol.TEMPO_DEFAULT
import com.epiano.ble.protocol.btDisplayString
import com.epiano.ble.protocol.hex

/**
 * 主界面。
 *
 * 设计原则：**这一层只做「把点击转成 AppState 调用」和「把状态显示出来」**，
 * 所有协议语义都在 protocol/session 包里（那些包有 103 项单测兜着）。
 */
class MainActivity : AppCompatActivity() {

    private lateinit var tvConnState: TextView
    private lateinit var tvBoard: TextView
    private lateinit var tvSlots: TextView
    private lateinit var tvRecInfo: TextView
    private lateinit var tvLog: TextView
    private lateinit var tvBend: TextView
    private lateinit var tvVib: TextView
    private lateinit var spDevices: Spinner
    private lateinit var spLib: Spinner
    private lateinit var etName: EditText
    private lateinit var etMelody: EditText
    private lateinit var sbBend: SeekBar
    private lateinit var sbVib: SeekBar
    private lateinit var cbDelay: CheckBox
    private lateinit var cbStrict: CheckBox
    private lateinit var tvTempo: TextView
    private lateinit var sbTempo: SeekBar
    private lateinit var rgTone: RadioGroup

    private val logLines = ArrayDeque<String>()
    private val found = mutableListOf<BleTransport.Found>()
    private var deviceAdapter: ArrayAdapter<String>? = null
    private var libAdapter: ArrayAdapter<String>? = null

    /** 正在拖动 seekbar 时不要被板子回读覆盖。 */
    private var userEditingSlider = false

    /**
     * 当前**选中的槽位**（0..3）。
     *
     * ★ 2026-10-28 新增。此前「指引 / 自动演奏 / 停止」三个按钮
     *   没有"当前槽"的概念，实现里偷偷挑了"第一个就绪槽"，
     *   于是用户点槽4 却播槽1。
     *   现在槽1..槽4 四个按钮点击即**选中该槽**，其余播放按钮都用它。
     */
    private var selectedSlot: Int = 0

    private val permLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        val denied = result.filterValues { !it }.keys
        // ★ 2026-10-28：蓝牙权限与定位权限要分开看。
        //   BLUETOOTH_SCAN/CONNECT 是**必需**的；
        //   ACCESS_FINE_LOCATION 只是为了在华为/荣耀平板上把权限入口显示出来，
        //   缺了它标准 Android 照样能扫。所以不能因为用户拒了定位就整件事不做 ——
        //   那样普通安卓机上反而用不了。
        val coreDenied = denied.filter {
            it == android.Manifest.permission.BLUETOOTH_SCAN ||
                it == android.Manifest.permission.BLUETOOTH_CONNECT ||
                it == android.Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (coreDenied.isEmpty()) {
            log("权限已授予")
            doScan()
            return@registerForActivityResult
        }
        val scanDenied = coreDenied.any { it != android.Manifest.permission.ACCESS_FINE_LOCATION }
        if (!scanDenied) {
            // 只拒了定位：先尝试扫描（标准安卓上照样能用），
            // 同时告诉用户华为平板需要它来打开权限入口
            log(
                "定位权限未授予。标准安卓上不影响蓝牙扫描，先继续尝试；\n" +
                    "  若扫描仍为空且用的是华为/荣耀平板，请到" +
                    "「设置 → 应用 → FPGA 电子琴 → 权限」把『位置信息』打开。",
            )
            doScan()
        } else {
            log(
                "缺少蓝牙权限：$coreDenied\n" +
                    "  请到「设置 → 应用 → FPGA 电子琴 → 权限」手动打开" +
                    "『附近设备』和『位置信息』（华为/荣耀平板只显示『位置信息』时也一并打开）。",
            )
            toast(getString(R.string.perm_needed) + "：$coreDenied")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        AppState.init(this)

        bindViews()
        wireButtons()

        AppState.onChanged = { runOnUiThread { render() } }
        render()
        log("就绪。先「扫描」找到模块（E104 出厂名形如 E104-BT52-V2.0），连接后点「刷新状态」。")
    }

    private fun bindViews() {
        tvConnState = findViewById(R.id.tvConnState)
        tvBoard = findViewById(R.id.tvBoard)
        tvSlots = findViewById(R.id.tvSlots)
        tvRecInfo = findViewById(R.id.tvRecInfo)
        tvLog = findViewById(R.id.tvLog)
        tvBend = findViewById(R.id.tvBend)
        tvVib = findViewById(R.id.tvVib)
        spDevices = findViewById(R.id.spDevices)
        spLib = findViewById(R.id.spLib)
        etName = findViewById(R.id.etName)
        etMelody = findViewById(R.id.etMelody)
        sbBend = findViewById(R.id.sbBend)
        sbVib = findViewById(R.id.sbVib)
        cbDelay = findViewById(R.id.cbDelay)
        cbStrict = findViewById(R.id.cbStrict)
        tvTempo = findViewById(R.id.tvTempo)
        sbTempo = findViewById(R.id.sbTempo)
        rgTone = findViewById(R.id.rgTone)

        deviceAdapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, mutableListOf())
        spDevices.adapter = deviceAdapter

        // 变调滑块是 0..24 偏置编码，显示时减 12
        sbBend.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: SeekBar?, p: Int, fromUser: Boolean) {
                tvBend.text = getString(R.string.bend_fmt, p - BEND_OFFSET)
                if (fromUser) userEditingSlider = true
            }

            override fun onStartTrackingTouch(sb: SeekBar?) {
                userEditingSlider = true
            }

            override fun onStopTrackingTouch(sb: SeekBar?) {
                userEditingSlider = false
                sendBend()
            }
        })

        sbVib.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: SeekBar?, p: Int, fromUser: Boolean) {
                tvVib.text = getString(R.string.vib_fmt, p)
                if (fromUser) userEditingSlider = true
            }

            override fun onStartTrackingTouch(sb: SeekBar?) {
                userEditingSlider = true
            }

            override fun onStopTrackingTouch(sb: SeekBar?) {
                userEditingSlider = false
                AppState.setParam(SET_VIB, sbVib.progress)
            }
        })

        rgTone.setOnCheckedChangeListener { _, id ->
            val tone = when (id) {
                R.id.rbTone0 -> 0
                R.id.rbTone1 -> 1
                R.id.rbTone2 -> 2
                else -> 3
            }
            AppState.setParam(SET_TONE, tone)
        }

        cbDelay.setOnCheckedChangeListener { _, checked ->
            AppState.setParam(SET_DELAY, if (checked) 1 else 0)
        }

        // 2026-10-29: 严格节奏开关（SET param=5）。
        //   打开后 GUIDE 到拍就进、记 miss；配合曲谱里的休止(空帧)就严格跟节奏。
        cbStrict.setOnCheckedChangeListener { _, checked ->
            log("指引模式 -> " + if (checked) "严格跟节奏" else "等待按键")
            AppState.setParam(SET_STRICT, if (checked) 1 else 0)
        }

        // 2026-10-28 新增：节奏滑块（0..5 → 60/80/100/120/160/200 BPM）。
        //   拖动时只更新文字，**松手才发命令** —— 拖一次会连续触发几十次
        //   onProgressChanged，每次都发一帧会把串口打满（停等协议下还会互相超时）。
        sbTempo.setOnSeekBarChangeListener(object : android.widget.SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: android.widget.SeekBar?, p: Int, fromUser: Boolean) {
                val i = p.coerceIn(0, 5)
                tvTempo.text = getString(R.string.tempo_fmt, TEMPO_BPMS[i], i)
            }

            override fun onStartTrackingTouch(sb: android.widget.SeekBar?) {}

            override fun onStopTrackingTouch(sb: android.widget.SeekBar?) {
                val i = (sb?.progress ?: 3).coerceIn(0, 5)
                log("设置节奏 → ${TEMPO_BPMS[i]} BPM（档位 $i）")
                AppState.setTempo(i)
            }
        })
        tvTempo.text = getString(R.string.tempo_fmt, TEMPO_BPMS[TEMPO_DEFAULT], TEMPO_DEFAULT)

        refreshLibSpinner()
    }

    private fun wireButtons() {
        findViewById<Button>(R.id.btnScan).setOnClickListener { ensurePermissionsThenScan() }
        findViewById<Button>(R.id.btnConnect).setOnClickListener { connectSelected() }
        findViewById<Button>(R.id.btnDisconnect).setOnClickListener { disconnect() }
        findViewById<Button>(R.id.btnQuery).setOnClickListener {
            // ★ 必须走 Async：sendFrame 是阻塞的（轮询+重试最长约 2 秒），
            //   直接在 UI 线程调用会把界面卡死 —— 真机实测过这个现象。
            //   三个查询在同一个后台任务里串行做，所以这里只调一次。
            log("查询板子状态…")
            AppState.refreshStatusAsync()
        }
        findViewById<Button>(R.id.btnSync).setOnClickListener {
            log("开始同步曲单…")
            AppState.syncAsync()
        }
        findViewById<Button>(R.id.btnSyncFull).setOnClickListener {
            // 2026-10-28：同步按钮有两档
            //   「同步曲单」      —— 增量，指纹一致的槽跳过（快）
            //   「强制全量重传」  —— 无视记账，4 个槽全部重发（慢但绝对覆盖）
            //
            //   为什么必须有后者：一旦某次同步把**错误的曲谱**写进板子，
            //   App 的 boardState 就会记下那个错误曲谱的指纹。之后即使曲库
            //   改对了，指纹也只跟"本地曲库"比，与板内真实内容无关 ——
            //   只要本地没再变，就永远显示「已是最新」而不重发，
            //   错误内容就永久留在板子里。
            //   遇到「名字和听到的不是一首歌」时，点这个按钮强制覆盖。
            log("强制全量重传：4 个槽全部重新下发…")
            AppState.syncAsync(forceFull = true, forget = true)
        }

        // 2026-10-29 新增：清空槽位
        findViewById<Button>(R.id.btnClearSlot).setOnClickListener {
            log("清空槽${selectedSlot + 1}…")
            AppState.clearSlotAsync(selectedSlot)
        }
        findViewById<Button>(R.id.btnClearAll).setOnClickListener {
            log("清空全部 4 个槽位…")
            AppState.clearAllAsync()
        }

        // 播放：按钮 N 对应槽位 N-1。
        // 2026-10-28：点下去先**记录选中槽**再播，这样「指引 / 自动演奏」
        //   也跟着用同一个槽，不会各挑各的。
        findViewById<Button>(R.id.btnPlay1).setOnClickListener { selectAndPlay(0) }
        findViewById<Button>(R.id.btnPlay2).setOnClickListener { selectAndPlay(1) }
        findViewById<Button>(R.id.btnPlay3).setOnClickListener { selectAndPlay(2) }
        findViewById<Button>(R.id.btnPlay4).setOnClickListener { selectAndPlay(3) }

        findViewById<Button>(R.id.btnGuide).setOnClickListener {
            startPlayMode(MODE_GUIDE)
        }
        findViewById<Button>(R.id.btnAuto).setOnClickListener {
            startPlayMode(MODE_AUTO)
        }
        findViewById<Button>(R.id.btnStop).setOnClickListener {
            log("停止")
            AppState.setModeAsync(MODE_STOP, 0)
        }

        findViewById<Button>(R.id.btnReadParam).setOnClickListener {
            AppState.refreshParamAsync()
        }

        // 录音
        findViewById<Button>(R.id.btnRecStart).setOnClickListener {
            log("开始录音 —— 请在琴上弹奏")
            AppState.recStartAsync()
        }
        findViewById<Button>(R.id.btnRecStop).setOnClickListener {
            log("停止录音")
            AppState.recStopAsync()
        }
        findViewById<Button>(R.id.btnRecInfo).setOnClickListener { AppState.refreshRecInfoAsync() }
        findViewById<Button>(R.id.btnRecRead).setOnClickListener {
            log("回读录音音符…")
            AppState.recReadAsync()
        }
        findViewById<Button>(R.id.btnRecCommit).setOnClickListener {
            // 2026-10-29 按用户要求重定规则：
            //   优先找**空槽**；全满时**占槽1**（覆盖槽1 现有的曲子，不弹确认框）。
            //   不再出现「4 个槽都满了，存不了」这种死路 —— 录音总要有个落点。
            val slot = pickSlotForRecording()
            val oldName = AppState.playlistNames().getOrNull(slot)
            if (oldName != null) {
                log("录音写入槽${slot + 1}，将覆盖原有「$oldName」…")
            } else {
                log("录音写入槽${slot + 1}（空槽）…")
            }
            AppState.recCommitAsync(slot)
        }

        // 曲库
        findViewById<Button>(R.id.btnAddSong).setOnClickListener {
            val name = etName.text.toString().ifBlank { "未命名" }
            AppState.addSong(name, etMelody.text.toString())
            if (AppState.lastError == null) {
                log("已加入曲库：$name")
                etName.setText("")
            }
            refreshLibSpinner()
        }
        findViewById<Button>(R.id.btnDeleteSong).setOnClickListener {
            val e = selectedEntry()
            if (e == null) log("先在上面选一首曲子") else {
                AppState.removeSong(e.entryId)
                log("已删除：${e.name}")
                refreshLibSpinner()
            }
        }
        findViewById<Button>(R.id.btnSlotA).setOnClickListener { assignSlot(0) }
        findViewById<Button>(R.id.btnSlotB).setOnClickListener { assignSlot(1) }
        findViewById<Button>(R.id.btnSlotC).setOnClickListener { assignSlot(2) }
        findViewById<Button>(R.id.btnSlotD).setOnClickListener { assignSlot(3) }
    }

    // -----------------------------------------------------------------------
    // BLE
    // -----------------------------------------------------------------------

    private fun ensurePermissionsThenScan() {
        val t = AppState.ble ?: AppState.createTransport(this)
        val need = t.requiredPermissions().filter {
            checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        if (need.isNotEmpty()) {
            permLauncher.launch(need.toTypedArray())
            return
        }
        doScan()
    }

    /**
     * 给录音挑一个存放的槽位。
     *
     * 规则（2026-10-29 按用户要求）：
     *   1. **优先找一个空槽**（曲单里还没分配曲子的槽）
     *   2. 全满时**占槽1**（会覆盖槽1 现有的曲子）
     *   3. 绝不返回 -1 —— 录音总要有个落点，覆盖比"存不了"好
     *
     * 为什么全满时选槽1 而不是别处：用户明确说「都满时占槽一」。
     */
    private fun pickSlotForRecording(): Int {
        val names = AppState.playlistNames()
        for (s in 0 until 4) {
            if (names.getOrNull(s) == null) return s
        }
        return 0    // 全满 ⇒ 覆盖槽1
    }

    private fun doScan() {
        if (AppState.ble == null) {
            val t = AppState.createTransport(this)
            t.onState = { s, m -> runOnUiThread { onBleState(s, m) } }
        }
        val t = AppState.ble!!
        found.clear()
        deviceAdapter?.clear()
        deviceAdapter?.notifyDataSetChanged()

        // ★ 2026-10-28：扫描前先自检，把「扫不到设备」的原因直接说出来。
        //   平板上最常见的两条是：定位开关没开（安卓 11 及以下）、
        //   以及「附近设备」权限只给了「仅此一次」。不说清楚的话，
        //   用户只看到空列表，无从判断是自己没配对还是权限没给。
        val prereq = try {
            t.diagnoseScanPrereq()
        } catch (e: Exception) {
            e.message
        }
        if (prereq != null) {
            log("扫描前置条件不满足：$prereq")
            toast(prereq)
            return
        }
        // 把适配器状态一并打出来，便于定位"能扫但收不到"这类问题
        log(t.adapterDebugInfo())

        // 不过滤名字：早先只上报含 "FPGA_EPIANO" 的设备，
        //   一旦模块广播名不同（或名字还没进 scan response）就什么都看不到，
        //   而用户无法判断是「模块没广播」还是「名字不匹配」。
        //   现在全部列出，由用户在列表里自己选 —— 排查友好得多。
        log("开始扫描全部 BLE 设备…（模块出厂名形如 E104-BT52-V2.0，选它即可）")
        val scanStartMs = System.currentTimeMillis()
        t.startScan(null, onFound = { d ->
            runOnUiThread {
                if (found.none { it.address == d.address }) {
                    found.add(d)
                    deviceAdapter?.add(d.toString())
                    deviceAdapter?.notifyDataSetChanged()
                } else {
                    // 同名设备后续回调可能补上名字，刷新显示
                    val i = found.indexOfFirst { it.address == d.address }
                    if (i >= 0 && found[i].name == null && d.name != null) {
                        found[i] = d
                        deviceAdapter?.clear()
                        found.forEach { deviceAdapter?.add(it.toString()) }
                        deviceAdapter?.notifyDataSetChanged()
                    }
                }
            }
        }, onError = { msg ->
            runOnUiThread { log("扫描出错：$msg") }
        })

        // ★ 2026-10-28 新增：6 秒后仍然一个设备都没扫到，就主动给出排查提示。
        //   原来只有 startScan 失败（onError）才会说话，而「能扫、但结果为空」
        //   是完全静默的 —— 用户在平板上就只看到一个永远空着的列表。
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            if (found.isEmpty()) {
                // 区分两种失败：系统一个回调都没给 vs 回调来了但被我们扔掉
                val raw = AppState.ble?.rawCallbackCount ?: 0
                if (raw == 0) {
                    log(
                        "扫描 6 秒，系统**一个广播包都没上报**（原始回调 0 次）。\n" +
                            "  这不是 App 过滤造成的，是系统没收到任何 BLE 广播。请依次确认：\n" +
                            "  1) 模块是否上电且正在广播？（E104 掉电后 ADV 可能复位；" +
                            "在电脑上发 AT+ADV? 应为 +OK=1）\n" +
                            "  2) 模块是否已被手机/电脑连着？从机默认只接一个中心，" +
                            "**请先把手机 App 断开或关掉手机蓝牙**\n" +
                            "  3) 平板蓝牙是否正常？到系统设置里用平板自己的蓝牙搜索" +
                            "看看能否看到任意 BLE 设备（如手环、耳机）\n" +
                            "  4) 把平板贴到模块 10cm 内，2.4G WiFi 会干扰\n" +
                            "  5) 关掉再打开平板蓝牙，然后重扫",
                    )
                } else {
                    log(
                        "扫描 6 秒，系统上报了 $raw 个广播包，但列表仍为空。\n" +
                            "  说明**收到了数据但被显示逻辑挡掉了**，这属于 App 问题，" +
                            "请把这行日志发我。",
                    )
                }
            }
        }, 6000)
    }

    private fun connectSelected() {
        if (found.isEmpty()) {
            toast("请先扫描并选择一个设备")
            return
        }
        val idx = spDevices.selectedItemPosition.coerceIn(0, found.size - 1)
        val dev = found[idx]
        val t = AppState.ble ?: AppState.createTransport(this)
        t.onState = { s, m -> runOnUiThread { onBleState(s, m) } }
        t.onRawBytes = { /* 需要看原始流量时打开 */ }
        log("连接 ${dev.address} …")
        t.connect(dev.address)
    }

    private fun disconnect() {
        AppState.detachSession()
        AppState.ble?.close()
        log("已断开")
        render()
    }

    private fun onBleState(s: BleTransport.State, msg: String) {
        log("[$s] $msg")
        tvConnState.text = msg
        if (s == BleTransport.State.READY) {
            val t = AppState.ble!!
            AppState.attachSession(t)
            log("会话已建立，MTU=${t.mtu}（单次写载荷 ${t.maxWritePayload} 字节）")
            // 连上就先问一次状态，验证全链路。
            // ★ 走 Async：这里是 GATT 回调，虽不在主线程，但统一走后台队列
            //   可以保证「连接→查询」不会和用户手点的操作并发。
            log("自动查询板子状态…")
            AppState.refreshStatusAsync()
        }
        render()
    }

    // -----------------------------------------------------------------------
    // 曲库
    // -----------------------------------------------------------------------

    private fun refreshLibSpinner() {
        // 2026-10-27：曲目列表**只显示名字**，不再附加「（N音）」。
        //   原因：音符数是实现细节，混在名字里既占宽度又不便点选；
        //   而且复音改造后「音符数」的语义会变成「事件数」，届时这个后缀会误导。
        //   条数等信息改由下方的槽位区展示。
        val names = AppState.library.entries.values.map { it.name }
        libAdapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, names)
        spLib.adapter = libAdapter
    }

    private fun selectedEntry(): com.epiano.ble.library.Entry? {
        val ids = AppState.library.entries.keys.toList()
        val i = spLib.selectedItemPosition
        if (i < 0 || i >= ids.size) return null
        return AppState.library.entries[ids[i]]
    }

    private fun assignSlot(slot: Int) {
        val e = selectedEntry()
        if (e == null) {
            log("先在上面选一首曲子")
            return
        }
        val cur = AppState.library.playlist.toMutableList()
        cur[slot] = e.entryId
        // ★ 2026-10-28 修复「点某个槽，曲子会自己往下滑一格」：
        //   原来这里写的是 `cur.filterNotNull()` —— 它把**所有空槽都删掉**并把后面的
        //   曲子前移。于是把曲子放到槽 3 时，前面的空槽被压缩，它就滑到了槽 1/2。
        //   槽位是「用户明确指定的位置」，空槽也是位置，必须原样保留。
        //   正确做法：直接把完整 4 项（含 null）交给 setPlaylist，
        //   它自己负责对齐到 SONG_COUNT。
        AppState.setSlots(cur)
        log("槽${slot + 1} ← ${e.name}（点「同步曲单」才会真正下发）")
        render()
    }

    private fun sendBend() {
        // SeekBar 的 0..24 就是协议本身的偏置编码：
        // RTL 用无符号 0..24 表示 -12..+12，避免手机端写补码出错。
        val bias = sbBend.progress.coerceIn(0, 24)
        AppState.setParam(1, bias)
        log("变调 → ${bias - BEND_OFFSET} 半音")
    }

    /**
     * 启动 GUIDE / AUTO。
     *
     * ★ 2026-10-28 修复「点自动演奏就报错」：
     *
     * RTL 的 `C_MODE`（`bt_link.v:318`）要求目标槽 **ready**：
     * ```verilog
     * else if(!ready_mask[pbuf[1][1:0]]) begin act_result<=3; ...
     * ```
     * 而 `ready_mask` 冷启动只有 bit0（出厂内置曲）。
     * 旧代码用 [currentSlotOr] 取「曲单里第一个被填的槽」——
     * 用户把自己加的曲子塞进槽 1/2/3、又没点过「同步曲单」时，
     * 那些槽在板子上**根本不存在** ⇒ 板子回 `result=3` ⇒ 界面上就是报错。
     *
     * 现在的做法：
     *   1. 优先选**板子确认就绪**的槽（以最近一次 STATUS 为准）；
     *   2. 若一个都没有，明确告诉用户「先同步」，**不要盲发**；
     *   3. 若选中的槽在曲单里有名字，日志里带上名字，便于对照。
     *
     * 这样报错从「一句看不懂的 result=3」变成「请先同步曲单」。
     */

    /** 选中某个槽并直接播放它（点槽N 按钮）。 */
    private fun selectAndPlay(slot: Int) {
        selectedSlot = slot
        val name = AppState.playlistNames().getOrNull(slot)
        log("选中槽${slot + 1}" + if (name != null) "（$name）" else "（空槽）")
        AppState.playAsync(slot)
    }

    /**
     * 启动 GUIDE / AUTO。
     *
     * ★ 2026-10-28 **重写**：原来这里会自动挑「第一个有名字的就绪槽」，
     *   完全无视用户选的槽 —— 于是「点槽4，播的却是槽1」。
     *   那是我上一轮为了"避免点了空槽报错"引进来的，方向错了：
     *   用户点哪个槽就该播哪个槽，选错了要**明确告诉他**，而不是偷偷换成别的。
     *
     * 现在的行为：
     *   1. 用界面上当前选中的槽（[selectedSlot]）
     *   2. 若该槽在板子上未就绪 ⇒ 明确提示「槽N 还没有曲子，请先同步」
     *   3. 若板子状态未知 ⇒ 提示先刷新状态
     *   绝不替用户改槽。
     */
    private fun startPlayMode(mode: Int) {
        val what = if (mode == MODE_GUIDE) "LED 指引" else "自动演奏"
        val st = AppState.lastStatus

        if (st == null) {
            log("先点「刷新状态」确认板子状态，再开始$what（否则无法判断哪个槽有曲子）")
            return
        }

        val slot = selectedSlot
        if (!st.ready(slot)) {
            val name = AppState.playlistNames().getOrNull(slot)
            log(
                "槽${slot + 1} 在板子上还没有曲子，无法$what。" +
                    if (name != null) {
                        "请点「同步曲单」把「$name」下发到槽${slot + 1}。"
                    } else {
                        "请先把一首曲子分配到槽${slot + 1}，再同步。"
                    },
            )
            return
        }
        val name = AppState.playlistNames().getOrNull(slot) ?: "（板内原有内容）"
        log("开始$what：槽${slot + 1}（$name）")
        AppState.setModeAsync(mode, slot)
    }

    // -----------------------------------------------------------------------
    // 渲染
    // -----------------------------------------------------------------------

    private fun render() {
        // 操作进行中：按钮置灰，避免重入（BLE 会话是串行的）
        val enabled = !AppState.busy
        for (id in intArrayOf(
            R.id.btnQuery, R.id.btnSync, R.id.btnSyncFull,
            R.id.btnClearSlot, R.id.btnClearAll,
            R.id.btnPlay1, R.id.btnPlay2, R.id.btnPlay3, R.id.btnPlay4,
            R.id.btnGuide, R.id.btnAuto, R.id.btnStop,
            R.id.btnReadParam, R.id.btnRecStart, R.id.btnRecStop,
            R.id.btnRecInfo, R.id.btnRecRead, R.id.btnRecCommit,
        )) {
            findViewById<Button>(id)?.isEnabled = enabled
        }
        if (AppState.busy) {
            tvConnState.text = "⏳ 正在与板子通信…"
        }

        val st = AppState.lastStatus
        if (st == null) {
            tvBoard.text = "板子状态：—（未连接或未查询）"
            tvSlots.text = "槽位：—"
        } else {
            // 复用与板载屏幕完全相同的 9 字符口径，方便与实物对拍
            tvBoard.text = buildString {
                append("板子屏幕同款状态： ")
                append(btDisplayString(st))
                append("\nstate=").append(st.state)
                append("  当前槽=").append(st.song + 1)
                append("  done=").append(st.done)
                append("  ready=0b").append(Integer.toBinaryString(st.readyMask).padStart(4, '0'))
            }
            val sb = StringBuilder("槽位：")
            for (i in 0 until 4) {
                val name = AppState.playlistNames().getOrNull(i) ?: "空"
                sb.append("\n  ")
                // 2026-10-29：标出当前选中的槽 —— 「指引/自动演奏/清空当前槽」
                //   都作用在它上面，不标出来用户不知道在操作哪一个。
                sb.append(if (i == selectedSlot) "▶" else "  ")
                sb.append("槽${i + 1} ")
                sb.append(if (st.ready(i)) "✔就绪" else "✘无曲")
                sb.append("  ").append(name)
            }
            tvSlots.text = sb.toString()
        }

        AppState.lastParam?.let { p ->
            if (!userEditingSlider) {
                sbBend.progress = p.bend.coerceIn(0, 24)
                sbVib.progress = p.vib.coerceIn(0, 3)
                tvBend.text = getString(R.string.bend_fmt, p.bendSemitones)
                tvVib.text = getString(R.string.vib_fmt, p.vib)
                cbDelay.isChecked = p.delay != 0
                // 2026-10-28：节奏也按板子回报的值刷新滑块
                AppState.lastTempo?.let { t ->
                    val i = t.index.coerceIn(0, 5)
                    sbTempo.progress = i
                    tvTempo.text = getString(R.string.tempo_fmt, t.bpm, i)
                }
                when (p.tone) {
                    0 -> rgTone.check(R.id.rbTone0)
                    1 -> rgTone.check(R.id.rbTone1)
                    2 -> rgTone.check(R.id.rbTone2)
                    else -> rgTone.check(R.id.rbTone3)
                }
            }
        }

        AppState.lastRecInfo?.let { r ->
            tvRecInfo.text = buildString {
                append("录音：")
                append(if (r.busy) "进行中" else if (r.ready) "已录完可保存" else "空闲")
                append("   字节=").append(r.bytes)
                append("  音符=").append(r.notes)
                if (r.full) append("  （录音区已满，已自动停止）")
            }
        }

        // 同步结果（异步跑完后在这里呈现）
        val rep = AppState.lastSyncReport
        if (rep != null && rep !== lastShownSyncReport) {
            lastShownSyncReport = rep
            log(rep.describe())
        }

        // 回读到的录音音符（只显示一次，避免每帧刷新重复刷屏）
        if (AppState.lastRecNotes.isNotEmpty() && recNotesShown != AppState.lastRecNotes.size) {
            recNotesShown = AppState.lastRecNotes.size
            val n = AppState.lastRecNotes
            // 只回读音符事件，绝不涉及音频（赛题严禁预录 PCM）
            log("回读到 ${n.size} 个音符事件：" + n.take(24).joinToString(" ") { it.name })
            if (n.size > 24) log("…（共 ${n.size} 个，此处只显示前 24 个）")
        }

        AppState.lastError?.let { err ->
            log("⚠ $err")
            // ★ 失败时把通道计数一并打出来，这是区分两类问题的关键证据：
            //   TX=0  → 写根本没提交出去（GATT 层问题 / 特征不可写）
            //   TX>0 且 RX=0 → 写提交了但模块/板子没有任何回应（UART 或透传模式问题）
            //   RX>0 但解析失败 → 收到字节了，是协议/CRC 问题
            log("   通道诊断：${AppState.linkStats()}")
            AppState.lastError = null
        }

        tvLog.text = logLines.joinToString("\n")
    }

    /** 避免同一份同步报告被重复打印。 */
    private var lastShownSyncReport: Any? = null
    private var recNotesShown = 0

    private fun log(msg: String) {
        val ts = "%02d:%02d:%02d".format(
            (System.currentTimeMillis() / 1000 % 86400) / 3600,
            (System.currentTimeMillis() / 1000 % 3600) / 60,
            System.currentTimeMillis() / 1000 % 60,
        )
        logLines.addLast("$ts  $msg")
        while (logLines.size > 300) logLines.removeFirst()
        tvLog.text = logLines.joinToString("\n")
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    override fun onDestroy() {
        super.onDestroy()
        AppState.onChanged = null
        AppState.ble?.close()
    }
}
