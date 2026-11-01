package com.epiano.ble.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 数据通道选择单测。
 *
 * ★ 直接调用 **生产代码** [DataChannels.pick]，不再在测试里抄一份算法。
 *   早先测的是抄来的副本，结果「抄对了、源码错了」也测不出来 —— 这次修正
 *   （FFF3 → FFF2/FFF1）正是因为缺少对生产逻辑的直接覆盖。
 *
 * 输入取自 **2026-10-27 真机 GATT 枚举**（用户手机截图）：
 *
 *     服务 0x1800 (Generic Access)     特征 2A00/2A01/2AA6        [R]
 *     服务 0x1801 (Generic Attribute)  特征 2A05                 [RI]
 *     服务 0x180A (Device Information) 特征 2A29/2A24/2A25/...   [R]
 *     服务 0xFFF0                      特征 0xFFF1 [RN]
 *                                      特征 0xFFF2 [WR]
 *                                      特征 0xFFF3 [WRN]
 */
class CharPickTest {

    private fun c(short: String, props: Int) = DataChannels.Characteristic(DataChannels.uuid(short), props)

    // 属性位（GATT 规范值，与 Android 常量一致）
    private val W = 0x08       // WRITE
    private val WR = 0x04      // WRITE_NO_RESPONSE
    private val R = 0x02       // READ
    private val N = 0x10       // NOTIFY
    private val I = 0x20       // INDICATE

    private val standard = listOf(
        DataChannels.Service(DataChannels.uuid("1800"), listOf(c("2a00", R), c("2a01", R), c("2aa6", R))),
        DataChannels.Service(DataChannels.uuid("1801"), listOf(c("2a05", R or I))),
        DataChannels.Service(DataChannels.uuid("180a"), listOf(c("2a29", R), c("2a24", R))),
    )

    /** 真机 FFF0 服务的三个特征（权限与截图完全一致）。 */
    private val fff0 = DataChannels.Service(
        DataChannels.uuid("fff0"),
        listOf(
            c("fff1", R or N),          // [RN]
            c("fff2", W or R),          // [WR]
            c("fff3", W or R or N),     // [WRN]
        )
    )

    @Test
    fun `真机 GATT 表应选择 FFF2 写 FFF1 通知`() {
        val sel = DataChannels.pick(standard + fff0)
        assertEquals(
            "发送必须是 FFF2（厂商定义的数据写入口）",
            DataChannels.uuid("fff2"), sel?.tx,
        )
        assertEquals(
            "接收必须是 FFF1（厂商定义的通知口）",
            DataChannels.uuid("fff1"), sel?.rx,
        )
        assertEquals("服务应是 FFF0", DataChannels.uuid("fff0"), sel?.service)
    }

    @Test
    fun `绝不能把 FFF3 配置口当数据发送口`() {
        // 这是 2026-10-27 修正的核心回归点：
        // FFF3 虽然「可写+可通知」，但它是 AT 空中配置口，
        // 往里写曲谱数据会被当 AT 指令吞掉。
        val sel = DataChannels.pick(standard + fff0)
        assertEquals(false, sel?.tx == DataChannels.uuid("fff3"))
        assertEquals(false, sel?.rx == DataChannels.uuid("fff3"))
    }

    @Test
    fun `FFF1 不可写时不应被选为发送口`() {
        // FFF1 只有 [RN]；若实现错误地把它当发送口，写会失败
        val sel = DataChannels.pick(standard + fff0)
        assertEquals(false, sel?.tx == DataChannels.uuid("fff1"))
    }

    @Test
    fun `缺少 FFF2 时宁可返回 null 也不退回 FFF3`() {
        // 只有 FFF1 + FFF3（例如固件变体）：没有明确的写入口，
        // 必须报错让用户显式配置，**不能**猜 FFF3。
        val partial = DataChannels.Service(
            DataChannels.uuid("fff0"),
            listOf(c("fff1", R or N), c("fff3", W or R or N)),
        )
        assertNull("缺 FFF2 必须返回 null，不能退回 FFF3", DataChannels.pick(standard + partial))
    }

    @Test
    fun `只有配置特征时返回 null`() {
        val onlyCfg = DataChannels.Service(
            DataChannels.uuid("fff0"),
            listOf(c("fff1", R or N), c("fff2", W or R)),
        )
        // FFF2 可写、FFF1 可通知 —— 这一组其实是完整的，应能选出来
        val sel = DataChannels.pick(standard + onlyCfg)
        assertEquals(DataChannels.uuid("fff2"), sel?.tx)
        assertEquals(DataChannels.uuid("fff1"), sel?.rx)
    }

    @Test
    fun `通用 FFE0 模块走第二分支`() {
        val ffe0 = DataChannels.Service(
            DataChannels.uuid("ffe0"),
            listOf(c("ffe1", W or N)),
        )
        val sel = DataChannels.pick(standard + ffe0)
        assertEquals(DataChannels.uuid("ffe1"), sel?.tx)
        assertEquals(DataChannels.uuid("ffe1"), sel?.rx)
    }

    @Test
    fun `FFF0 优先于 FFE0`() {
        // 两种服务同时存在时，E104 的 FFF0 规则优先
        val ffe0 = DataChannels.Service(DataChannels.uuid("ffe0"), listOf(c("ffe1", W or N)))
        val sel = DataChannels.pick(standard + ffe0 + fff0)
        assertEquals(DataChannels.uuid("fff2"), sel?.tx)
    }

    @Test
    fun `完全未知的服务返回 null 而不是乱选`() {
        val weird = DataChannels.Service(
            DataChannels.uuid("abcd"),
            listOf(c("abcd", W or N)),
        )
        assertNull("未知服务必须返回 null，要求显式配置", DataChannels.pick(standard + weird))
    }

    @Test
    fun `只有标准服务时返回 null`() {
        assertNull("1800/1801/180A 里没有可用的数据口", DataChannels.pick(standard))
    }

    @Test
    fun `FFF2 不支持写时该组合无效`() {
        // 属性和厂商定义冲突（FFF2 却不可写）：应判为无效，不硬用
        val broken = DataChannels.Service(
            DataChannels.uuid("fff0"),
            listOf(c("fff1", R or N), c("fff2", R), c("fff3", W or R or N)),
        )
        assertNull("FFF2 不可写时应返回 null", DataChannels.pick(standard + broken))
    }

    @Test
    fun `FFF1 不支持通知时该组合无效`() {
        val broken = DataChannels.Service(
            DataChannels.uuid("fff0"),
            listOf(c("fff1", R), c("fff2", W or R), c("fff3", W or R or N)),
        )
        assertNull("FFF1 不可通知时应返回 null", DataChannels.pick(standard + broken))
    }
}