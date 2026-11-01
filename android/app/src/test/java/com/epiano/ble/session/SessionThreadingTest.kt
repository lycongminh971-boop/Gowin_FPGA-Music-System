package com.epiano.ble.session

import com.epiano.ble.library.Library
import com.epiano.ble.library.parseMelody
import com.epiano.ble.protocol.SOF_IN
import com.epiano.ble.protocol.crc16
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * 会话/线程模型单测。
 *
 * 背景（2026-10-27 真机）：点「刷新状态」界面卡死。
 * 根因是 `Session.sendFrame` **阻塞**（轮询 + 重试，最坏约 2 秒），
 * 而 UI 直接在按钮回调里调用它 ⇒ 卡住主线程。
 * 修法是所有会话操作走后台单线程队列。
 *
 * 这里验证修法的两个关键性质。
 */
class SessionThreadingTest {

    /** 只会回 ACK 的最小假板子。 */
    private fun ackFor(cmd: Int): ByteArray {
        val body = byteArrayOf(2, 0x81.toByte(), cmd.toByte(), 0)
        val c = crc16(body)
        return byteArrayOf(0x5A, 2, 0x81.toByte(), cmd.toByte(), 0, (c and 0xFF).toByte(), ((c shr 8) and 0xFF).toByte())
    }

    /**
     * `sendFrame` 在无回帧时会把超时**乘上重试次数**，所以单次调用可能阻塞很久。
     * 这条用真实计时验证「它确实是阻塞的」—— 也就是「必须放后台线程」的理由。
     */
    @Test
    fun `无回帧时 sendFrame 会阻塞 且时长约等于 超时乘重试`() {
        val transport = object : Transport {
            override fun write(data: ByteArray) { /* 全吞，永不回帧 */ }
            override fun read(): ByteArray = ByteArray(0)
        }
        val s = Session(
            transport = transport,
            lib = Library(),
            ackTimeout = 0.05,      // 缩短以便测试快跑
            maxRetries = 2,         // 1 次首发 + 2 次重试 = 3 轮
        )
        val t0 = System.nanoTime()
        try {
            s.sendFrame(byteArrayOf(SOF_IN.toByte(), 0, 6))
        } catch (_: SessionError) {
        }
        val elapsedMs = (System.nanoTime() - t0) / 1_000_000
        // 3 轮 × 50ms ≈ 150ms；放宽下界避免机器慢导致假红
        assertTrue(
            "sendFrame 应阻塞约 150ms（实测 ${elapsedMs}ms）—— 这就是不能放 UI 线程的原因",
            elapsedMs >= 100,
        )
    }

    /**
     * 模拟 AppState.runAsync 的单线程队列语义：
     * 并发提交多个任务时，它们必须**串行**执行（BLE 是停等协议，
     * 并发发帧会让 ACK 与 seq 的对应关系错乱）。
     */
    @Test
    fun `会话操作必须串行执行`() {
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        val concurrent = AtomicInteger(0)
        val maxConcurrent = AtomicInteger(0)
        val done = CountDownLatch(5)

        repeat(5) { i ->
            executor.execute {
                val now = concurrent.incrementAndGet()
                maxConcurrent.updateAndGet { m -> maxOf(m, now) }
                Thread.sleep(20)
                concurrent.decrementAndGet()
                done.countDown()
            }
        }
        assertTrue("任务应在 2 秒内全部完成", done.await(2, TimeUnit.SECONDS))
        assertEquals("单线程队列的并发度必须是 1", 1, maxConcurrent.get())
        executor.shutdown()
    }

    /**
     * 复刻 `AppState.runAsync` 的**防重入**语义并证明它的副作用：
     * 连续提交多个任务时，后提交的会被忽略（busy=true）。
     *
     * ★ 这正是我在修 UI 时发现的第二个 bug：
     *   原先「刷新状态」按钮连调三个 `xxxAsync()`，
     *   结果只有第一个真的执行，参数与录音状态**永远是旧的**。
     *   修法是把三次查询合并进同一个任务。
     */
    @Test
    fun `防重入会把后续任务丢掉 所以多个查询必须合并成一个任务`() {
        // ★ 必须用**真异步**模拟：AppState.runAsync 是「立刻置 busy，
        //   把任务丢给后台线程」。如果测试里同步执行 block，
        //   busy 在每次返回前就清掉了，三次调用都会被接受 —— 测不出问题。
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        val busy = AtomicBoolean(false)
        val executed = AtomicInteger(0)

        val submit: (() -> Unit) -> Boolean = { block ->
            if (busy.get()) {
                false                  // 被忽略 —— 与 AppState.runAsync 一致
            } else {
                busy.set(true)
                executor.execute {
                    try {
                        block()
                    } finally {
                        busy.set(false)
                    }
                }
                true
            }
        }

        // 错误做法：连调三次（不等前一个完成）→ 只有第一次被接受
        val accepted = (1..3).map {
            submit { Thread.sleep(30); executed.incrementAndGet() }
        }
        assertEquals("只有第一次应被接受", 1, accepted.count { it })
        // 等后台任务跑完，确认另两次确实没执行
        Thread.sleep(200)
        assertEquals("只应执行 1 次（另两次被防重入丢掉）", 1, executed.get())

        // 正确做法：合并成一个任务 → 三次查询都真的做了
        executed.set(0)
        submit {
            repeat(3) { Thread.sleep(5); executed.incrementAndGet() }
        }
        Thread.sleep(300)
        assertEquals("合并后三次查询都应执行", 3, executed.get())
        executor.shutdown()
    }

    /** 校验假板子的 ACK 构造正确（自检，避免测试本身写错）。 */
    @Test
    fun `假 ACK 帧能通过协议层校验`() {
        val frame = ackFor(0x06)
        val parsed = com.epiano.ble.protocol.parseReply(frame)
        assertTrue(parsed is com.epiano.ble.protocol.Ack)
        assertEquals(0x06, (parsed as com.epiano.ble.protocol.Ack).cmd)
    }

    /** 真实场景下的参数读取不应抛异常。 */
    @Test
    fun `正常回帧时 query 能拿到 STATUS`() {
        val transport = object : Transport {
            private var out = ByteArray(0)
            override fun write(data: ByteArray) {
                // 回一条 STATUS：state=0 song=0 done=0 ready=0b0001
                val payload = byteArrayOf(0, 0, 0, 0, 0b0001)
                val body = byteArrayOf(payload.size.toByte(), 0x82.toByte()) + payload
                val c = crc16(body)
                out = byteArrayOf(0x5A) + body +
                    byteArrayOf((c and 0xFF).toByte(), ((c shr 8) and 0xFF).toByte())
            }

            override fun read(): ByteArray {
                val a = out; out = ByteArray(0); return a
            }
        }
        val s = Session(transport, Library(), ackTimeout = 1.0, maxRetries = 1,
            sleep = { }, now = run {
                var t = 0.0
                { t += 0.001; t }
            })
        val st = s.query()
        assertTrue("内置槽 0 应就绪", st.ready(0))
    }
}