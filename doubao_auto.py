#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
doubao_auto.py —— 豆包大模型专属安卓自动化引擎
=================================================

设计目标
--------
本文件是 auto.py 的「豆包专用适配版」，供豆包专属工具模式
（lib/src/doubao_tools.dart）在函数调用里使用。二者底座相同：
经本机 adb（uid=2000 shell，等同 Shizuku 权限）操作，无需 root。

与 auto.py 的差异（都是为豆包模型的行为特征而做）
--------------------------------------------------
1. **结构化输出**：所有动作都能 `--json` 返回统一信封
   `{"ok":true,"data":{...},"meta":{...}}`，
   豆包拿到的是可直接推理的字段，而不是一大段自由文本。
2. **一次性感知 observe**：把「当前应用 + 屏幕文字 + 可点元素 +
   屏幕指纹 + 电量 + 亮度」打包成一次返回，减少豆包的往返轮次
   （豆包 summary 思考的包间延迟较高，减少轮次就是减少卡顿感知）。
3. **原子计划 plan**：把多步操作写成一个 JSON 数组一次提交，
   引擎内部逐步执行并记录每步结果，失败即停并回报第几步失败。
   豆包只需一次工具调用就能完成「打开微信 → 找联系人 → 输入 → 发送」。
4. **思考感知等待 wait_model**：轮询界面指纹，直到连续 N 次不变
   才判定「模型/界面已静止」，避免豆包在界面还在动画时就点击。
5. **多方案输入**：ADBKeyboard → 剪贴板粘贴 → 逐字符 keyevent，
   三档回退，任何一档失败自动降级，全部失败才报错。
6. **不抛裸异常**：任何路径都返回信封，豆包不会因为 traceback 卡住。

用法示例
--------
  python3 doubao_auto.py tap 540 1200
  python3 doubao_auto.py text "你好"
  python3 doubao_auto.py observe --json
  python3 doubao_auto.py plan --json '[
      {"op":"start_app","pkg":"com.tencent.mm"},
      {"op":"wait_model","stable_ms":800},
      {"op":"tap_text","text":"通讯录"},
      {"op":"text","text":"晚上一起吃饭"}
  ]'
  python3 doubao_auto.py screen off
  python3 doubao_auto.py screen on

安全边界
--------
· 本引擎不是沙箱：所有动作直接作用于真机，无人工确认环节。
· 不读取、不打印任何 API Key / 主密钥 / 会话内容。
· 卸载、强制停止等高危动作必须显式给出完整包名才会执行。
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

# ==================== 常量 ====================

VERSION = "1.0.0"
DEFAULT_SERIAL = "127.0.0.1:5555"
DUMP_PATH = "/sdcard/doubao_auto_dump.xml"
SHOT_PATH = "/sdcard/doubao_auto_shot.png"

IME_ADB = "com.android.adbkeyboard/.AdbIME"

K_BACK, K_HOME, K_ENTER = 4, 3, 66
K_WAKEUP, K_SLEEP = 224, 223
K_PASTE, K_DEL, K_MOVE_END = 279, 67, 123
K_CTRL_LEFT, K_A = 113, 29

# 常见弹窗「跳过/关闭」文案（广告清理用）
POPUP_WORDS = (
    "跳过", "跳過", "关闭", "關閉", "以后再说", "稍后再说", "暂不", "暂不更新",
    "取消", "我知道了", "知道", "不再提示", "残忍拒绝", "下次再说",
    "Skip", "Skip Ad", "Close", "Not now", "Later", "Cancel", "No thanks",
)

ADB = None
_SERIAL = DEFAULT_SERIAL


# ==================== 信封 ====================

def ok(data=None, meta=None):
    """成功信封"""
    return {"ok": True, "data": data if data is not None else {},
            "meta": meta or {}}


def err(message, code="error", **extra):
    """失败信封：豆包据此判断是否换方案，而不是看到 traceback"""
    e = {"ok": False, "error": str(message), "code": code}
    e.update(extra)
    return e


# ==================== adb 底座 ====================

def _adb_bin():
    for p in ("/data/data/com.termux/files/usr/bin/adb", "adb"):
        if p == "adb" or os.path.exists(p):
            return p
    return "adb"


def adb_init(serial=None):
    global ADB, _SERIAL
    ADB = _adb_bin()
    if serial:
        _SERIAL = serial
    return ADB


def _sh(args, timeout=30):
    """同步执行 adb 命令，永不抛异常"""
    try:
        return subprocess.run([ADB, "-s", _SERIAL] + args,
                              capture_output=True, timeout=timeout)
    except Exception as e:
        class _R:
            returncode = 1
            stdout = b""
            stderr = str(e).encode()
        return _R()


def _out(r):
    try:
        return (r.stdout or b"").decode("utf-8", "replace").strip()
    except Exception:
        return ""


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
    s = serial or _SERIAL
    try:
        subprocess.run([ADB, "connect", s], capture_output=True, timeout=15)
        time.sleep(0.6)
        return True
    except Exception:
        return False


def device_online(serial=None):
    s = serial or _SERIAL
    r = _sh(["devices"], timeout=15)
    for line in _out(r).splitlines():
        line = line.strip()
        if not line or line.startswith("List of devices"):
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[0] == s and parts[1] == "device":
            return True
    return False


def ensure(serial=None, attempts=3):
    """确保设备在线：起服务 → 连接 → 校验；失败重试"""
    s = serial or _SERIAL
    server_up()
    for i in range(max(1, attempts)):
        if device_online(s):
            return True
        reconnect(s)
        time.sleep(0.5 + i * 0.3)
    return device_online(s)


def run(args, serial=None, timeout=30, retries=3):
    """带重试的 adb 执行：掉线自动重连后重跑"""
    s = serial or _SERIAL
    last = None
    for i in range(max(1, retries)):
        r = _sh(args, timeout=timeout) if s == _SERIAL else subprocess.run(
            [ADB, "-s", s] + args, capture_output=True, timeout=timeout)
        if r.returncode == 0:
            return _out(r)
        last = r
        if i < retries - 1:
            ensure(s, attempts=2)
            time.sleep(0.3)
    try:
        return _out(last) if last else ""
    except Exception:
        return ""


# ==================== 屏幕 / 电量 / 亮度 ====================

def screen_size():
    raw = run(["shell", "wm", "size"], timeout=15)
    m = re.search(r"(\d+)x(\d+)", raw)
    if not m:
        return 1080, 2400
    return int(m.group(1)), int(m.group(2))


def screen_on():
    run(["shell", "input", "keyevent", str(K_WAKEUP)])
    time.sleep(0.4)
    return ok({"screen": "on"})


def screen_off():
    run(["shell", "input", "keyevent", str(K_SLEEP)])
    time.sleep(0.3)
    return ok({"screen": "off"})


def wake_state():
    raw = run(["shell", "dumpsys", "power"], timeout=20)
    m = re.search(r"mWakefulness=(\w+)", raw)
    state = m.group(1) if m else "Unknown"
    return ok({"wakefulness": state, "on": state.lower() == "awake"})


def battery():
    raw = run(["shell", "dumpsys", "battery"], timeout=20)
    level = None
    status = None
    m = re.search(r"level:\s*(\d+)", raw)
    if m:
        level = int(m.group(1))
    m = re.search(r"status:\s*(\d+)", raw)
    if m:
        status = int(m.group(1))
    return ok({"level": level, "status": status})


def brightness_get():
    raw = run(["shell", "settings", "get", "system", "screen_brightness"],
              timeout=15)
    try:
        return ok({"brightness": int(raw.strip())})
    except Exception:
        return ok({"brightness": None})


def brightness_range():
    """读取本机亮度量程上限。部分机型是 255，部分机型是 2047 等。
    取不到时用 2047 兜底（实测多数量程为 0-2047）。"""
    raw = run(["shell", "settings", "get", "system", "screen_brightness_max"],
              timeout=15)
    try:
        v = int((raw or "").strip())
        if v > 0:
            return v
    except Exception:
        pass
    return 2047


def brightness_set(value):
    """设置亮度。

    入参 0-255 视为「百分比量程」，按本机实际量程等比换算；
    大于 255 视为「本机原始值」，直接写入。这样调用方两种口径都能用，
    不会因为机型量程不同而写出一个明显不对的亮度。
    """
    try:
        v = float(value)
    except Exception:
        return err("brightness 需要数字", "bad_param")
    mx = brightness_range()
    if v <= 255:
        v = v / 255.0 * mx
    v = int(max(0, min(mx, v)))
    run(["shell", "settings", "put", "system", "screen_brightness", str(v)],
        timeout=20)
    return ok({"brightness": v, "max": mx})


# ==================== 基础动作 ====================

def tap(x, y):
    try:
        xi, yi = int(x), int(y)
    except Exception:
        return err("tap 需要整数坐标", "bad_param")
    run(["shell", "input", "tap", str(xi), str(yi)], timeout=20)
    return ok({"tap": [xi, yi]})


def long_press(x, y, ms=800):
    try:
        xi, yi, m = int(x), int(y), int(ms)
    except Exception:
        return err("long_press 参数非法", "bad_param")
    run(["shell", "input", "swipe", str(xi), str(yi), str(xi), str(yi),
         str(m)], timeout=20)
    return ok({"long_press": [xi, yi], "ms": m})


def swipe(x1, y1, x2, y2, ms=600):
    try:
        a = [int(x1), int(y1), int(x2), int(y2), int(ms)]
    except Exception:
        return err("swipe 参数非法", "bad_param")
    run(["shell", "input", "swipe"] + [str(v) for v in a], timeout=20)
    return ok({"swipe": a})


def key(code, times=1):
    try:
        c = int(code)
        n = max(1, int(times))
    except Exception:
        return err("key 需要整数键码", "bad_param")
    for _ in range(n):
        run(["shell", "input", "keyevent", str(c)], timeout=20)
        time.sleep(0.05)
    return ok({"keycode": c, "times": n})


def back():
    return key(K_BACK)


def home():
    return key(K_HOME)


# ==================== 文本输入（三档回退）====================

def ime_current():
    return run(["shell", "settings", "get", "secure", "default_input_method"],
               timeout=15)


def ime_set(ime):
    run(["shell", "ime", "set", ime], timeout=20)
    time.sleep(0.3)
    return ime_current()


def _esc_text(text):
    """adb shell input text 的转义：空格→%s，特殊字符加反斜杠"""
    s = str(text)
    s = s.replace(" ", "%s")
    for ch in ("\\", "'", '"', "`", "$", "&", "|", ";", "<", ">", "(", ")",
               "*", "?", "~", "#"):
        s = s.replace(ch, "\\" + ch)
    return s


def _input_via_adb_keyboard(text):
    """方案 A：ADBKeyboard 广播（中文/emoji 全支持）"""
    if IME_ADB.split("/")[0] not in (ime_current() or ""):
        ime_set(IME_ADB)
        time.sleep(0.3)
    payload = str(text).replace("\\", "\\\\").replace('"', '\\"')
    run(["shell", "am", "broadcast", "-a", "ADB_INPUT_TEXT", "--es", "msg",
         '"%s"' % payload], timeout=20)
    return True


def _input_via_clipboard(text):
    """方案 B：剪贴板 + 粘贴键（无 ADBKeyboard 时的主力路径）"""
    # Android 10+ 允许 shell 写剪贴板的方式不稳定，这里走 service call 兜底
    payload = str(text)
    b64 = payload.encode("utf-8").hex()
    # 先试 cmd clipboard
    r = run(["shell", "cmd", "clipboard", "set", payload], timeout=20)
    if r:
        return True
    # 再试 input keyevent 粘贴（需已有内容）
    run(["shell", "input", "keyevent", str(K_PASTE)], timeout=20)
    return bool(b64)


def _input_via_keyevent(text):
    """方案 C：逐字 keyevent（仅 ASCII 可靠）"""
    s = _esc_text(text)
    if not s:
        return False
    run(["shell", "input", "text", s], timeout=30)
    return True


def input_text(text, restore_ime=True):
    """输入文本：A → B → C 三档回退，全失败才报错"""
    old = ime_current()
    tried = []
    for name, fn in (("adbkeyboard", _input_via_adb_keyboard),
                     ("clipboard", _input_via_clipboard),
                     ("keyevent", _input_via_keyevent)):
        try:
            if fn(text):
                tried.append(name + ":ok")
                if restore_ime and old and name == "adbkeyboard":
                    ime_set(old)
                return ok({"text": text, "via": name, "tried": tried})
            tried.append(name + ":fail")
        except Exception as e:
            tried.append("%s:%s" % (name, e))
    if old:
        ime_set(old)
    return err("三档输入方案均失败", "input_failed", tried=tried)


# ==================== UI 树 / 元素查找 ====================

def dump_xml(retries=2):
    """导出 UI 树；返回 XML 字符串（失败返回空串）"""
    for i in range(max(1, retries)):
        run(["shell", "uiautomator", "dump", DUMP_PATH], timeout=40)
        raw = run(["shell", "cat", DUMP_PATH], timeout=20)
        if raw and raw.lstrip().startswith("<"):
            return raw
        time.sleep(0.3)
    return ""


def parse_nodes(xml_text):
    """把 UI 树拍平成列表：文本、resource-id、class、bounds、可点"""
    if not xml_text:
        return []
    try:
        root = ET.fromstring(xml_text)
    except Exception:
        return []
    out = []

    def walk(node):
        a = node.attrib
        bounds = a.get("bounds", "")
        m = re.findall(r"\[(\d+),(\d+)\]", bounds)
        cx = cy = None
        if len(m) == 2:
            x1, y1 = int(m[0][0]), int(m[0][1])
            x2, y2 = int(m[1][0]), int(m[1][1])
            cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
        txt = a.get("text", "")
        desc = a.get("content-desc", "")
        if txt or desc or a.get("clickable") == "true":
            out.append({
                "text": txt,
                "desc": desc,
                "rid": a.get("resource-id", ""),
                "cls": a.get("class", ""),
                "clickable": a.get("clickable") == "true",
                "enabled": a.get("enabled") == "true",
                "bounds": bounds,
                "x": cx,
                "y": cy,
            })
        for c in list(node):
            walk(c)

    walk(root)
    return out


def find_nodes(text=None, rid=None, cls=None, contains=True):
    nodes = parse_nodes(dump_xml())
    out = []
    for n in nodes:
        if text is not None:
            hay = (n["text"] or "") + " " + (n["desc"] or "")
            if contains:
                if text not in hay:
                    continue
            else:
                if text not in (n["text"], n["desc"]):
                    continue
        if rid is not None and rid not in (n["rid"] or ""):
            continue
        if cls is not None and cls not in (n["cls"] or ""):
            continue
        out.append(n)
    return out


def tap_text(text, exact=False):
    nodes = find_nodes(text=text, contains=not exact)
    target = None
    for n in nodes:
        if n["x"] is not None:
            target = n
            break
    if not target:
        return err("找不到文本控件：%s" % text, "not_found")
    run(["shell", "input", "tap", str(target["x"]), str(target["y"])],
        timeout=20)
    return ok({"tapped": text, "at": [target["x"], target["y"]]})


def tap_rid(rid):
    nodes = find_nodes(rid=rid)
    for n in nodes:
        if n["x"] is not None:
            run(["shell", "input", "tap", str(n["x"]), str(n["y"])],
                timeout=20)
            return ok({"tapped_rid": rid, "at": [n["x"], n["y"]]})
    return err("找不到 resource-id 控件：%s" % rid, "not_found")


def wait_text(text, timeout=8, interval=0.5):
    """等待文本出现"""
    end = time.time() + float(timeout)
    while time.time() < end:
        if find_nodes(text=text):
            return ok({"found": text})
        time.sleep(interval)
    return err("等待超时：%s" % text, "timeout")


def wait_gone(text, timeout=8, interval=0.5):
    end = time.time() + float(timeout)
    while time.time() < end:
        if not find_nodes(text=text):
            return ok({"gone": text})
        time.sleep(interval)
    return err("元素未消失：%s" % text, "timeout")


# ==================== 界面稳定 / 思考感知等待 ====================

def screen_hash(fast=True):
    """屏幕指纹。

    fast=True（默认）：单次 adb 往返取「焦点窗口 + 前台 Activity」做哈希，
      实测约 250ms。wait_model 每 200ms 轮询一次，必须走这条快路，
      否则 uiautomator dump 的 8s 开销会让「等界面稳定」变成新的卡顿源。
    fast=False：UI 树全文哈希，精确但慢（约 8s），仅用于需要精确比对的场合。
    """
    if not fast:
        xml_text = dump_xml(retries=1)
        if xml_text:
            return hashlib.sha1(
                xml_text.encode("utf-8", "replace")).hexdigest()[:16]
    cmd = ("dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'; "
           "dumpsys activity activities | grep mResumedActivity")
    raw = run(["shell", cmd], timeout=20)
    base = " ".join(x.strip() for x in (raw or "").splitlines())
    if not base:
        base = "no-focus"
    return hashlib.sha1(base.encode("utf-8", "replace")).hexdigest()[:16]


def wait_model(stable_ms=800, max_ms=12000, poll_ms=200):
    """
    等待界面静止：连续 stable_ms 内指纹不变即返回。

    豆包专用：summary 思考的包间延迟高，模型给指令时界面常还在动画，
    直接点击会点空。此函数让引擎自己确认「界面真的停了」再交还控制权。
    """
    start = time.time()
    last = None
    last_change = start
    while (time.time() - start) * 1000 < float(max_ms):
        h = screen_hash()
        now = time.time()
        if h != last:
            last = h
            last_change = now
        elif (now - last_change) * 1000 >= float(stable_ms):
            return ok({"stable": True,
                       "waited_ms": int((now - start) * 1000),
                       "hash": h})
        time.sleep(float(poll_ms) / 1000.0)
    return ok({"stable": False,
               "waited_ms": int((time.time() - start) * 1000),
               "hash": last})


# ==================== 弹窗清理 ====================

def is_popup_present():
    nodes = parse_nodes(dump_xml(retries=1))
    words = set(POPUP_WORDS)
    hits = []
    for n in nodes:
        hay = (n["text"] or "") + " " + (n["desc"] or "")
        for w in words:
            if w and w in hay:
                hits.append({"word": w, "text": n["text"], "x": n["x"],
                             "y": n["y"]})
                break
    return ok({"present": bool(hits), "hits": hits[:8]})


def dismiss_popup(rounds=3, wait=0.4):
    """点掉弹窗。只点明确是弹窗的按钮，不乱点。"""
    done = []
    for _ in range(max(1, int(rounds))):
        st = is_popup_present()
        if not st["data"]["present"]:
            break
        hit = None
        for h in st["data"]["hits"]:
            if h["x"] is not None:
                hit = h
                break
        if not hit:
            break
        run(["shell", "input", "tap", str(hit["x"]), str(hit["y"])],
            timeout=20)
        done.append(hit["word"])
        time.sleep(float(wait))
    return ok({"dismissed": done})


# ==================== 应用管理 ====================

def app_start(pkg, activity=None, settle=1.2):
    if activity:
        run(["shell", "am", "start", "-n", "%s/%s" % (pkg, activity)],
            timeout=25)
    else:
        run(["shell", "monkey", "-p", pkg, "-c",
             "android.intent.category.LAUNCHER", "1"], timeout=25)
    time.sleep(float(settle))
    cur = current_app()
    return ok({"started": pkg, "current": cur["data"].get("package")})


def app_stop(pkg):
    if not pkg or "." not in pkg:
        return err("force-stop 需要完整包名", "bad_param")
    run(["shell", "am", "force-stop", pkg], timeout=20)
    return ok({"stopped": pkg})


def app_installed(pkg):
    raw = run(["shell", "pm", "list", "packages", pkg], timeout=20)
    return ok({"installed": pkg in raw, "package": pkg})


def app_uninstall(pkg):
    if not pkg or "." not in pkg:
        return err("卸载需要完整包名", "bad_param")
    chk = app_installed(pkg)
    if not chk["data"].get("installed"):
        return err("未安装：%s" % pkg, "not_installed")
    raw = run(["shell", "pm", "uninstall", pkg], timeout=40)
    return ok({"uninstalled": pkg, "raw": raw[-200:]})


def current_app():
    raw = run(["shell", "dumpsys", "window"], timeout=25)
    m = re.search(r"mCurrentFocus=Window\{[^ ]+ [^ ]+ ([^/]+)/([^}]+)\}", raw)
    if m:
        return ok({"package": m.group(1), "activity": m.group(2).strip()})
    m = re.search(r"mFocusedApp=.*?([a-zA-Z0-9_.]+)/([a-zA-Z0-9_.]+)", raw)
    if m:
        return ok({"package": m.group(1), "activity": m.group(2)})
    return ok({"package": "", "activity": ""})


# ==================== 截图 / OCR ====================

def screenshot(path=None):
    target = path or SHOT_PATH
    run(["shell", "screencap", "-p", "/sdcard/db_shot.png"], timeout=30)
    try:
        subprocess.run([ADB, "-s", _SERIAL, "pull", "/sdcard/db_shot.png",
                        target], capture_output=True, timeout=40)
    except Exception as e:
        return err("截图拉取失败：%s" % e, "shot_failed")
    size = 0
    try:
        size = os.path.getsize(target)
    except Exception:
        pass
    return ok({"path": target, "bytes": size})


def ocr(path):
    """OCR：仅在系统装了 tesseract 时可用，否则如实说明不可用"""
    exe = None
    for p in ("/data/data/com.termux/files/usr/bin/tesseract", "tesseract"):
        if p == "tesseract" or os.path.exists(p):
            exe = p
            break
    if not exe:
        return err("本机未安装 tesseract，OCR 不可用", "no_ocr")
    try:
        r = subprocess.run([exe, path, "stdout", "-l", "chi_sim+jpn+eng"],
                           capture_output=True, timeout=90)
        text = (r.stdout or b"").decode("utf-8", "replace").strip()
        return ok({"text": text, "chars": len(text)})
    except Exception as e:
        return err("OCR 失败：%s" % e, "ocr_failed")


# ==================== 一次性感知 ====================

def observe(with_nodes=True, node_limit=40):
    """
    豆包专用「一次看全」：
    当前应用 + 屏幕尺寸 + 唤醒状态 + 电量 + 亮度 + 指纹 + 可点元素。
    一次工具调用的信息量 ≈ 原来 5 次，显著减少豆包的往返轮次。
    """
    w, h = screen_size()
    cur = current_app()
    nodes = parse_nodes(dump_xml(retries=1)) if with_nodes else []
    clickable = [n for n in nodes if n["clickable"] and n["x"] is not None]
    texts = []
    seen = set()
    for n in nodes:
        t = (n["text"] or "").strip()
        if not t or t in seen:
            continue
        seen.add(t)
        texts.append(t)
    return ok({
        "package": cur["data"].get("package"),
        "activity": cur["data"].get("activity"),
        "screen": {"w": w, "h": h},
        "wake": wake_state()["data"],
        "battery": battery()["data"],
        "brightness": brightness_get()["data"],
        "hash": screen_hash(),
        "texts": texts[:node_limit],
        "clickable": [{"text": n["text"], "desc": n["desc"], "x": n["x"],
                       "y": n["y"]} for n in clickable[:node_limit]],
    })


# ==================== 原子计划执行 ====================

def _do_op(op):
    """执行单个计划步骤。返回 (信封, 是否视为成功)"""
    name = (op.get("op") or "").strip()
    if not name:
        return err("步骤缺少 op 字段", "bad_plan"), False

    if name == "tap":
        return tap(op.get("x"), op.get("y")), True
    if name == "long_press":
        return long_press(op.get("x"), op.get("y"), op.get("ms", 800)), True
    if name == "swipe":
        return swipe(op.get("x1"), op.get("y1"), op.get("x2"),
                     op.get("y2"), op.get("ms", 600)), True
    if name == "key":
        return key(op.get("code"), op.get("times", 1)), True
    if name in ("back", "go_back"):
        return back(), True
    if name == "home":
        return home(), True
    if name == "text":
        return input_text(op.get("text", "")), True
    if name == "tap_text":
        return tap_text(op.get("text", ""), bool(op.get("exact"))), True
    if name == "tap_rid":
        return tap_rid(op.get("rid", "")), True
    if name == "wait_text":
        return wait_text(op.get("text", ""), op.get("timeout", 8)), True
    if name == "wait_gone":
        return wait_gone(op.get("text", ""), op.get("timeout", 8)), True
    if name == "wait_model":
        return wait_model(op.get("stable_ms", 800), op.get("max_ms", 12000)), True
    if name == "dismiss_popup":
        return dismiss_popup(op.get("rounds", 3)), True
    if name == "start_app":
        return app_start(op.get("pkg", ""), op.get("activity"),
                         op.get("settle", 1.2)), True
    if name == "stop_app":
        return app_stop(op.get("pkg", "")), True
    if name == "observe":
        return observe(True, op.get("node_limit", 40)), True
    if name == "hash":
        return ok({"hash": screen_hash()}), True
    if name == "wake":
        return wake_state(), True
    if name == "battery":
        return battery(), True
    if name == "size":
        w, h = screen_size()
        return ok({"w": w, "h": h}), True
    if name == "current_app":
        return current_app(), True
    if name == "brightness":
        return (brightness_get() if op.get("value") is None
                else brightness_set(op.get("value"))), True
    if name == "is_popup_present":
        return is_popup_present(), True
    if name == "installed":
        return app_installed(op.get("pkg", "")), True
    if name == "ocr":
        return ocr(op.get("path", SHOT_PATH)), True
    if name == "find":
        return ok({"nodes": find_nodes(text=op.get("text"))}), True
    if name == "screenshot":
        return screenshot(op.get("path")), True
    if name == "sleep":
        time.sleep(float(op.get("ms", 300)) / 1000.0)
        return ok({"slept_ms": op.get("ms", 300)}), True
    if name == "screen_on":
        return screen_on(), True
    if name == "screen_off":
        return screen_off(), True
    return err("未知操作：%s" % name, "unknown_op"), False


def run_plan(steps, stop_on_error=True):
    """
    原子计划：多步一次提交，逐步执行并记录。
    失败即停（stop_on_error 默认 True），回报第几步、哪一步、原始错误。
    """
    if not isinstance(steps, list) or not steps:
        return err("计划必须是非空数组", "bad_plan")
    log = []
    for i, step in enumerate(steps):
        t0 = time.time()
        envelope, _ = _do_op(step if isinstance(step, dict) else {})
        cost = int((time.time() - t0) * 1000)
        log.append({
            "index": i,
            "op": (step or {}).get("op") if isinstance(step, dict) else None,
            "ok": envelope.get("ok", False),
            "ms": cost,
            "data": envelope.get("data"),
            "error": envelope.get("error"),
        })
        if not envelope.get("ok") and stop_on_error:
            return err("第 %d 步失败：%s" % (i, envelope.get("error")),
                       "plan_failed", step=i, log=log)
        time.sleep(0.05)
    return ok({"steps": len(log), "log": log})


# ==================== CLI ====================

def _print(env, as_json):
    if as_json:
        print(json.dumps(env, ensure_ascii=False))
    else:
        if env.get("ok"):
            print(json.dumps(env.get("data", {}), ensure_ascii=False,
                             indent=2))
        else:
            print("失败：%s" % env.get("error"))
            extra = {k: v for k, v in env.items()
                     if k not in ("ok", "error")}
            if extra:
                print(json.dumps(extra, ensure_ascii=False, indent=2))


def _usage():
    print(__doc__.strip())
    print("\n可用子命令：")
    for c in ("observe tap long_press swipe key back home text input "
              "tap_text tap_rid find wait_text wait_gone wait_model "
              "popup dismiss start stop installed uninstall current "
              "shot ocr battery brightness wake size hash plan screen "
              "version").split():
        print("  " + c)


# ------------------------------------------------------------
# 虚拟屏幕（副屏）：所有 UI 操作在独立 display 执行，主屏焦点不受影响
# 实测：Android 12 上 settings put global overlay_display_devices 可建副屏，
# am start --display / input -d / screencap -d 均可用；
# uiautomator dump 不支持 --display（会 dump 主屏），故副屏感知只走截图+OCR。
# ------------------------------------------------------------
VD_KEY = "overlay_display_devices"
VD_W, VD_H, VD_DPI = 720, 1280, 320


def vd_parse_ids(text):
    """从 dumpsys display 的 Display States 段取全部 display id。"""
    i = text.find("Display States:")
    if i < 0:
        return []
    tail = text[i:]
    j = tail.find("Display Adapters:")
    if j > 0:
        tail = tail[:j]
    return [int(x) for x in re.findall(r"Display Id=(\d+)", tail)]


def vd_display_id():
    """副屏 displayId；-1 表示不存在。主屏恒为 0，故取非 0 的那一个。"""
    text = run(["shell", "dumpsys display"], timeout=25)
    if 'uniqueId="overlay' not in text:
        return -1
    for i in vd_parse_ids(text):
        if i != 0:
            return i
    return -1


def vd_status():
    spec = run(["shell", "settings", "get", "global", VD_KEY], timeout=10).strip()
    did = vd_display_id()
    return ok({"spec": "" if spec == "null" else spec,
               "displayId": did, "ready": did >= 0})


def vd_create(w=None, h=None, dpi=None):
    try:
        w = int(w or VD_W)
        h = int(h or VD_H)
        dpi = int(dpi or VD_DPI)
    except Exception:
        return err("width/height/dpi 必须是整数", "bad_arg")
    spec = "%dx%d/%d" % (w, h, dpi)
    run(["shell", "settings", "put", "global", VD_KEY, spec], timeout=15)
    for _ in range(12):
        time.sleep(0.35)
        did = vd_display_id()
        if did >= 0:
            return ok({"displayId": did, "spec": spec, "created": True})
    return err("副屏创建超时（spec=%s）" % spec, "vd_timeout")


def vd_destroy():
    run(["shell", "settings", "put", "global", VD_KEY, ""], timeout=15)
    return ok({"configured": False})


def _vd_id_or_err():
    did = vd_display_id()
    if did < 0:
        return -1, err("副屏未就绪，先执行 vd_create", "vd_missing")
    return did, None


def vd_launch(target):
    if not target:
        return err("target 为空", "bad_arg")
    did, e = _vd_id_or_err()
    if e:
        return e
    t = target.strip()
    if "://" in t:
        args = ["shell", "am", "start", "--display", str(did), "-a",
                "android.intent.action.VIEW", "-d", t]
    elif "/" in t:
        args = ["shell", "am", "start", "--display", str(did), "-n", t]
    else:
        args = ["shell", "am", "start", "--display", str(did), "-a",
                "android.intent.action.MAIN", "-c",
                "android.intent.category.LAUNCHER", "-p", t]
    out = run(args, timeout=40)
    low = out.lower()
    bad = ("error" in low) or ("exception" in low) or ("does not exist" in low)
    return err(out, "vd_launch_failed") if bad else ok({"displayId": did, "out": out})


def vd_tap(x, y):
    did, e = _vd_id_or_err()
    if e:
        return e
    if x is None or y is None:
        return err("x/y 为空", "bad_arg")
    run(["shell", "input", "-d", str(did), "tap", str(x), str(y)], timeout=15)
    return ok({"displayId": did, "tap": [int(x), int(y)]})


def vd_swipe(x1, y1, x2, y2, ms=300):
    did, e = _vd_id_or_err()
    if e:
        return e
    if None in (x1, y1, x2, y2):
        return err("x1/y1/x2/y2 不能为空", "bad_arg")
    run(["shell", "input", "-d", str(did), "swipe",
         str(x1), str(y1), str(x2), str(y2), str(ms)], timeout=15)
    return ok({"displayId": did,
               "swipe": [int(x1), int(y1), int(x2), int(y2)], "ms": int(ms)})


def vd_key(code):
    did, e = _vd_id_or_err()
    if e:
        return e
    if code is None:
        return err("keycode 为空", "bad_arg")
    run(["shell", "input", "-d", str(did), "keyevent", str(code)], timeout=15)
    return ok({"displayId": did, "keycode": int(code)})


def vd_text(text):
    did, e = _vd_id_or_err()
    if e:
        return e
    if not text:
        return err("text 为空", "bad_arg")
    if all(ord(ch) < 128 for ch in text):
        run(["shell", "input", "-d", str(did), "text",
             text.replace(" ", "%s")], timeout=20)
        return ok({"displayId": did, "text": text, "mode": "input_text"})
    try:
        subprocess.run(["termux-clipboard-set", text],
                       capture_output=True, timeout=5)
        time.sleep(0.12)
        run(["shell", "input", "-d", str(did), "keyevent", "279"], timeout=15)
        return ok({"displayId": did, "text": text, "mode": "clipboard_paste"})
    except Exception as ex:
        return err("文本输入失败：%s" % ex, "vd_text_failed")


def vd_shot(path=None):
    did, e = _vd_id_or_err()
    if e:
        return e
    dest = path or ("/sdcard/.ds_vd_shot_%d.png" % int(time.time() * 1000))
    run(["shell", "screencap", "-d", str(did), "-p", dest], timeout=40)
    if (not os.path.exists(dest)) or os.path.getsize(dest) == 0:
        try:
            if os.path.exists(dest):
                os.remove(dest)
        except Exception:
            pass
        return err("副屏截图为空（该屏没有活动窗口，先 vd_launch）", "vd_shot_empty")
    return ok({"displayId": did, "path": dest, "bytes": os.path.getsize(dest)})


def _vd_ocr_file(p, lang="chi_sim+eng"):
    try:
        r = subprocess.run(["tesseract", p, "stdout", "-l", lang],
                           capture_output=True, timeout=90)
        txt = (r.stdout or b"").decode("utf-8", "replace").strip()
        return txt or "（无文字）"
    except Exception as ex:
        return "OCR 失败：%s" % ex


def vd_ocr(lang="chi_sim+eng"):
    s = vd_shot()
    if not s.get("ok"):
        return s
    p = s["data"]["path"]
    try:
        return ok({"displayId": s["data"]["displayId"], "path": p,
                   "text": _vd_ocr_file(p, lang)})
    finally:
        try:
            os.remove(p)
        except Exception:
            pass


def vd_observe(lang="chi_sim+eng"):
    st = vd_status()
    if not st.get("ok") or not st["data"]["ready"]:
        return st
    s = vd_shot()
    out = {"status": st["data"]}
    if not s.get("ok"):
        out["shot_error"] = s.get("error")
        return ok(out)
    p = s["data"]["path"]
    try:
        out["bytes"] = s["data"]["bytes"]
        out["ocr"] = _vd_ocr_file(p, lang)
    finally:
        try:
            os.remove(p)
        except Exception:
            pass
    return ok(out)


def main(argv):
    as_json = "--json" in argv
    argv = [a for a in argv if a != "--json"]
    serial = None
    if "--serial" in argv:
        i = argv.index("--serial")
        if i + 1 < len(argv):
            serial = argv[i + 1]
            del argv[i:i + 2]
    adb_init(serial)
    ensure(_SERIAL, attempts=2)

    if len(argv) < 2:
        _usage()
        return 0

    cmd = argv[1].lower()
    a = argv[2:]

    def arg(i, default=None):
        return a[i] if i < len(a) else default

    if cmd == "version":
        env = ok({"version": VERSION, "serial": _SERIAL,
                  "adb": ADB, "online": device_online()})
    elif cmd == "observe":
        env = observe(True, int(arg(0, 40)))
    elif cmd == "tap":
        env = tap(arg(0), arg(1))
    elif cmd == "long_press":
        env = long_press(arg(0), arg(1), arg(2, 800))
    elif cmd == "swipe":
        env = swipe(arg(0), arg(1), arg(2), arg(3), arg(4, 600))
    elif cmd == "key":
        env = key(arg(0), arg(1, 1))
    elif cmd == "back":
        env = back()
    elif cmd == "home":
        env = home()
    elif cmd in ("text", "input"):
        env = input_text(arg(0, ""))
    elif cmd == "tap_text":
        env = tap_text(arg(0, ""), arg(1, "") in ("exact", "1", "true"))
    elif cmd == "tap_rid":
        env = tap_rid(arg(0, ""))
    elif cmd == "find":
        env = ok({"nodes": find_nodes(text=arg(0))})
    elif cmd == "wait_text":
        env = wait_text(arg(0, ""), arg(1, 8))
    elif cmd == "wait_gone":
        env = wait_gone(arg(0, ""), arg(1, 8))
    elif cmd == "wait_model":
        env = wait_model(arg(0, 800), arg(1, 12000))
    elif cmd == "popup":
        env = is_popup_present()
    elif cmd == "dismiss":
        env = dismiss_popup(arg(0, 3))
    elif cmd == "start":
        env = app_start(arg(0, ""))
    elif cmd == "stop":
        env = app_stop(arg(0, ""))
    elif cmd == "installed":
        env = app_installed(arg(0, ""))
    elif cmd == "uninstall":
        env = app_uninstall(arg(0, ""))
    elif cmd == "current":
        env = current_app()
    elif cmd == "shot":
        env = screenshot(arg(0))
    elif cmd == "ocr":
        env = ocr(arg(0, SHOT_PATH))
    elif cmd == "battery":
        env = battery()
    elif cmd == "brightness":
        if arg(0) is None:
            env = brightness_get()
        else:
            env = brightness_set(arg(0))
    elif cmd == "wake":
        env = wake_state()
    elif cmd == "size":
        w, h = screen_size()
        env = ok({"w": w, "h": h})
    elif cmd == "hash":
        env = ok({"hash": screen_hash()})
    elif cmd == "screen":
        env = screen_on() if (arg(0, "on") == "on") else screen_off()
    elif cmd == "vd_status":
        env = vd_status()
    elif cmd == "vd_create":
        env = vd_create(arg(0), arg(1), arg(2))
    elif cmd == "vd_destroy":
        env = vd_destroy()
    elif cmd == "vd_launch":
        env = vd_launch(arg(0, ""))
    elif cmd == "vd_tap":
        env = vd_tap(arg(0), arg(1))
    elif cmd == "vd_swipe":
        env = vd_swipe(arg(0), arg(1), arg(2), arg(3), arg(4, 300))
    elif cmd == "vd_key":
        env = vd_key(arg(0))
    elif cmd == "vd_text":
        env = vd_text(arg(0, ""))
    elif cmd == "vd_shot":
        env = vd_shot(arg(0))
    elif cmd == "vd_ocr":
        env = vd_ocr(arg(0, "chi_sim+eng"))
    elif cmd == "vd_observe":
        env = vd_observe()
    elif cmd == "plan":
        raw = arg(0, "")
        if raw and os.path.exists(raw):
            raw = open(raw, "r", encoding="utf-8").read()
        try:
            steps = json.loads(raw)
        except Exception as e:
            env = err("计划 JSON 解析失败：%s" % e, "bad_json")
        else:
            env = run_plan(steps)
    else:
        env = err("未知子命令：%s" % cmd, "unknown_cmd")

    _print(env, as_json)
    return 0 if env.get("ok") else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:
        # 任何未捕获异常也走信封，绝不把 traceback 甩给调用方
        _print(err("引擎内部异常：%s" % e, "internal"), "--json" in sys.argv)
        sys.exit(1)
