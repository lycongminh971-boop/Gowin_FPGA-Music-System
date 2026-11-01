from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import sys
import time

GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)


class DCB(ctypes.Structure):
    _fields_ = [
        ("DCBlength", wt.DWORD), ("BaudRate", wt.DWORD),
        ("fBinary", wt.DWORD, 1), ("fParity", wt.DWORD, 1),
        ("fOutxCtsFlow", wt.DWORD, 1), ("fOutxDsrFlow", wt.DWORD, 1),
        ("fDtrControl", wt.DWORD, 2), ("fDsrSensitivity", wt.DWORD, 1),
        ("fTXContinueOnXoff", wt.DWORD, 1), ("fOutX", wt.DWORD, 1),
        ("fInX", wt.DWORD, 1), ("fErrorChar", wt.DWORD, 1),
        ("fNull", wt.DWORD, 1), ("fRtsControl", wt.DWORD, 2),
        ("fAbortOnError", wt.DWORD, 1), ("fDummy2", wt.DWORD, 17),
        ("wReserved", wt.WORD), ("XonLim", wt.WORD), ("XoffLim", wt.WORD),
        ("ByteSize", wt.BYTE), ("Parity", wt.BYTE), ("StopBits", wt.BYTE),
        ("XonChar", ctypes.c_char), ("XoffChar", ctypes.c_char),
        ("ErrorChar", ctypes.c_char), ("EofChar", ctypes.c_char),
        ("EvtChar", ctypes.c_char), ("wReserved1", wt.WORD),
    ]


class COMMTIMEOUTS(ctypes.Structure):
    _fields_ = [
        ("ReadIntervalTimeout", wt.DWORD), ("ReadTotalTimeoutMultiplier", wt.DWORD),
        ("ReadTotalTimeoutConstant", wt.DWORD), ("WriteTotalTimeoutMultiplier", wt.DWORD),
        ("WriteTotalTimeoutConstant", wt.DWORD),
    ]


def open_port(name: str, baud: int = 115200):
    path = f"\\\\.\\{name}"
    h = kernel32.CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, None,
                             OPEN_EXISTING, 0, None)
    if h == INVALID_HANDLE_VALUE:
        err = ctypes.get_last_error()
        raise OSError(f"打不开 {name}（Win32 错误 {err}）。"
                      f"常见原因：端口被 XCOM 等串口助手占用 —— 先关掉那些软件。")

    dcb = DCB()
    dcb.DCBlength = ctypes.sizeof(DCB)
    if not kernel32.GetCommState(h, ctypes.byref(dcb)):
        kernel32.CloseHandle(h)
        raise OSError(f"GetCommState 失败（{name}）")

    dcb.BaudRate = baud
    dcb.ByteSize = 8
    dcb.Parity = 0        # NOPARITY
    dcb.StopBits = 0      # ONESTOPBIT
    dcb.fBinary = 1
    dcb.fParity = 0
    dcb.fOutxCtsFlow = 0
    dcb.fOutxDsrFlow = 0
    dcb.fDtrControl = 1   # DTR_CONTROL_ENABLE
    dcb.fDsrSensitivity = 0
    dcb.fOutX = 0
    dcb.fInX = 0
    dcb.fRtsControl = 1   # RTS_CONTROL_ENABLE
    dcb.fAbortOnError = 0
    if not kernel32.SetCommState(h, ctypes.byref(dcb)):
        kernel32.CloseHandle(h)
        raise OSError(f"SetCommState 失败（{name}，波特率 {baud}）")

    to = COMMTIMEOUTS()
    to.ReadIntervalTimeout = 100
    to.ReadTotalTimeoutMultiplier = 0
    to.ReadTotalTimeoutConstant = 300
    to.WriteTotalTimeoutMultiplier = 0
    to.WriteTotalTimeoutConstant = 500
    if not kernel32.SetCommTimeouts(h, ctypes.byref(to)):
        kernel32.CloseHandle(h)
        raise OSError("SetCommTimeouts 失败")

    kernel32.PurgeComm(h, 0x0008 | 0x0004)   # PURGE_TXCLEAR | PURGE_RXCLEAR
    return h


def write_bytes(h, data: bytes):
    n = wt.DWORD(0)
    buf = ctypes.create_string_buffer(data, len(data))
    if not kernel32.WriteFile(h, buf, len(data), ctypes.byref(n), None):
        raise OSError(f"WriteFile 失败（Win32 错误 {ctypes.get_last_error()}）")
    return n.value


def read_available(h, wait_ms: int = 800) -> bytes:
    """读满 wait_ms 或直到连续 200ms 无新数据。"""
    out = bytearray()
    end = time.time() + wait_ms / 1000.0
    idle_deadline = None
    while time.time() < end:
        chunk = _read_once(h, 100)
        if chunk:
            out += chunk
            idle_deadline = time.time() + 0.2
        elif idle_deadline and time.time() > idle_deadline:
            break
        elif not out and time.time() > end:
            break
    return bytes(out)


def _read_once(h, ms: int) -> bytes:
    buf = ctypes.create_string_buffer(4096)
    n = wt.DWORD(0)
    # 临时把读超时压到 ms
    to = COMMTIMEOUTS()
    to.ReadIntervalTimeout = ms
    to.ReadTotalTimeoutConstant = ms
    kernel32.SetCommTimeouts(h, ctypes.byref(to))
    ok = kernel32.ReadFile(h, buf, 4096, ctypes.byref(n), None)
    if not ok:
        return b""
    return buf.raw[: n.value]


def show(label: str, data: bytes):
    if not data:
        print(f"  {label}: (无数据)")
        return
    printable = "".join(chr(b) if 32 <= b < 127 else "." for b in data)
    print(f"  {label}: {data.hex(' ')}")
    print(f"  {label} ascii: {printable!r}")


def send(h, cmd: str, wait_ms: int = 800, eol: str = "\r\n") -> bytes:
    payload = (cmd + eol).encode("ascii")
    write_bytes(h, payload)
    time.sleep(wait_ms / 1000.0)
    return read_available(h, wait_ms)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", help="COM 口号，如 COM8")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--ask", action="store_true", help="发一串只读查询指令")
    ap.add_argument("--raw", help="直接发一条指令")
    ap.add_argument("--no-eol", action="store_true", help="不加 \\r\\n（AT 指令表要求不加回车时用）")
    args = ap.parse_args()

    print(f"打开 {args.port} @ {args.baud} 8N1 …")
    h = open_port(args.port, args.baud)
    print("已打开。\n")
    eol = "" if args.no_eol else "\r\n"
    try:
        if args.raw:
            print(f">>> {args.raw}")
            show("回", send(h, args.raw, 900, eol))
            return

        # 先试探：有些固件要求 AT 指令**不带回车换行**
        cmds = ["AT", "AT+TRANMD?", "AT+ROLE?", "AT+BAUD?", "AT+NAME?", "AT+ADV?"] \
            if args.ask else ["AT"]
        for c in cmds:
            print(f">>> {c}")
            r = send(h, c, 900, eol)
            show("回", r)
            if not r and not args.ask:
                print("  （无回应，试不带回车换行）")
                r2 = send(h, c, 900, "")
                show("回", r2)
            print()
    finally:
        kernel32.CloseHandle(h)
        print("端口已关闭。")


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        print(f"错误：{e}", file=sys.stderr)
        sys.exit(1)