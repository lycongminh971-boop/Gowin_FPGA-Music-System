package com.epiano.ble.library

/**
 * 一个最小、无依赖的 JSON 读写器。
 *
 * **为什么不用 `org.json`：** 它在 Android 真机上能用，但在纯 JVM 单测里
 * `android.jar` 提供的是会抛 `RuntimeException("Stub!")` 的桩类，
 * 于是「持久化」这条路径**在单测里根本跑不到**。而持久化正是曲库记账的
 * 唯一落点（板子不会报告自己装了哪几首，全靠手机记账），
 * 测不到就等于没有保障。自带一个实现，真机与 JVM 行为完全一致。
 *
 * 只覆盖本工程用到的 JSON 子集：对象、数组、字符串、数字、bool、null。
 * 不追求完整规范（不支持 \u 代理对之外的转义细节、不做流式解析），
 * 但**解析失败会抛异常而不是返回 null**，避免静默丢数据。
 */
sealed interface JsonValue {
    data class Obj(val map: LinkedHashMap<String, JsonValue>) : JsonValue
    data class Arr(val items: List<JsonValue>) : JsonValue
    data class Str(val value: String) : JsonValue
    data class Num(val value: Long) : JsonValue
    data class Bool(val value: Boolean) : JsonValue
    data object Null : JsonValue

    // --- 便捷读取：缺字段返回默认值，类型不符也返回默认值（宽容读，严格写）---

    fun num(key: String, def: Long = 0L): Long = ((this as? Obj)?.map?.get(key) as? Num)?.value ?: def
    fun str(key: String): String? = ((this as? Obj)?.map?.get(key) as? Str)?.value
    fun bool(key: String, def: Boolean = false): Boolean =
        ((this as? Obj)?.map?.get(key) as? Bool)?.value ?: def

    fun has(key: String): Boolean = (this as? Obj)?.map?.containsKey(key) == true
    fun arr(key: String): Arr = ((this as? Obj)?.map?.get(key) as? Arr) ?: Arr(emptyList())

    /** 数组里第 i 个元素的字符串值；元素是 null 或是别的类型时返回 null。 */
    fun stringAt(i: Int): String? = ((this as? Arr)?.items?.getOrNull(i) as? Str)?.value
}

/** 数组元素的读取辅助。 */
val JsonValue.Arr.size: Int get() = items.size

val JsonValue.Arr.nums: List<Long>
    get() = items.map { (it as? JsonValue.Num)?.value ?: 0L }

fun JsonValue.Arr.strings(): List<String> =
    items.mapNotNull { (it as? JsonValue.Str)?.value }

fun JsonValue.Arr.objects(): List<JsonValue.Obj> =
    items.mapNotNull { it as? JsonValue.Obj }

object Json {

    // -----------------------------------------------------------------------
    // 写
    // -----------------------------------------------------------------------

    fun write(v: JsonValue): String = StringBuilder().also { writeTo(v, it) }.toString()

    private fun writeTo(v: JsonValue, sb: StringBuilder) {
        when (v) {
            is JsonValue.Obj -> {
                sb.append('{')
                var first = true
                for ((k, value) in v.map) {
                    if (!first) sb.append(',')
                    first = false
                    writeString(k, sb)
                    sb.append(':')
                    writeTo(value, sb)
                }
                sb.append('}')
            }

            is JsonValue.Arr -> {
                sb.append('[')
                v.items.forEachIndexed { i, item ->
                    if (i > 0) sb.append(',')
                    writeTo(item, sb)
                }
                sb.append(']')
            }

            is JsonValue.Str -> writeString(v.value, sb)
            is JsonValue.Num -> sb.append(v.value.toString())
            is JsonValue.Bool -> sb.append(if (v.value) "true" else "false")
            JsonValue.Null -> sb.append("null")
        }
    }

    private fun writeString(s: String, sb: StringBuilder) {
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
            }
        }
        sb.append('"')
    }

    // -----------------------------------------------------------------------
    // 读
    // -----------------------------------------------------------------------

    /** 解析 JSON 文本。失败抛 [LibraryException]（不返回 null，避免静默丢数据）。 */
    fun parse(text: String): JsonValue {
        val p = Parser(text)
        p.skipWs()
        val v = p.parseValue()
        p.skipWs()
        if (!p.atEnd()) throw LibraryException("JSON 尾部有多余内容（位置 ${p.pos}）")
        return v
    }

    private class Parser(private val s: String) {
        var pos = 0

        fun atEnd(): Boolean = pos >= s.length

        fun skipWs() {
            while (pos < s.length && s[pos].isWhitespace()) pos++
        }

        fun parseValue(): JsonValue {
            skipWs()
            if (atEnd()) throw LibraryException("JSON 意外结束")
            return when (s[pos]) {
                '{' -> parseObj()
                '[' -> parseArr()
                '"' -> JsonValue.Str(parseString())
                't' -> {
                    expect("true"); JsonValue.Bool(true)
                }

                'f' -> {
                    expect("false"); JsonValue.Bool(false)
                }

                'n' -> {
                    expect("null"); JsonValue.Null
                }

                else -> parseNum()
            }
        }

        private fun expect(word: String) {
            if (!s.startsWith(word, pos)) {
                throw LibraryException("JSON 位置 $pos 期望「$word」")
            }
            pos += word.length
        }

        private fun parseObj(): JsonValue.Obj {
            pos++                       // '{'
            val map = LinkedHashMap<String, JsonValue>()
            skipWs()
            if (pos < s.length && s[pos] == '}') {
                pos++; return JsonValue.Obj(map)
            }
            while (true) {
                skipWs()
                val k = parseString()
                skipWs()
                if (atEnd() || s[pos] != ':') throw LibraryException("JSON 位置 $pos 期望 ':'")
                pos++
                map[k] = parseValue()
                skipWs()
                if (atEnd()) throw LibraryException("JSON 对象未闭合")
                when (s[pos]) {
                    ',' -> pos++
                    '}' -> {
                        pos++; return JsonValue.Obj(map)
                    }

                    else -> throw LibraryException("JSON 位置 $pos 期望 ',' 或 '}'")
                }
            }
        }

        private fun parseArr(): JsonValue.Arr {
            pos++                       // '['
            val items = mutableListOf<JsonValue>()
            skipWs()
            if (pos < s.length && s[pos] == ']') {
                pos++; return JsonValue.Arr(items)
            }
            while (true) {
                items.add(parseValue())
                skipWs()
                if (atEnd()) throw LibraryException("JSON 数组未闭合")
                when (s[pos]) {
                    ',' -> pos++
                    ']' -> {
                        pos++; return JsonValue.Arr(items)
                    }

                    else -> throw LibraryException("JSON 位置 $pos 期望 ',' 或 ']'")
                }
            }
        }

        private fun parseString(): String {
            if (atEnd() || s[pos] != '"') throw LibraryException("JSON 位置 $pos 期望字符串")
            pos++
            val sb = StringBuilder()
            while (true) {
                if (atEnd()) throw LibraryException("JSON 字符串未闭合")
                when (val c = s[pos]) {
                    '"' -> {
                        pos++; return sb.toString()
                    }

                    '\\' -> {
                        pos++
                        if (atEnd()) throw LibraryException("JSON 转义未完成")
                        when (val e = s[pos]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                if (pos + 4 >= s.length) throw LibraryException("JSON \\u 转义不完整")
                                val hex = s.substring(pos + 1, pos + 5)
                                sb.append(hex.toInt(16).toChar())
                                pos += 4
                            }

                            else -> throw LibraryException("未知 JSON 转义 \\$e")
                        }
                        pos++
                    }

                    else -> {
                        sb.append(c); pos++
                    }
                }
            }
        }

        private fun parseNum(): JsonValue.Num {
            val start = pos
            if (pos < s.length && (s[pos] == '-' || s[pos] == '+')) pos++
            while (pos < s.length && (s[pos].isDigit() || s[pos] == '.' || s[pos] == 'e' || s[pos] == 'E' ||
                        ((s[pos] == '-' || s[pos] == '+') && pos > start))
            ) pos++
            val tok = s.substring(start, pos)
            if (tok.isEmpty()) throw LibraryException("JSON 位置 $start 不是合法值")
            // 本工程只写整数；遇到小数就截断（不会出现，纯防御）
            val v = tok.toDoubleOrNull()?.toLong()
                ?: throw LibraryException("JSON 数字无法解析：$tok")
            return JsonValue.Num(v)
        }
    }
}