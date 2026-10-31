#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
st.py —— 一键启动脚本（编译 + 前台/后台运行 + 守护服务）

────────────────────────── v2.1 修复说明 ──────────────────────────
本目录已从 Go（14,080 行）100% 重写为 Dart v2.0.0：
bin/main.dart + lib/src/*.dart + pubspec.yaml，
go.mod / go.sum / *.go / app 已全部删除（见 README_DART.md）。

旧版 st.py 仍按 Go 项目运作，运行时必然报错，共 4 个根因：
  1) detect_project_dir() 无兜底 —— is_go_project() 为 False 后，
     仍无条件 return BASE_DIR/ddsh（不存在的路径），
     于是报「❌ 项目目录不存在：.../ddsh/ddsh」
  2) is_go_project() 查 go.mod/main.go —— 文件已删，永远 False
  3) run_build() 执行 go build -o app . —— go 已无关，必然失败
  4) run_app()/daemon/守护服务执行 ./app —— 该文件不存在

本版改为 Dart 工具链，CLI 行为 100% 兼容：
   AOT（默认、推荐）：dart compile exe bin/main.dart -o app  →  ./app
   JIT（自动回退）  ：AOT 不可用/失败时改用 dart run bin/main.dart
   两种模式由「app 是否存在且可执行」自动判定，无需额外状态文件。

────────────────────────────────────────────────────────
运行模式
────────────────────────────────────────────────────────
  前台（默认）：
    python3 st.py                编译(如需) -> 前台运行

  后台（脱离终端，关 Termux 窗口也不死）：
    python3 st.py --daemon       编译(如需) -> setsid 后台运行 + wake-lock
    python3 st.py --status       查看后台进程是否存活
    python3 st.py --logs         实时看运行日志
    python3 st.py --restart      停止 -> 再后台启动
    python3 st.py --stop         停止后台进程

  守护服务（最强保活：崩溃自动重启 + Termux 重开自动拉起）：
    python3 st.py --install-service   注册 termux-services 服务
    python3 st.py --remove-service    卸载服务

  其它：
    python3 st.py --rebuild      强制重新编译
    python3 st.py --skip-build   跳过编译
    python3 st.py --no-aot       跳过 AOT，直接用 dart run（省编译时间）

放置方式（两种都支持）：
  1) st.py 与 ddsh/ 同级  ->   python3 st.py
  2) st.py 放在 ddsh/ 内   ->   python3 ddsh/st.py
"""

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------------- 配置区（按需修改） ----------------
# ha.py 外挂（思考链代码折叠）已移除，不再自动执行
SERVICE_NAME = "ddsh"   # termux-services 服务名
ENTRY_REL = os.path.join("bin", "main.dart")   # Dart 入口（相对项目目录）
# ---------------------------------------------------


def log(msg):
    print(f"[st] {msg}", flush=True)


# ───────────────────── 项目类型探测（Go → Dart） ─────────────────────
def is_dart_project(path):
    """Dart 项目判定：pubspec.yaml + bin/main.dart 同时存在。"""
    if not os.path.isdir(path):
        return False
    return (
        os.path.isfile(os.path.join(path, "pubspec.yaml"))
        and os.path.isfile(os.path.join(path, "bin", "main.dart"))
    )


def is_go_project(path):
    """保留以兼容旧调用；Go 侧已随重写移除，仅用于提示。"""
    if not os.path.isdir(path):
        return False
    return (
        os.path.isfile(os.path.join(path, "go.mod"))
        or os.path.isfile(os.path.join(path, "main.go"))
    )


def is_project(path):
    return is_dart_project(path) or is_go_project(path)


def detect_project_dir():
    """
    自动探测项目目录，兼容两种放置方式。
    修复点：任何分支都必须返回真实存在的目录，绝不返回不存在的路径。
    优先级：环境变量 > 脚本自身目录 > 同级 ddsh/ > 脚本自身目录(兜底)
    """
    env = os.environ.get("PROJECT_DIR")
    if env:
        return os.path.abspath(env)

    # 1) st.py 直接放在项目根目录（当前实际布局）
    if is_project(BASE_DIR):
        return BASE_DIR

    # 2) st.py 在父目录，项目在 ddsh/ 子目录
    cand = os.path.join(BASE_DIR, "ddsh")
    if is_project(cand):
        return cand

    # 3) 兜底：仍返回 BASE_DIR（真实存在），由 run_build 给出明确诊断，
    #    而不是返回一个凭空拼出来、必然不存在的路径。
    return BASE_DIR


PROJECT_DIR = detect_project_dir()
# 聊天记录真实目录（Dart 侧 dsChatDir = DATA_DIR/deepseek_chat，DATA_DIR=项目/data）
CHAT_DIR = os.path.join(PROJECT_DIR, "data", "deepseek_chat")
APP_PATH = os.path.join(PROJECT_DIR, "app")
ENTRY_PATH = os.path.join(PROJECT_DIR, ENTRY_REL)

# 后台运行相关的 pid / 日志文件（放 data/ 下，已被 .gitignore 覆盖，不污染 git）
DATA_DIR = os.path.join(PROJECT_DIR, "data")
PID_FILE = os.path.join(DATA_DIR, "st.pid")
LOG_FILE = os.path.join(DATA_DIR, "st.log")


# ───────────────────────── 编译 ─────────────────────────
def _source_mtime(project_dir):
    """
    返回项目源码中最新的修改时间。
    修复点：Dart 源码分布在 bin/ 与 lib/src/，必须递归扫描，
    不能像旧版那样只 listdir 顶层 *.go。
    """
    latest = 0.0
    skip_dirs = {".dart_tool", "build", ".git", ".backup_tmp", "data", "node_modules"}
    try:
        for root, dirs, files in os.walk(project_dir):
            dirs[:] = [d for d in dirs if d not in skip_dirs]
            for name in files:
                if name.endswith(".dart") or name in ("pubspec.yaml", "pubspec.lock"):
                    try:
                        latest = max(latest, os.path.getmtime(os.path.join(root, name)))
                    except OSError:
                        pass
    except OSError:
        return float("inf")  # 读取失败则视为需要编译
    return latest


def is_app_up_to_date():
    """app 存在且比所有 Dart 源码都新，则视为无需重新编译。"""
    if not os.path.isfile(APP_PATH):
        return False
    try:
        app_mtime = os.path.getmtime(APP_PATH)
    except OSError:
        return False
    return app_mtime >= _source_mtime(PROJECT_DIR)


def _ensure_package_config():
    """AOT 编译前确保 .dart_tool/package_config.json 存在（零依赖 pub get）。"""
    cfg = os.path.join(PROJECT_DIR, ".dart_tool", "package_config.json")
    if os.path.isfile(cfg):
        return
    log("未找到 package_config.json，执行 dart pub get ...")
    try:
        subprocess.run(["dart", "pub", "get"], cwd=PROJECT_DIR)
    except FileNotFoundError:
        log("❌ 未找到 dart 命令")


def run_build(force_aot=True):
    """
    编译 Dart 项目（等价旧命令 rm -rf app && go build -o app .）：
        dart compile exe bin/main.dart -o app
    失败时自动回退 JIT 模式（dart run），不直接退出。
    返回 True=AOT 产物可用，False=已回退 JIT。
    """
    if not os.path.isdir(PROJECT_DIR):
        log(f"❌ 项目目录不存在：{PROJECT_DIR}")
        log("   提示：请把 st.py 放在 ddsh 同级，或放进 ddsh/ 目录内运行")
        sys.exit(1)
    if not is_dart_project(PROJECT_DIR):
        log(f"⚠️ {PROJECT_DIR} 看起来不是 Dart 项目（缺 pubspec.yaml 或 bin/main.dart）")
        log("   仍尝试编译，如失败请检查目录")
    if not os.path.isfile(ENTRY_PATH):
        log(f"⚠️ 入口文件不存在：{ENTRY_PATH}，将直接以 JIT 模式运行")
        return False

    # 清掉旧产物（旧 Go 的 app 或上一版 AOT 产物）
    if os.path.exists(APP_PATH):
        try:
            if os.path.isdir(APP_PATH) and not os.path.islink(APP_PATH):
                shutil.rmtree(APP_PATH)
            else:
                os.remove(APP_PATH)
        except OSError as e:
            log(f"⚠️ 删除旧 app 失败：{e}")

    if not force_aot:
        log("已指定 --no-aot，跳过 AOT 编译，使用 JIT 模式")
        return False

    _ensure_package_config()

    # ★ 关键修复：绝不直接写 APP_PATH。
    #   旧实现是 `dart compile exe ... -o app`，只要上一版 app 仍在运行（哪怕只是
    #   父进程 st.py 被 Ctrl-Z / 后台残留），内核就会以 ETXTBSY 拒绝写入，
    #   报 “Cannot open file ... Text file busy”。改为编译到临时文件，
    #   再 os.replace() 原子换名 —— 运行中的旧进程继续用它自己的 inode，
    #   新进程用新 inode，二者互不干扰，0 中断。
    BUILD_TMP = APP_PATH + ".build.tmp"
    try:
        if os.path.exists(BUILD_TMP):
            os.remove(BUILD_TMP)
    except OSError as e:
        log(f"⚠️ 清理临时产物失败：{e}")

    log(f"编译 Dart 项目（AOT）：{PROJECT_DIR}")
    log(f"  dart compile exe {ENTRY_REL} -o app.build.tmp  →  原子替换为 app")
    cmd = ["dart", "compile", "exe", ENTRY_REL, "-o", "app.build.tmp"]
    try:
        r = subprocess.run(cmd, cwd=PROJECT_DIR)
    except FileNotFoundError:
        log("❌ 未找到 dart 命令，请确认已安装 Dart SDK 并加入 PATH")
        log("   自动回退 JIT 模式也一并失败 → 退出")
        sys.exit(127)
    if r.returncode != 0:
        log(f"⚠️ AOT 编译失败，退出码 {r.returncode} → 自动回退 JIT 模式（dart run）")
        try:
            if os.path.exists(BUILD_TMP):
                os.remove(BUILD_TMP)
        except OSError:
            pass
        return False

    # dart compile 产物可能没有 x 位（实测 600）
    try:
        os.chmod(BUILD_TMP, 0o755)
    except OSError as e:
        log(f"⚠️ 设置执行权限失败：{e}")
    if not (os.path.isfile(BUILD_TMP) and os.access(BUILD_TMP, os.X_OK)):
        log("⚠️ AOT 产物不可执行 → 回退 JIT 模式（dart run）")
        return False

    try:
        os.replace(BUILD_TMP, APP_PATH)   # 原子换名，ETXTBSY 从此不可能再出现
    except OSError as e:
        log(f"⚠️ 原子替换 app 失败：{e}")
        try:
            if os.path.exists(BUILD_TMP):
                os.remove(BUILD_TMP)
        except OSError:
            pass
        return False
    log("✅ 编译完成（AOT，原子替换）")
    return True


def use_aot():
    """AOT 产物是否存在且可执行 —— 无状态判定，daemon/服务进程同样适用。"""
    return os.path.isfile(APP_PATH) and os.access(APP_PATH, os.X_OK)


def app_cmd():
    """返回实际运行命令：优先 AOT 产物，否则 JIT（dart run）。"""
    if use_aot():
        return [APP_PATH]
    return ["dart", "run", ENTRY_REL]
def _proc_cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            raw = f.read()
        return raw.replace(b"\x00", b" ").decode("utf-8", "replace").strip()
    except Exception:
        return ""


def port_in_use(port):
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.3)
    try:
        return s.connect_ex(("127.0.0.1", int(port))) == 0
    finally:
        try:
            s.close()
        except Exception:
            pass


def kill_stale_instances():
    """
    启动前清理「本项目的」旧实例：
      - 旧 app 进程（AOT 产物路径命中）
      - 旧 dart run bin/main.dart 进程（同一 PROJECT_DIR）
    只杀自己项目相关进程，绝不碰其它程序；也不会误杀当前 st.py。
    解决两件事：Text file busy（旧进程占着 app）+ 9999 端口被占。
    """
    me = os.getpid()
    victims = []
    try:
        names = os.listdir("/proc")
    except OSError:
        return []
    for name in names:
        if not name.isdigit():
            continue
        pid = int(name)
        if pid == me:
            continue
        cl = _proc_cmdline(pid)
        if not cl:
            continue
        hit = False
        if APP_PATH in cl:
            hit = True
        elif "bin/main.dart" in cl and PROJECT_DIR in cl:
            hit = True
        if hit:
            victims.append(pid)

    for pid in victims:
        try:
            os.kill(pid, signal.SIGTERM)
            log(f"清理旧实例 pid={pid}")
        except OSError:
            pass
    # 最多等 3 秒优雅退出，之后强杀
    for _ in range(30):
        alive = []
        for pid in victims:
            try:
                os.kill(pid, 0)
                alive.append(pid)
            except OSError:
                pass
        if not alive:
            break
        time.sleep(0.1)
    else:
        for pid in alive:
            try:
                os.kill(pid, signal.SIGKILL)
                log(f"强杀旧实例 pid={pid}")
            except OSError:
                pass
        time.sleep(0.2)
    return victims


def wait_port_free(port, timeout=5.0):
    """等待端口释放，返回 True 表示可用。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not port_in_use(port):
            return True
        time.sleep(0.2)
    return not port_in_use(port)


def read_port():
    """从 PORT 环境变量 / .env 读取端口，默认 9999。"""
    v = os.environ.get("PORT")
    if v and v.strip().isdigit():
        return int(v.strip())
    env_path = os.path.join(PROJECT_DIR, ".env")
    try:
        with open(env_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:]
                if line.startswith("PORT"):
                    k, _, val = line.partition("=")
                    if k.strip() == "PORT" and val.strip().isdigit():
                        return int(val.strip())
    except OSError:
        pass
    return 9999


def ensure_port_ready():
    """启动前确保端口可用，否则清理旧实例后等待。"""
    port = read_port()
    if not port_in_use(port):
        return True
    log(f"⚠️ 端口 {port} 已被占用，尝试清理本项目旧实例 ...")
    kill_stale_instances()
    ok = wait_port_free(port, 6.0)
    if ok:
        log(f"✅ 端口 {port} 已释放")
    else:
        log(f"❌ 端口 {port} 仍被其它程序占用，请手动处理：ss -ltnp | grep {port}")
    return ok


def run_app():
    """前台运行（AOT 的 ./app 或 JIT 的 dart run），交互式，直通终端。"""
    ensure_port_ready()
    cmd = app_cmd()
    log(f"运行：{' '.join(cmd)} ...")
    try:
        return subprocess.call(cmd, cwd=PROJECT_DIR)
    except FileNotFoundError:
        log("❌ 启动失败：找不到可执行文件或 dart 命令")
        log("   请先执行：python3 st.py --rebuild")
        return 127


# ───────────────────────── 后台运行（daemon） ─────────────────────────
def _ensure_data_dir():
    os.makedirs(DATA_DIR, exist_ok=True)


def acquire_wakelock():
    """获取唤醒锁，防止 CPU 进入深度休眠（Termux:API 提供）。"""
    try:
        r = subprocess.run(["termux-wake-lock"], capture_output=True, timeout=10)
        return r.returncode == 0
    except Exception:
        return False


def read_pid():
    try:
        with open(PID_FILE) as f:
            return int(f.read().strip())
    except Exception:
        return None


def write_pid(pid):
    _ensure_data_dir()
    with open(PID_FILE, "w") as f:
        f.write(str(pid))


def clear_pid():
    try:
        if os.path.exists(PID_FILE):
            os.remove(PID_FILE)
    except OSError:
        pass


def is_running(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)  # 仅探测，不真正发信号
        return True
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        return False


def run_app_daemon():
    """
    后台运行：
      - start_new_session=True 等价 setsid，脱离终端会话，关窗口不收到 SIGHUP
      - stdin 指向 /dev/null，stdout/stderr 重定向到日志
      - 记录 pid 到 PID_FILE
      - 尝试 termux-wake-lock 防 CPU 休眠
    """
    ensure_port_ready()
    cmd = app_cmd()
    if not use_aot() and not os.path.isfile(ENTRY_PATH):
        log(f"❌ 既无可执行 app，也找不到入口：{ENTRY_PATH}")
        log("   请先执行：python3 st.py --rebuild")
        return 1

    # 若已有存活进程，提示
    old_pid = read_pid()
    if old_pid and is_running(old_pid):
        log(f"⚠️ app 已在后台运行（pid={old_pid}），先 --stop 再启动")
        return 1
    clear_pid()

    _ensure_data_dir()
    logf = open(LOG_FILE, "ab")
    logf.write(b"\n" + b"=" * 50 + b"\n")
    logf.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] st.py daemon start "
               f"({'AOT' if use_aot() else 'JIT'})\n".encode())
    logf.flush()

    proc = subprocess.Popen(
        cmd,
        cwd=PROJECT_DIR,
        stdin=subprocess.DEVNULL,
        stdout=logf,
        stderr=subprocess.STDOUT,
        start_new_session=True,  # setsid：新会话、脱离控制终端
        close_fds=True,
    )
    logf.close()
    write_pid(proc.pid)

    if acquire_wakelock():
        log("✅ 已获取 termux-wake-lock（防 CPU 休眠）")
    else:
        log("⚠️ 未能获取 wake-lock（可选，不影响后台运行）")

    log(f"✅ app 已在后台运行（pid={proc.pid}，{'AOT' if use_aot() else 'JIT'}）")
    log(f"   日志文件：{LOG_FILE}")
    log(f"   查看日志：python3 st.py --logs")
    log(f"   查看状态：python3 st.py --status")
    log(f"   停止进程：python3 st.py --stop")
    log("   提示：关掉 Termux 窗口不会杀它；若 Android 系统杀应用，见 --install-service")
    return 0


def stop_app():
    """停止后台运行的 app。"""
    pid = read_pid()
    if not pid or not is_running(pid):
        log("ℹ️ 没有检测到运行中的后台 app")
        clear_pid()
        return 0
    log(f"停止 app（pid={pid}）...")
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as e:
        log(f"⚠️ 发送 SIGTERM 失败：{e}")
    for _ in range(10):
        time.sleep(0.5)
        if not is_running(pid):
            break
    if is_running(pid):
        log("进程未退出，发送 SIGKILL ...")
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError as e:
            log(f"⚠️ 发送 SIGKILL 失败：{e}")
        time.sleep(0.5)
    clear_pid()
    log("✅ 已停止")
    return 0


def show_status():
    pid = read_pid()
    if pid and is_running(pid):
        log(f"✅ app 正在后台运行（pid={pid}）")
        log(f"   模式：{'AOT（./app）' if use_aot() else 'JIT（dart run）'}")
        log(f"   日志：{LOG_FILE}")
    else:
        log("ℹ️ app 未在后台运行")
        if pid:
            clear_pid()
    return 0


def tail_logs(lines=50):
    if not os.path.isfile(LOG_FILE):
        log(f"⚠️ 日志文件不存在：{LOG_FILE}")
        return 0
    log(f"最近 {lines} 行日志（{LOG_FILE}）：")
    try:
        with open(LOG_FILE, "rb") as f:
            # 读取最后 N 行
            f.seek(0, os.SEEK_END)
            size = f.tell()
            chunk = 8192
            data = b""
            pos = size
            while pos > 0 and data.count(b"\n") < lines:
                step = min(chunk, pos)
                pos -= step
                f.seek(pos)
                data = f.read(step) + data
            lines_list = data.splitlines()
            tail = lines_list[-lines:] if len(lines_list) > lines else lines_list
            for ln in tail:
                print(ln.decode("utf-8", errors="replace"))
    except Exception as e:
        log(f"⚠️ 读取日志失败：{e}")
    return 0


# ───────────────────────── termux-services 守护服务 ─────────────────────────
def service_dir():
    return os.path.expanduser(f"~/.termux/services/{SERVICE_NAME}")


def install_service():
    """
    注册 termux-services 服务：
      - 崩溃自动重启（runit 监控）
      - Termux 重新打开后自动拉起
      - 开机自启（配合 Termux:Boot）
    这是"就算 Termux 被杀也没关系"的最强保活形态。
    修复点：旧版写死 exec ./app；现改为「有 AOT 产物就跑它，否则 dart run」。
    """
    if not shutil.which("sv"):
        log("❌ 未安装 termux-services，请先执行：pkg install termux-services")
        return 1

    sdir = service_dir()
    os.makedirs(sdir, exist_ok=True)

    run_path = os.path.join(sdir, "run")
    run_script = (
        "#!/data/data/com.termux/files/usr/bin/sh\n"
        "exec 2>&1\n"
        f"cd {PROJECT_DIR}\n"
        "termux-wake-lock\n"
        "if [ -x ./app ]; then\n"
        "  exec ./app\n"
        "else\n"
        "  exec dart run bin/main.dart\n"
        "fi\n"
    )
    with open(run_path, "w") as f:
        f.write(run_script)
    os.chmod(run_path, 0o755)

    log(f"已写入服务脚本：{run_path}")
    log("启用服务并启动 ...")
    subprocess.run(["sv-enable", SERVICE_NAME], check=False)
    subprocess.run(["sv", "up", SERVICE_NAME], check=False)
    time.sleep(1.5)
    r = subprocess.run(["sv", "status", SERVICE_NAME], capture_output=True, text=True)
    log(f"服务状态：{r.stdout.strip() or r.stderr.strip()}")
    log("✅ 守护服务已安装。崩溃会自动重启，Termux 重开后自动拉起。")
    log("   管理命令：sv up ddsh / sv down ddsh / sv status ddsh")
    return 0


def remove_service():
    if not shutil.which("sv"):
        log("ℹ️ 未安装 termux-services，无需卸载")
        return 0
    log("停止并卸载服务 ...")
    subprocess.run(["sv", "down", SERVICE_NAME], check=False)
    subprocess.run(["sv-disable", SERVICE_NAME], check=False)
    sdir = service_dir()
    if os.path.isdir(sdir):
        shutil.rmtree(sdir, ignore_errors=True)
    log("✅ 服务已卸载")
    return 0


# ───────────────────────── 主流程 ─────────────────────────
def _maybe_build(args):
    """按参数决定是否编译。"""
    if args.skip_build:
        log("跳过编译（--skip-build）")
        if not use_aot():
            log("ℹ️ 无 AOT 产物 → 本次以 JIT 模式运行（dart run）")
    elif args.rebuild:
        log("强制重新编译（--rebuild）")
        run_build(force_aot=not args.no_aot)
    elif is_app_up_to_date():
        log("检测到 app 已存在且为最新，跳过编译")
    else:
        run_build(force_aot=not args.no_aot)


def main():
    parser = argparse.ArgumentParser(
        description="st.py —— 一键启动（编译 + 前台/后台运行 + 守护服务）"
    )
    # 运行模式
    parser.add_argument("--daemon", action="store_true", help="后台运行（脱离终端，关窗口不死）")
    parser.add_argument("--stop", action="store_true", help="停止后台运行的 app")
    parser.add_argument("--status", action="store_true", help="查看后台 app 状态")
    parser.add_argument("--restart", action="store_true", help="停止 -> 后台重启")
    parser.add_argument("--logs", type=int, nargs="?", const=50, metavar="N",
                        help="查看后台日志（默认最近 50 行）")
    parser.add_argument("--install-service", action="store_true", help="注册 termux-services 守护服务")
    parser.add_argument("--remove-service", action="store_true", help="卸载 termux-services 服务")
    # 原有参数
    parser.add_argument("--no-hack", action="store_true", help="（已废弃）外挂已移除，参数仅保留兼容")
    parser.add_argument("--skip-build", action="store_true", help="跳过编译")
    parser.add_argument("--rebuild", action="store_true", help="强制重新编译")
    parser.add_argument("--no-aot", action="store_true",
                        help="不做 AOT 编译，直接用 dart run（省编译时间，启动稍慢）")
    parser.add_argument("--watch", action="store_true",
                        help="（已废弃）外挂已移除，参数仅保留兼容")
    parser.add_argument("--clean", action="store_true", help="（已废弃）外挂已移除，不再做任何处理")
    args = parser.parse_args()

    log(f"项目目录：{PROJECT_DIR}")
    log(f"聊天记录目录：{CHAT_DIR}")

    # ---- 纯管理命令，互斥且立即执行 ----
    if args.stop:
        return stop_app()
    if args.status:
        return show_status()
    if args.logs is not None:
        return tail_logs(args.logs)
    if args.install_service:
        return install_service()
    if args.remove_service:
        return remove_service()
    if args.clean:
        log("ℹ️ --clean 已废弃：ha.py 外挂已移除，不做任何处理")
        return 0

    # ---- 重启：停止 -> 后台启动 ----
    if args.restart:
        _maybe_build(args)
        stop_app()
        return run_app_daemon()

    # ---- 编译 ----
    _maybe_build(args)

    # ---- 后台运行 ----
    if args.daemon:
        return run_app_daemon()

    # ---- 前台运行（默认，保持原逻辑） ----
    code = 1
    try:
        code = run_app()
        log(f"Dart 程序退出，退出码 {code}")
    finally:
        pass

    sys.exit(code)


if __name__ == "__main__":
    main()
