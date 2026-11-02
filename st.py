#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
st.py —— ワンクリック起動スクリプト（コンパイル + フォアグラウンド/バックグラウンド実行 + デーモンサービス）

────────────────────────── v2.1 修正説明 ──────────────────────────
このディレクトリはGo（14,080行）からDart v2.0.0へ100%書き換えられました：
bin/main.dart + lib/src/*.dart + pubspec.yaml，
go.mod / go.sum / *.go / app はすべて削除済み（README_DART.md参照）。

旧版のst.pyはGoプロジェクトとして動作するため、実行時に必ずエラーになります。根本原因は4つ：
  1) detect_project_dir() にフォールバックがない —— is_go_project() が False の後、
     無条件に return BASE_DIR/ddsh（存在しないパス）を返し、
     「❌ プロジェクトディレクトリが存在しません：.../ddsh/ddsh」が発生
  2) is_go_project() は go.mod/main.go を確認 —— ファイルは削除済みで常に False
  3) run_build() は go build -o app . を実行 —— go は無関係で必ず失敗
  4) run_app()/daemon/デーモンサービスは ./app を実行 —— そのファイルは存在しない

本版はDartツールチェーンに変更し、CLIの動作は100%互換：
   AOT（デフォルト、推奨）：dart compile exe bin/main.dart -o app  →  ./app
   JIT（自動フォールバック）：AOTが利用不可/失敗時に dart run bin/main.dart に切り替え
   2つのモードは「appが存在し実行可能か」で自動判定され、追加の状態ファイルは不要。

────────────────────────────────────────────────────────
実行モード
────────────────────────────────────────────────────────
  フォアグラウンド（デフォルト）：
    python3 st.py                コンパイル(必要時) -> フォアグラウンド実行

  バックグラウンド（ターミナルから切り離し、Termuxウィンドウを閉じても死なない）：
    python3 st.py --daemon       コンパイル(必要時) -> setsid バックグラウンド実行 + wake-lock
    python3 st.py --status       バックグラウンドプロセスの生存確認
    python3 st.py --logs         実行ログをリアルタイム表示
    python3 st.py --restart      停止 -> バックグラウンド再起動
    python3 st.py --stop         バックグラウンドプロセスを停止

  デーモンサービス（最強のキープアライブ：クラッシュ時に自動再起動 + Termux再起動時に自動起動）：
    python3 st.py --install-service    termux-servicesサービスを登録
    python3 st.py --remove-service    サービスをアンインストール

  その他：
    python3 st.py --rebuild      強制再コンパイル
    python3 st.py --skip-build   コンパイルをスキップ
    python3 st.py --no-aot       AOTをスキップし、直接 dart run（コンパイル時間を節約）

配置方法（両方対応）：
  1) st.py と ddsh/ が同じ階層  ->   python3 st.py
  2) st.py を ddsh/ 内に配置   ->   python3 ddsh/st.py
"""

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------------- 設定エリア（必要に応じて変更） ----------------
# ha.py 外部プラグイン（思考チェーンコード折りたたみ）は削除済み、自動実行しない
SERVICE_NAME = "ddsh"   # termux-services サービス名
ENTRY_REL = os.path.join("bin", "main.dart")   # Dartエントリ（プロジェクトディレクトリからの相対パス）
# ---------------------------------------------------


def log(msg):
    print(f"[st] {msg}", flush=True)


# ───────────────────── プロジェクト種別検出（Go → Dart） ─────────────────────
def is_dart_project(path):
    """Dartプロジェクト判定：pubspec.yaml + bin/main.dart が同時に存在。"""
    if not os.path.isdir(path):
        return False
    return (
        os.path.isfile(os.path.join(path, "pubspec.yaml"))
        and os.path.isfile(os.path.join(path, "bin", "main.dart"))
    )


def is_go_project(path):
    """旧呼び出しとの互換性のために保持；Go側は書き換えで削除済み、通知のみに使用。"""
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
    プロジェクトディレクトリを自動検出し、2つの配置方法に対応。
    修正点：どの分岐でも実在するディレクトリを必ず返し、存在しないパスは絶対に返さない。
    優先順位：環境変数 > スクリプト自身のディレクトリ > 同階層の ddsh/ > スクリプト自身のディレクトリ(フォールバック)
    """
    env = os.environ.get("PROJECT_DIR")
    if env:
        return os.path.abspath(env)

    # 1) st.py がプロジェクトルート直下にある（現在の実際のレイアウト）
    if is_project(BASE_DIR):
        return BASE_DIR

    # 2) st.py が親ディレクトリにあり、プロジェクトが ddsh/ サブディレクトリにある
    cand = os.path.join(BASE_DIR, "ddsh")
    if is_project(cand):
        return cand

    # 3) フォールバック：それでも BASE_DIR（実在する）を返し、run_build で明確な診断を出す。
    #    架空の、必ず存在しないパスを返さない。
    return BASE_DIR


PROJECT_DIR = detect_project_dir()
# チャット履歴の実際のディレクトリ（Dart側 dsChatDir = DATA_DIR/deepseek_chat，DATA_DIR=プロジェクト/data）
CHAT_DIR = os.path.join(PROJECT_DIR, "data", "deepseek_chat")
APP_PATH = os.path.join(PROJECT_DIR, "app")
ENTRY_PATH = os.path.join(PROJECT_DIR, ENTRY_REL)

# バックグラウンド実行関連のpid / ログファイル（data/ 下に配置、.gitignoreでカバー済み、gitを汚さない）
DATA_DIR = os.path.join(PROJECT_DIR, "data")
PID_FILE = os.path.join(DATA_DIR, "st.pid")
LOG_FILE = os.path.join(DATA_DIR, "st.log")


# ───────────────────────── コンパイル ─────────────────────────
def _source_mtime(project_dir):
    """
    プロジェクトソース内の最新更新時刻を返す。
    修正点：Dartソースは bin/ と lib/src/ に分散しているため、再帰的にスキャンする必要がある。
    旧版のようにトップレベルの *.go を listdir するだけではいけない。
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
        return float("inf")  # 読み取り失敗時はコンパイル必要とみなす
    return latest


def is_app_up_to_date():
    """アプリが存在し、すべてのDartソースコードよりも新しい場合、再コンパイルの必要はないとみなされます。"""
    if not os.path.isfile(APP_PATH):
        return False
    try:
        app_mtime = os.path.getmtime(APP_PATH)
    except OSError:
        return False
    return app_mtime >= _source_mtime(PROJECT_DIR)


def _ensure_package_config():
    """AOT コンパイル前に .dart_tool/package_config.json の存在を確認（依存ゼロの pub get）。"""
    cfg = os.path.join(PROJECT_DIR, ".dart_tool", "package_config.json")
    if os.path.isfile(cfg):
        return
    log("package_config.jsonが見つかりませんでした。dart pub get ...を実行してください。")
    try:
        subprocess.run(["dart", "pub", "get"], cwd=PROJECT_DIR)
    except FileNotFoundError:
        log("❌ dartコマンドが見つかりませんでした。")


def run_build(force_aot=True):
    """
    Dartプロジェクトをコンパイルする（古いコマンドrm -rf app && go build -o app .と同等）：
        dart compile exe bin/main.dart -o app
    失敗時は自動的にJITモード（dart run）にフォールバックし、直接終了しない。
    戻り値 True=AOT生成物が利用可能，False=JITにフォールバック済み。
    """
    if not os.path.isdir(PROJECT_DIR):
        log(f"❌ プロジェクトディレクトリが存在しません：{PROJECT_DIR}")
        log("   ヒント：st.pyをddshと同じレベルに置くか、ddsh/ディレクトリ内に置いて実行してください。")
        sys.exit(1)
    if not is_dart_project(PROJECT_DIR):
        log(f"⚠️ {PROJECT_DIR} Dartプロジェクトではないようです（pubspec.yamlまたはbin/main.dartが欠けています）")
        log("   引き続きコンパイルを試みますが、失敗した場合はディレクトリを確認してください。")
    if not os.path.isfile(ENTRY_PATH):
        log(f"⚠️ エントリーファイルが存在しません：{ENTRY_PATH}，JITモードで直接実行されます")
        return False

    # 古い生成物を削除（旧Goのappまたは前バージョンのAOT生成物）
    if os.path.exists(APP_PATH):
        try:
            if os.path.isdir(APP_PATH) and not os.path.islink(APP_PATH):
                shutil.rmtree(APP_PATH)
            else:
                os.remove(APP_PATH)
        except OSError as e:
            log(f"⚠️ 古いアプリの削除に失敗しました：{e}")

    if not force_aot:
        log("--no-aotが指定されているため、AOTコンパイルをスキップし、JITモードを使用します。")
        return False

    _ensure_package_config()

    # ★ 重要な修正：APP_PATH に直接書き込まない。
    #   旧実装は `dart compile exe ... -o app` で、前バージョンのappがまだ実行中（たとえ
    #   親プロセスst.pyがCtrl-Z / バックグラウンド残留でも）の場合、カーネルがETXTBSYで
    #   書き込みを拒否し、「Cannot open file ... Text file busy」が発生。
    #   一時ファイルにコンパイルし、os.replace()でアトミックにリネームする方式に変更 ——
    #   実行中の旧プロセスは自身のinodeを使い続け、新プロセスは新しいinodeを使うため、
    #   互いに干渉せず、0中断で切り替え可能。
    BUILD_TMP = APP_PATH + ".build.tmp"
    try:
        if os.path.exists(BUILD_TMP):
            os.remove(BUILD_TMP)
    except OSError as e:
        log(f"⚠️ 一時的な生成物のクリアに失敗：{e}")

    log(f"Dartプロジェクトのコンパイル（AOT）：{PROJECT_DIR}")
    log(f"  dart compile exe {ENTRY_REL} -o app.build.tmp  →  原子をappに置き換える")
    cmd = ["dart", "compile", "exe", ENTRY_REL, "-o", "app.build.tmp"]
    try:
        r = subprocess.run(cmd, cwd=PROJECT_DIR)
    except FileNotFoundError:
        log("❌ Dartコマンドが見つかりませんでした。Dart SDKがインストールされていることを確認し、PATHに追加してください。")
        log("   自動リトリートJITモードも一緒に失敗 → 終了")
        sys.exit(127)
    if r.returncode != 0:
        log(f"⚠️ AOTコンパイルに失敗しました。終了コード {r.returncode} → 自動的にJITモード（dart run）に戻す")
        try:
            if os.path.exists(BUILD_TMP):
                os.remove(BUILD_TMP)
        except OSError:
            pass
        return False

    # dart compile 生成物には x ビットがない場合がある（実測 600）
    try:
        os.chmod(BUILD_TMP, 0o755)
    except OSError as e:
        log(f"⚠️ 実行権限の設定に失敗しました：{e}")
    if not (os.path.isfile(BUILD_TMP) and os.access(BUILD_TMP, os.X_OK)):
        log("⚠️ AOT生成物が実行不可能 → JITモードに戻す（dart run）")
        return False

    try:
        os.replace(BUILD_TMP, APP_PATH)   # アトミックリネーム、ETXTBSYは今後発生不可能
    except OSError as e:
        log(f"⚠️ 原子置換アプリが失敗しました：{e}")
        try:
            if os.path.exists(BUILD_TMP):
                os.remove(BUILD_TMP)
        except OSError:
            pass
        return False
    log("✅ コンパイル完了（AOT、アトミック置換）")
    return True


def use_aot():
    """AOT生成物が存在し実行可能か —— ステートレス判定、daemon/サービスプロセスでも同様に適用。"""
    return os.path.isfile(APP_PATH) and os.access(APP_PATH, os.X_OK)


def app_cmd():
    """実際の実行コマンドを返す：優先AOT生成物、なければJIT（dart run）。"""
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
    起動前に「本プロジェクトの」旧インスタンスをクリーンアップ：
      - 旧appプロセス（AOT生成物パスに一致）
      - 旧dart run bin/main.dartプロセス（同一PROJECT_DIR）
    自プロジェクト関連プロセスのみをkillし、他のプログラムには一切触れない。現在のst.pyも誤ってkillしない。
    2つの問題を解決：Text file busy（旧プロセスがappを占有）+ 9999ポートが占有。
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
            log(f"古いインスタンスのクリア pid={pid}")
        except OSError:
            pass
    # 最大3秒の穏やかな終了を待ち、その後強制kill
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
                log(f"古いインスタンスを強制的に削除する pid={pid}")
            except OSError:
                pass
        time.sleep(0.2)
    return victims


def wait_port_free(port, timeout=5.0):
    """ポートの解放を待機、Trueで利用可能。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not port_in_use(port):
            return True
        time.sleep(0.2)
    return not port_in_use(port)


def read_port():
    """PORT環境変数 / .envからポートを読み取り、デフォルト9999。"""
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
    """起動前にポートが利用可能であることを確認、そうでなければ旧インスタンスをクリーンアップして待機。"""
    port = read_port()
    if not port_in_use(port):
        return True
    log(f"⚠️ ポート {port} 既に使用中です。このプロジェクトの古いインスタンスを削除してみてください...")
    kill_stale_instances()
    ok = wait_port_free(port, 6.0)
    if ok:
        log(f"✅ ポート {port} 解放済み")
    else:
        log(f"❌ ポート {port} 他のプログラムによって使用中です。手動で処理してください：ss -ltnp | grep {port}")
    return ok


def run_app():
    """フォアグラウンド実行（AOTの./appまたはJITのdart run），インタラクティブ、ターミナル直通。"""
    ensure_port_ready()
    cmd = app_cmd()
    log(f"実行：{' '.join(cmd)} ...")
    try:
        return subprocess.call(cmd, cwd=PROJECT_DIR)
    except FileNotFoundError:
        log("❌ 起動失敗：実行可能ファイルまたはdartコマンドが見つかりません")
        log("   まずは次のコマンドを実行してください：python3 st.py --rebuild")
        return 127


# ───────────────────────── バックグラウンド実行（daemon） ─────────────────────────
def _ensure_data_dir():
    os.makedirs(DATA_DIR, exist_ok=True)


def acquire_wakelock():
    """ウェイクロックを取得し、CPUの深いスリープを防止（Termux:API提供）。"""
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
        os.kill(pid, 0)  # 検出のみ、実際にシグナルは送らない
        return True
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        return False


def run_app_daemon():
    """
    バックグラウンド実行：
      - start_new_session=True はsetsidと同等、ターミナルセッションから切り離し、ウィンドウを閉じてもSIGHUPを受信しない
      - stdin は /dev/null を指し、stdout/stderr はログにリダイレクト
      - pid を PID_FILE に記録
      - termux-wake-lock を試行しCPUスリープを防止
    """
    ensure_port_ready()
    cmd = app_cmd()
    if not use_aot() and not os.path.isfile(ENTRY_PATH):
        log(f"❌ 実行可能なアプリもなく、入り口も見つからない：{ENTRY_PATH}")
        log("   まず、以下のコマンドを実行してください：python3 st.py --rebuild")
        return 1

    # 既に生存プロセスがある場合は通知
    old_pid = read_pid()
    if old_pid and is_running(old_pid):
        log(f"⚠️ アプリはバックグラウンドで実行中です（pid={old_pid}），まず「stop」してから再起動する")
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
        start_new_session=True,  # setsid：新セッション、制御端末から切り離し
        close_fds=True,
    )
    logf.close()
    write_pid(proc.pid)

    if acquire_wakelock():
        log("✅ termux-wake-lockを取得しました（CPUスリープ防止機能）")
    else:
        log("⚠️ ウェイクロックを取得できませんでした（オプションで、バックグラウンドでの実行には影響しません）")

    log(f"✅ アプリはバックグラウンドで実行中です。（pid={proc.pid}，{'AOT' if use_aot() else 'JIT'}）")
    log(f"   ログファイル：{LOG_FILE}")
    log(f"   ログを確認する：python3 st.py --logs")
    log(f"   状態を確認する：python3 st.py --status")
    log(f"   プロセスを停止する：python3 st.py --stop")
    log("   ヒント：Termuxウィンドウを閉じてもアプリは終了しません。Androidシステムによるアプリの終了については、--install-serviceを参照してください。")
    return 0


def stop_app():
    """バックグラウンド実行中のappを停止。"""
    pid = read_pid()
    if not pid or not is_running(pid):
        log("ℹ️ 実行中のバックグラウンドアプリは検出されませんでした")
        clear_pid()
        return 0
    log(f"停止 app（pid={pid}）...")
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as e:
        log(f"⚠️ SIGTERMを送信するに失敗しました：{e}")
    for _ in range(10):
        time.sleep(0.5)
        if not is_running(pid):
            break
    if is_running(pid):
        log("プロセスが終了していないため、SIGKILLを送信します...")
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError as e:
            log(f"⚠️ SIGKILLを送信するに失敗しました：{e}")
        time.sleep(0.5)
    clear_pid()
    log("✅ 停止済み")
    return 0


def show_status():
    pid = read_pid()
    if pid and is_running(pid):
        log(f"✅ アプリがバックグラウンドで実行中（pid={pid}）")
        log(f"   パターン：{'AOT（./app）' if use_aot() else 'JIT（dart run）'}")
        log(f"   ログ：{LOG_FILE}")
    else:
        log("ℹ️ アプリがバックグラウンドで実行されていません")
        if pid:
            clear_pid()
    return 0


def tail_logs(lines=50):
    if not os.path.isfile(LOG_FILE):
        log(f"⚠️ ログファイルが存在しません：{LOG_FILE}")
        return 0
    log(f"最近の{lines}行のログ（{LOG_FILE}）：")
    try:
        with open(LOG_FILE, "rb") as f:
            # 最後のN行を読み取る
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
        log(f"⚠️ ログの読み取りに失敗しました：{e}")
    return 0


# ───────────────────────── termux-services デーモンサービス ─────────────────────────
def service_dir():
    return os.path.expanduser(f"~/.termux/services/{SERVICE_NAME}")


def install_service():
    """
    termux-servicesサービスを登録：
      - クラッシュ時に自動再起動（runit監視）
      - Termux再起動後に自動起動
      - 起動時自動起動（Termux:Bootと連携）
    これが「Termuxがkillされても問題ない」最強のキープアライブ形態。
    修正点：旧版は exec ./app をハードコード；現在は「AOT生成物があればそれを実行、なければdart run」に変更。
    """
    if not shutil.which("sv"):
        log("❌ termux-servicesがインストールされていません。まず、以下のコマンドを実行してください：pkg install termux-services")
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

    log(f"サービススクリプトに書き込まれました：{run_path}")
    log("サービスを有効にして起動する ...")
    subprocess.run(["sv-enable", SERVICE_NAME], check=False)
    subprocess.run(["sv", "up", SERVICE_NAME], check=False)
    time.sleep(1.5)
    r = subprocess.run(["sv", "status", SERVICE_NAME], capture_output=True, text=True)
    log(f"サービス状態：{r.stdout.strip() or r.stderr.strip()}")
    log("✅ セキュリティサービスがインストールされました。クラッシュした場合は自動的に再起動し、Termuxが再開すると自動的に起動します。")
    log("   管理コマンド：sv up ddsh / sv down ddsh / sv status ddsh")
    return 0


def remove_service():
    if not shutil.which("sv"):
        log("ℹ️ termux-servicesはインストールされていないので、アンインストールする必要はありません。")
        return 0
    log("サービスを停止し、アンインストールする ...")
    subprocess.run(["sv", "down", SERVICE_NAME], check=False)
    subprocess.run(["sv-disable", SERVICE_NAME], check=False)
    sdir = service_dir()
    if os.path.isdir(sdir):
        shutil.rmtree(sdir, ignore_errors=True)
    log("✅ サービスがアンインストールされました")
    return 0


# ───────────────────────── メインフロー ─────────────────────────
def _maybe_build(args):
    """引数に応じてコンパイルするか決定。"""
    if args.skip_build:
        log("コンパイルをスキップ（--skip-build）")
        if not use_aot():
            log("ℹ️ AOT生成物なし → 今回はJITモードで実行（dart run）")
    elif args.rebuild:
        log("強制的に再コンパイルする（--rebuild）")
        run_build(force_aot=not args.no_aot)
    elif is_app_up_to_date():
        log("アプリが既に存在し、最新であることが検出されたため、コンパイルをスキップします。")
    else:
        run_build(force_aot=not args.no_aot)


def main():
    parser = argparse.ArgumentParser(
        description="st.py —— ワンクリック起動（コンパイル + フォアグラウンド/バックグラウンド実行 + デーモンサービス）"
    )
    # 実行モード
    parser.add_argument("--daemon", action="store_true", help="バックグラウンド実行（ターミナルから切り離し、ウィンドウを閉じても死なない）")
    parser.add_argument("--stop", action="store_true", help="バックグラウンド実行中のappを停止")
    parser.add_argument("--status", action="store_true", help="バックグラウンドappの状態を確認")
    parser.add_argument("--restart", action="store_true", help="停止 -> バックグラウンド再起動")
    parser.add_argument("--logs", type=int, nargs="?", const=50, metavar="N",
                        help="バックグラウンドログを表示（デフォルト最近50行）")
    parser.add_argument("--install-service", action="store_true", help="termux-servicesデーモンサービスを登録")
    parser.add_argument("--remove-service", action="store_true", help="termux-servicesサービスをアンインストール")
    # 既存の引数
    parser.add_argument("--no-hack", action="store_true", help="（廃止）外部プラグインは削除済み、引数は互換性のために保持")
    parser.add_argument("--skip-build", action="store_true", help="コンパイルをスキップ")
    parser.add_argument("--rebuild", action="store_true", help="強制再コンパイル")
    parser.add_argument("--no-aot", action="store_true",
                        help="AOTコンパイルを行わず、直接dart run（コンパイル時間を節約、起動はやや遅い）")
    parser.add_argument("--watch", action="store_true",
                        help="（廃止）外部プラグインは削除済み、引数は互換性のために保持")
    parser.add_argument("--clean", action="store_true", help="（廃止）外部プラグインは削除済み、何も処理しない")
    args = parser.parse_args()

    log(f"プロジェクトディレクトリ：{PROJECT_DIR}")
    log(f"チャット履歴のディレクトリ：{CHAT_DIR}")

    # ---- 純粋な管理コマンド、相互排他かつ即時実行 ----
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
        log("ℹ️ --clean は廃止されました：ha.pyの外部プラグインが削除され、何も処理されません")
        return 0

    # ---- 再起動：停止 -> バックグラウンド起動 ----
    if args.restart:
        _maybe_build(args)
        stop_app()
        return run_app_daemon()

    # ---- コンパイル ----
    _maybe_build(args)

    # ---- バックグラウンド実行 ----
    if args.daemon:
        return run_app_daemon()

    # ---- フォアグラウンド実行（デフォルト、元のロジックを維持） ----
    code = 1
    try:
        code = run_app()
        log(f"Dartプログラムが終了し、終了コード {code}")
    finally:
        pass

    sys.exit(code)


if __name__ == "__main__":
    main()