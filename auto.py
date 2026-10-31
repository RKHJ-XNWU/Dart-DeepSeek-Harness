#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
auto.py — 安卓全自动操作引擎
经本机 adb（uid=2000 shell，等同 Shizuku 权限），无需 root、无需 Shizuku。

能力：
  点击/长按/滑动/按键、找文字控件、弹窗广告自动清理、等待元素、等界面稳定
  输入文本（中文/emoji 全支持）、复制、剪切、粘贴、读取剪贴板、全选、清空
  启动/停止/卸载应用、截图、OCR、通知
  掉线自动重连、失败自动重试、超时保护

用法见：python3 auto.py -h
"""
import os
import re
import sys
import time
import struct
import hashlib
import subprocess
import xml.etree.ElementTree as ET

DEFAULT_SERIAL = "127.0.0.1:5555"
DUMP_PATH = "/sdcard/auto_dump.xml"
IME_ADB = "com.android.adbkeyboard/.AdbIME"
IME_ADB_PKG = "com.android.adbkeyboard"

# 按键码
K_BACK, K_HOME, K_ENTER = 4, 3, 66
K_WAKEUP, K_SLEEP = 224, 223
K_COPY, K_CUT, K_PASTE = 278, 277, 279
K_DEL, K_MOVE_END = 67, 123
K_CTRL_LEFT, K_A = 113, 29


# ==================== adb 底座 ====================
def _adb_bin():
    for p in ("/data/data/com.termux/files/usr/bin/adb", "adb"):
        if os.path.exists(p) or p == "adb":
            return p
    return "adb"


ADB = _adb_bin()
_SERIAL = DEFAULT_SERIAL


def _sh(args, timeout=30):
    return subprocess.run([ADB, "-s", _SERIAL] + args,
                          capture_output=True, timeout=timeout)


def server_up():
    try:
        r = subprocess.run([ADB, "version"], capture_output=True, timeout=10)
        if r.returncode == 0:
            return True
    except Exception:
        pass
    try:
        subprocess.run([ADB, "start-server"], capture_output=True, timeout=20)
        return True
    except Exception:
        return False


def reconnect(serial=None):
    serial = serial or _SERIAL
    try:
        subprocess.run([ADB, "connect", serial], capture_output=True, timeout=15)
        time.sleep(0.6)
    except Exception:
        pass


def device_online(serial=None):
    serial = serial or _SERIAL
    try:
        r = subprocess.run([ADB, "devices"], capture_output=True, timeout=15)
        for line in r.stdout.decode("utf-8", "replace").splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 2 and parts[0] == serial and parts[1] == "device":
                return True
    except Exception:
        pass
    return False


def ensure(serial=None, attempts=3):
    serial = serial or _SERIAL
    for _ in range(attempts):
        if device_online(serial):
            return True
        if not server_up():
            time.sleep(0.5)
        reconnect(serial)
        time.sleep(0.5)
    return device_online(serial)


def run(args, serial=None, timeout=30, retries=3, quiet=True):
    """执行 adb 命令；失败自动重连重试。"""
    global _SERIAL
    if serial:
        _SERIAL = serial
    last = ""
    for i in range(retries):
        try:
            r = _sh(args, timeout=timeout)
            out = r.stdout.decode("utf-8", "replace")
            err = r.stderr.decode("utf-8", "replace")
            if r.returncode == 0:
                return out
            last = err or out
            if any(k in last for k in ("offline", "not found", "no devices",
                                       "device unauthorized", "cannot connect")):
                ensure(_SERIAL)
        except subprocess.TimeoutExpired:
            last = "timeout"
        except Exception as e:
            last = str(e)
        if i < retries - 1:
            time.sleep(0.35)
    if last and not quiet:
        print("[adb] " + last.strip(), file=sys.stderr)
    return ""


# ==================== 输入法管理 ====================
def ime_current(serial=None):
    return run(["shell", "settings get secure default_input_method"],
               serial, retries=2).strip()


def ime_set(ime, serial=None):
    run(["shell", "ime set " + ime], serial, retries=2)
    return True


def _ime_switch_to_adb(serial=None):
    old = ime_current(serial)
    if IME_ADB in old:
        return old
    run(["shell", "ime enable " + IME_ADB], serial, retries=2)
    run(["shell", "ime set " + IME_ADB], serial, retries=2)
    time.sleep(0.4)
    return old


def _ime_restore(old, serial=None):
    if old and IME_ADB not in old:
        run(["shell", "ime set " + old], serial, retries=2)


# ==================== 文本输入 ====================
_SAFE_ASCII = re.compile(r"^[\x20-\x7e]+$")
_SH_SPECIAL = set(" &|;<>()$`\\\"'!#*?[]{}~^")


def _esc_shell_text(s):
    out = []
    for ch in s:
        if ch == " ":
            out.append("%s")
        elif ch in _SH_SPECIAL:
            out.append("\\" + ch)
        else:
            out.append(ch)
    return "".join(out)


def input_text(text, serial=None, restore_ime=True):
    """输入任意文本（中文/emoji/ASCII）。"""
    if not text:
        return False
    if _SAFE_ASCII.match(text) and not (set(text) & _SH_SPECIAL):
        run(["shell", "input text " + _esc_shell_text(text)], serial, timeout=25)
        return True
    if not app_installed(IME_ADB_PKG, serial):
        if _SAFE_ASCII.match(text):
            run(["shell", "input text " + _esc_shell_text(text)], serial, timeout=25)
            return True
        return False
    old = _ime_switch_to_adb(serial)
    try:
        import base64
        b64 = base64.b64encode(text.encode("utf-8")).decode("ascii")
        run(["shell", "am broadcast -a ADB_INPUT_B64 --es msg " + b64],
            serial, timeout=25)
        time.sleep(0.25)
        return True
    finally:
        if restore_ime:
            _ime_restore(old, serial)


def select_all_keys(serial=None):
    """Ctrl+A 全选（Android 11+ input keycombination）。"""
    run(["shell", "input keycombination %d %d" % (K_CTRL_LEFT, K_A)],
        serial, timeout=20)
    time.sleep(0.15)
    return True


def clear_text(serial=None, chunk=40, retry=2):
    """清空当前输入框：先在末尾连续退格，失败则重新聚焦后重试。

    兼容「输入框为空时 text 属性返回 hint」：以文本长度是否变短为准。
    """
    for _ in range(retry):
        before = edit_text(serial)
        if not before:
            return True
        pos = find_edit(serial)
        if pos:
            tap(pos[0], pos[1], serial)
            time.sleep(0.3)
        run(["shell", "input keyevent %d" % K_MOVE_END], serial)
        n = len(before) + 8
        while n > 0:
            b = min(n, chunk)
            run(["shell", "input keyevent " + " ".join([str(K_DEL)] * b)],
                serial, timeout=45)
            n -= b
            time.sleep(0.1)
        after = edit_text(serial)
        if after == "" or len(after) < len(before):
            return True
    return False


def select_all(serial=None):
    """全选：优先长按输入框点菜单「全选」，兜底 Ctrl+A。

    注意：部分自定义输入框（如 OPPO 设置搜索框）不支持 Ctrl+A，
    必须走长按菜单。
    """
    pos = find_edit(serial)
    if pos:
        long_press(pos[0], pos[1], 800, serial)
        time.sleep(0.8)
        if tap_text_any(["全选", "Select all", "Select All"], serial):
            time.sleep(0.3)
            return True
        key(K_BACK, serial)
        time.sleep(0.3)
    return select_all_keys(serial)


# ==================== 剪贴板 ====================
def clip_get(serial=None):
    """读取剪贴板文本（解析 getPrimaryClip 的 Parcel）。"""
    out = run(["shell", "service call clipboard 4 s16 com.android.shell s16 null i32 0"],
              serial, timeout=20)
    if "Parcel" not in out:
        return ""
    data = b""
    for line in out.splitlines():
        m = re.match(r"\s*0x[0-9a-fA-F]+:\s+((?:[0-9a-fA-F]{8}\s*)+)", line)
        if not m:
            continue
        for w in m.group(1).split():
            data += struct.pack("<I", int(w, 16))
    if not data:
        return ""
    noise = {"text/plain", "text/html", "BNDL", "url", "intent",
             "android.intent.extra.TEXT", "http://", "https://"}
    best, cur, i = "", [], 0
    while i + 1 < len(data):
        ch = data[i] | (data[i + 1] << 8)
        if 32 <= ch < 0xFFFE and (chr(ch).isprintable() or ch in (9, 10, 13)):
            cur.append(chr(ch))
        else:
            if len(cur) >= 2:
                s = "".join(cur).strip()
                if s and s not in noise and len(s) > len(best):
                    best = s
            cur = []
        i += 2
    if len(cur) >= 2:
        s = "".join(cur).strip()
        if s and s not in noise and len(s) > len(best):
            best = s
    return best


def clip_copy(serial=None):
    run(["shell", "input keyevent %d" % K_COPY], serial)
    return True


def clip_cut(serial=None):
    run(["shell", "input keyevent %d" % K_CUT], serial)
    return True


def clip_paste(serial=None):
    run(["shell", "input keyevent %d" % K_PASTE], serial)
    return True


# ==================== 屏幕 ====================
def size(serial=None):
    out = run(["shell", "wm", "size"], serial, retries=2)
    m = re.search(r"(\d+)x(\d+)", out)
    return (int(m.group(1)), int(m.group(2))) if m else (720, 1600)


def tap(x, y, serial=None):
    run(["shell", "input tap %d %d" % (int(x), int(y))], serial)
    return True


def long_press(x, y, ms=800, serial=None):
    run(["shell", "input swipe %d %d %d %d %d %d" %
         (int(x), int(y), int(x), int(y), int(ms), int(ms))], serial, timeout=30)
    return True


def swipe(x1, y1, x2, y2, ms=600, serial=None):
    # ColorOS 对过快注入会拒绝，默认 600ms
    run(["shell", "input swipe %d %d %d %d %d" %
         (int(x1), int(y1), int(x2), int(y2), int(ms))], serial, timeout=30)
    return True


def key(code, serial=None):
    run(["shell", "input keyevent %d" % int(code)], serial)


def screen_on(serial=None):
    key(K_WAKEUP, serial)


def screen_off(serial=None):
    key(K_SLEEP, serial)


def wake_state(serial=None):
    out = run(["shell", "dumpsys power"], serial, timeout=25, retries=2)
    m = re.search(r"mWakefulness=(\w+)", out)
    return m.group(1) if m else "Unknown"


def unlock(serial=None, pin=None):
    screen_on(serial)
    time.sleep(0.6)
    w, h = size(serial)
    swipe(w // 2, int(h * 0.82), w // 2, int(h * 0.28), 400, serial)
    time.sleep(0.7)
    if pin:
        input_text(str(pin), serial)
        key(K_ENTER, serial)
        time.sleep(0.8)
    return True


# ==================== UI 解析 ====================
def dump(serial=None, retries=2):
    for _ in range(retries):
        run(["shell", "uiautomator dump " + DUMP_PATH], serial, timeout=45, retries=2)
        xml = run(["shell", "cat " + DUMP_PATH], serial, timeout=25, retries=2)
        if xml.strip().startswith("<?xml"):
            try:
                return ET.fromstring(xml)
            except ET.ParseError:
                pass
        time.sleep(0.4)
    return None


def _center(node):
    m = re.search(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if not m:
        return None
    a, b, c, d = map(int, m.groups())
    if c - a <= 1 or d - b <= 1:
        return None
    return (a + c) // 2, (b + d) // 2


def iter_nodes(root):
    return list(root.iter()) if root is not None else []


def find_nodes(text=None, rid=None, cls=None, serial=None, root=None,
               exact=False, desc=True):
    root = root if root is not None else dump(serial)
    hits = []
    for n in iter_nodes(root):
        t = n.get("text", "") or ""
        d = (n.get("content-desc", "") or "") if desc else ""
        r = n.get("resource-id", "") or ""
        k = n.get("class", "") or ""
        ok = True
        if text is not None:
            ok = ok and ((t == text or d == text) if exact
                         else (text in t or text in d))
        if rid is not None:
            ok = ok and (rid in r)
        if cls is not None:
            ok = ok and (cls in k)
        if ok and (text is not None or rid is not None or cls is not None):
            c = _center(n)
            if c:
                hits.append(c)
    return hits


def tap_text_any(words, serial=None, root=None):
    root = root if root is not None else dump(serial)
    nodes = iter_nodes(root)
    for w in words:
        for n in nodes:
            t = (n.get("text", "") or "").strip()
            d = (n.get("content-desc", "") or "").strip()
            if t == w or d == w or (len(w) > 2 and (w in t or w in d)):
                c = _center(n)
                if c:
                    tap(c[0], c[1], serial)
                    return True
    return False


def tap_text(text, serial=None, exact=False, root=None):
    hits = find_nodes(text=text, serial=serial, root=root, exact=exact)
    if hits:
        tap(hits[0][0], hits[0][1], serial)
        return True
    return False


def tap_rid(rid, serial=None, root=None):
    hits = find_nodes(rid=rid, serial=serial, root=root)
    if hits:
        tap(hits[0][0], hits[0][1], serial)
        return True
    return False


def _is_edit(n):
    k = n.get("class", "") or ""
    return ("EditText" in k or "AutoCompleteTextView" in k
            or "SearchView" in k or "SearchAutoComplete" in k)


def find_edit(serial=None, root=None):
    """找第一个可聚焦输入框中心坐标。"""
    nodes = iter_nodes(root if root is not None else dump(serial))
    for n in nodes:
        if _is_edit(n) and (n.get("focusable") == "true" or n.get("clickable") == "true"):
            c = _center(n)
            if c:
                return c
    for n in nodes:
        if _is_edit(n):
            c = _center(n)
            if c:
                return c
    return None


def edit_text(serial=None, root=None):
    """读取当前聚焦输入框的文本。"""
    nodes = iter_nodes(root if root is not None else dump(serial))
    for n in nodes:
        if _is_edit(n) and n.get("focused") == "true":
            return n.get("text", "") or ""
    for n in nodes:
        if _is_edit(n):
            return n.get("text", "") or ""
    return ""


def type_into(text, serial=None, root=None):
    """找输入框 -> 点击聚焦 -> 输入文本。"""
    pos = find_edit(serial, root) or find_edit(serial, dump(serial))
    if pos is None:
        return False
    tap(pos[0], pos[1], serial)
    time.sleep(0.55)
    return input_text(text, serial)


def wait_text(text, timeout=8, interval=0.5, serial=None):
    end = time.time() + timeout
    while time.time() < end:
        if find_nodes(text=text, serial=serial):
            return True
        time.sleep(interval)
    return False


def wait_gone(text, timeout=8, interval=0.5, serial=None):
    end = time.time() + timeout
    while time.time() < end:
        if not find_nodes(text=text, serial=serial):
            return True
        time.sleep(interval)
    return False


# ==================== 弹窗 / 广告 ====================
CLOSE_WORDS = ["跳过", "跳过广告", "关闭", "取消", "我知道了", "知道了", "暂不",
               "以后再说", "稍后再说", "稍后", "不同意", "拒绝", "不再提示",
               "残忍拒绝", "Skip", "Skip Ad", "Close", "Not now", "Later", "Cancel"]
ALLOW_WORDS = ["允许", "始终允许", "Allow", "While using the app", "仅在使用中允许"]


def kill_popup(rounds=3, serial=None, allow=False, wait=0.5):
    words = list(CLOSE_WORDS) + (ALLOW_WORDS if allow else [])
    killed = []
    for _ in range(rounds):
        root = dump(serial)
        if root is None:
            break
        hit = None
        for n in iter_nodes(root):
            t = (n.get("text", "") or "").strip()
            d = (n.get("content-desc", "") or "").strip()
            c = _center(n)
            if not c:
                continue
            for w in words:
                if t == w or d == w or (len(w) > 2 and (w in t or w in d)):
                    hit = (c, w)
                    break
            if hit:
                break
        if not hit:
            break
        (cx, cy), w = hit
        tap(cx, cy, serial)
        killed.append(w)
        time.sleep(wait)
    return killed


# ==================== 应用 ====================
def app_start(pkg, activity=None, serial=None, settle=1.2):
    if activity:
        run(["shell", "am start -n %s/%s" % (pkg, activity)], serial, timeout=35)
    else:
        run(["shell", "monkey -p %s -c android.intent.category.LAUNCHER 1" % pkg],
            serial, timeout=35)
    time.sleep(settle)
    return current_app(serial) == pkg


def app_stop(pkg, serial=None):
    run(["shell", "am force-stop " + pkg], serial)
    return True


def app_uninstall(pkg, serial=None):
    out = run(["shell", "pm uninstall " + pkg], serial, timeout=90)
    return "Success" in out


def app_installed(pkg, serial=None):
    out = run(["shell", "pm list packages " + pkg], serial, retries=2)
    return ("package:" + pkg) in out


def current_app(serial=None):
    out = run(["shell", "dumpsys window"], serial, timeout=25, retries=2)
    for line in out.splitlines():
        if "mCurrentFocus" in line or "mFocusedApp" in line:
            m = re.search(r"([a-zA-Z0-9_.]+)/", line)
            if m:
                return m.group(1)
    return ""


def install_apk(path, serial=None):
    out = run(["install", "-r", "-d", path], serial, timeout=180)
    return "Success" in out


# ==================== 截图 / OCR ====================
def shot(path=None, serial=None):
    path = path or os.path.join(os.environ.get("HOME", "."), "shot.png")
    tmp = "/sdcard/.auto_shot.png"
    run(["shell", "screencap -p " + tmp], serial, timeout=45, retries=2)
    subprocess.run([ADB, "-s", serial or _SERIAL, "pull", tmp, path],
                   capture_output=True, timeout=45)
    run(["shell", "rm -f " + tmp], serial, retries=1)
    return path if os.path.exists(path) else None


def ocr(path):
    try:
        r = subprocess.run(["tesseract", path, "stdout", "-l", "chi_sim+eng"],
                           capture_output=True, timeout=120)
        return r.stdout.decode("utf-8", "replace")
    except Exception as e:
        return "[ocr失败] " + str(e)


def screen_hash(serial=None):
    try:
        r = subprocess.run([ADB, "-s", serial or _SERIAL, "exec-out", "screencap -p"],
                           capture_output=True, timeout=45)
        return hashlib.md5(r.stdout).hexdigest()
    except Exception:
        return ""


# ==================== 通知 ====================
def notify(title, content, serial=None):
    t = str(title).replace("'", "")
    c = str(content).replace("'", "")
    run(["shell", "cmd notification post -S bigtext -t '%s' autotag '%s'" % (t, c)],
        serial, timeout=20, retries=1)
    return True


# ==================== 状态守卫 ====================
def alive(serial=None, max_retry=5):
    for _ in range(max_retry):
        if ensure(serial):
            out = run(["shell", "echo ok"], serial, retries=1)
            if "ok" in out:
                w, h = size(serial)
                return True, {"size": (w, h), "app": current_app(serial),
                              "wake": wake_state(serial)}
        time.sleep(0.8)
    return False, {}


def wait_stable(serial=None, interval=0.5, max_wait=8.0, stable_rounds=2):
    """等界面稳定（连续 N 次截图指纹一致）。防卡死用。"""
    end = time.time() + max_wait
    prev, same = "", 0
    while time.time() < end:
        h = screen_hash(serial)
        if h and h == prev:
            same += 1
            if same >= stable_rounds:
                return True
        else:
            same = 0
            prev = h
        time.sleep(interval)
    return False


# ==================== CLI ====================
def main():
    import argparse
    p = argparse.ArgumentParser(
        description="安卓全自动操作引擎（adb uid=2000，等同 Shizuku）")
    p.add_argument("--serial", default=DEFAULT_SERIAL, help="adb 设备序列号")
    sub = p.add_subparsers(dest="cmd")

    sub.add_parser("status")
    s = sub.add_parser("tap"); s.add_argument("x", type=int); s.add_argument("y", type=int)
    s = sub.add_parser("tap-text"); s.add_argument("text"); s.add_argument("--exact", action="store_true")
    s = sub.add_parser("tap-id"); s.add_argument("rid")
    s = sub.add_parser("long"); s.add_argument("x", type=int); s.add_argument("y", type=int); s.add_argument("--ms", type=int, default=800)
    s = sub.add_parser("swipe")
    for k in ("x1", "y1", "x2", "y2"):
        s.add_argument(k, type=int)
    s.add_argument("--ms", type=int, default=600)
    s = sub.add_parser("key"); s.add_argument("code")
    sub.add_parser("on"); sub.add_parser("off")
    s = sub.add_parser("unlock"); s.add_argument("--pin")
    sub.add_parser("dump")
    s = sub.add_parser("find"); s.add_argument("text")
    s = sub.add_parser("wait"); s.add_argument("text"); s.add_argument("--timeout", type=float, default=8)
    s = sub.add_parser("wait-gone"); s.add_argument("text"); s.add_argument("--timeout", type=float, default=8)
    s = sub.add_parser("kill-popup"); s.add_argument("--rounds", type=int, default=3); s.add_argument("--allow", action="store_true")
    s = sub.add_parser("start"); s.add_argument("pkg"); s.add_argument("--activity")
    s = sub.add_parser("stop"); s.add_argument("pkg")
    s = sub.add_parser("uninstall"); s.add_argument("pkg")
    s = sub.add_parser("installed"); s.add_argument("pkg")
    sub.add_parser("current")
    s = sub.add_parser("shot"); s.add_argument("--path"); s.add_argument("--ocr", action="store_true")
    s = sub.add_parser("notify"); s.add_argument("title"); s.add_argument("content")

    s = sub.add_parser("type", help="输入文本（中文/emoji 全支持）"); s.add_argument("text")
    s = sub.add_parser("type-into", help="找输入框并输入"); s.add_argument("text")
    sub.add_parser("copy", help="复制选中内容")
    sub.add_parser("cut", help="剪切选中内容")
    sub.add_parser("paste", help="粘贴剪贴板")
    sub.add_parser("clip-get", help="读取剪贴板文本")
    sub.add_parser("select-all", help="全选当前输入框")
    sub.add_parser("select-all-keys", help="Ctrl+A 全选")
    sub.add_parser("clear", help="清空当前输入框")
    sub.add_parser("edit-text", help="读取当前输入框文本")
    sub.add_parser("stable", help="等待界面稳定")

    a = p.parse_args()
    if not a.cmd:
        p.print_help()
        return

    global _SERIAL
    if getattr(a, "serial", None):
        _SERIAL = a.serial

    if a.cmd == "status":
        ok, info = alive()
        print("在线" if ok else "离线", info)
        return

    ensure()

    if a.cmd == "tap": print(tap(a.x, a.y))
    elif a.cmd == "tap-text": print(tap_text(a.text, exact=a.exact))
    elif a.cmd == "tap-id": print(tap_rid(a.rid))
    elif a.cmd == "long": print(long_press(a.x, a.y, a.ms))
    elif a.cmd == "swipe": print(swipe(a.x1, a.y1, a.x2, a.y2, a.ms))
    elif a.cmd == "key": key(a.code); print(True)
    elif a.cmd == "on": screen_on(); print(True)
    elif a.cmd == "off": screen_off(); print(True)
    elif a.cmd == "unlock": unlock(pin=a.pin); print(True)
    elif a.cmd == "dump": print("OK" if dump() is not None else "FAIL")
    elif a.cmd == "find": print(find_nodes(text=a.text))
    elif a.cmd == "wait": print(wait_text(a.text, a.timeout))
    elif a.cmd == "wait-gone": print(wait_gone(a.text, a.timeout))
    elif a.cmd == "kill-popup": print(kill_popup(a.rounds, allow=a.allow))
    elif a.cmd == "start": print(app_start(a.pkg, a.activity))
    elif a.cmd == "stop": print(app_stop(a.pkg))
    elif a.cmd == "uninstall": print(app_uninstall(a.pkg))
    elif a.cmd == "installed": print(app_installed(a.pkg))
    elif a.cmd == "current": print(current_app())
    elif a.cmd == "shot":
        f = shot(a.path)
        print(f)
        if f and a.ocr:
            print(ocr(f))
    elif a.cmd == "notify": notify(a.title, a.content); print(True)
    elif a.cmd == "type": print(input_text(a.text))
    elif a.cmd == "type-into": print(type_into(a.text))
    elif a.cmd == "copy": print(clip_copy())
    elif a.cmd == "cut": print(clip_cut())
    elif a.cmd == "paste": print(clip_paste())
    elif a.cmd == "clip-get": print(repr(clip_get()))
    elif a.cmd == "select-all": print(select_all())
    elif a.cmd == "select-all-keys": print(select_all_keys())
    elif a.cmd == "clear": print(clear_text())
    elif a.cmd == "edit-text": print(repr(edit_text()))
    elif a.cmd == "stable": print(wait_stable())


if __name__ == "__main__":
    main()
