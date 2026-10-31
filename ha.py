#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ha.py —— 聊天记录优化外挂（思考链代码折叠）

解决的问题
============
Go 项目在工具模式下运行，思考链(reasoning)会输出大量代码。
这些代码被原样写入聊天记录后，GUI 渲染端会因为代码块过长、过多而严重卡顿。

解决思路
========
不删除代码（删除会导致无法复盘调试，是错误做法），而是把超长代码块
用 <details>/<summary> 折叠标记包裹：
  * 默认折叠 —— 渲染时只显示一行摘要，不展开大段代码，不卡顿
  * 点击展开 —— 代码完整保留，信息不丢失

本项目的聊天记录格式
====================
聊天记录不是 JSON，而是 .sts 管道分隔文本，位于 data/deepseek_chat/ 下：
  会话文件：data/deepseek_chat/sessions/*.sts
  每行 #M|id|role|content|createdAt|attachments|reasoning
字段由 Go 侧 escDs 转义：真实换行 -> 字面 \\n，管道符 | -> \\p，反斜杠 -> \\\\
因此本脚本对 .sts 做的是"转义态"下的代码块折叠，全程保持单行、不破坏字段结构。

四种用法
========
  python3 ha.py clean  --dir data/deepseek_chat/            # 一次性优化
  python3 ha.py watch  --dir data/deepseek_chat/            # 持续监听（谨慎，见下）
  python3 ha.py proxy  --port 9000                          # HTTP 代理，实时折叠 LLM 响应
  python3 ha.py export --dir data/deepseek_chat/ --out display/  # 生成展示副本，不动原文件

注意
====
Go 程序运行期间会持续向 .sts 追加写入（O_APPEND）。若 watch 与 Go 同时读写
同一文件，存在数据竞争风险。推荐做法：让 Go 程序退出后，再执行一次 clean。
st.py 默认也采用「退出后 clean」的方式，安全且足够。
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

try:
    from urllib.request import Request, urlopen
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
except ImportError:  # Python < 3.7 兜底
    from urllib.request import Request, urlopen
    from http.server import BaseHTTPRequestHandler, HTTPServer
    ThreadingHTTPServer = None

# ---------------- 配置 ----------------
DEFAULT_MIN_LINES = 15          # 代码块超过该行数才折叠
DEFAULT_INTERVAL = 2            # 目录监听轮询间隔（秒）
DEFAULT_UPSTREAM = "https://api.deepseek.com"
SUPPORTED_SUFFIX = {".sts", ".md", ".txt", ".json", ".jsonl", ".log"}

# ---------------- 通用：普通文本代码块折叠（真实换行） ----------------
CODE_BLOCK_RE = re.compile(r'```([\w+\-.#]*)[ \t]*\n(.*?)```', re.DOTALL)
DETAILS_RE = re.compile(r'<details>.*?</details>', re.DOTALL)

# ---------------- .sts 专用：转义态代码块折叠（字面 \\n） ----------------
# .sts 字段里：真实换行被 escDs 写成字面 "\n"（反斜杠 + n 两个字符）。
# 因此代码块围栏 ``` 之间的行分隔是字面 \n，而非真实换行。
STS_CODE_BLOCK_RE = re.compile(r'```([\w+\-.#]*)\\n(.*?)```', re.DOTALL)
STS_DETAILS_RE = re.compile(r'<details>.*?</details>', re.DOTALL)


def fold_code_blocks(text, min_lines=DEFAULT_MIN_LINES):
    """普通文本：折叠超过 min_lines 行的代码块（幂等）。"""
    if not isinstance(text, str) or not text:
        return text

    def repl(m):
        lang = m.group(1)
        code = m.group(2)
        lines = code.count("\n") + (1 if code.strip() else 0)
        if lines < min_lines:
            return m.group(0)
        lang_label = f" · {lang}" if lang else ""
        summary = f"📄 代码{lang_label} · {lines} 行（点击展开）"
        return (
            f"<details>\n<summary>{summary}</summary>\n\n"
            f"```{lang}\n{code}\n```\n\n"
            f"</details>"
        )

    protected = []

    def stash(m):
        protected.append(m.group(0))
        return f"\x00DETAILS_{len(protected) - 1}\x00"

    text2 = DETAILS_RE.sub(stash, text)
    text2 = CODE_BLOCK_RE.sub(repl, text2)
    for i, block in enumerate(protected):
        text2 = text2.replace(f"\x00DETAILS_{i}\x00", block)
    return text2


def fold_sts_code_blocks(text, min_lines=DEFAULT_MIN_LINES):
    """折叠 .sts 字段（转义态）里的超长代码块，返回新文本（幂等，保持单行）。"""
    if not isinstance(text, str) or not text:
        return text

    def repl(m):
        lang = m.group(1)
        code = m.group(2)
        # 行数 = 字面 \n 的个数 + 1
        lines = code.count("\\n") + (1 if code.strip() else 0)
        if lines < min_lines:
            return m.group(0)
        lang_label = f" · {lang}" if lang else ""
        summary = f"📄 代码{lang_label} · {lines} 行（点击展开）"
        # 折叠标记内部也用字面 \n，保持 .sts 单行结构
        return (
            f"<details>\\n<summary>{summary}</summary>\\n\\n"
            f"```{lang}\\n{code}\\n```\\n\\n"
            f"</details>"
        )

    protected = []

    def stash(m):
        protected.append(m.group(0))
        return f"\x00DETAILS_{len(protected) - 1}\x00"

    text2 = STS_DETAILS_RE.sub(stash, text)
    text2 = STS_CODE_BLOCK_RE.sub(repl, text2)
    for i, block in enumerate(protected):
        text2 = text2.replace(f"\x00DETAILS_{i}\x00", block)
    return text2


# ---------------- 文件处理 ----------------
def process_text(text, min_lines=DEFAULT_MIN_LINES):
    new_text = fold_code_blocks(text, min_lines)
    return new_text, (new_text != text)


def process_json_text(text, min_lines=DEFAULT_MIN_LINES):
    """处理 JSON（DeepSeek messages 格式），折叠思考链/正文里的代码块。"""
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return text, False

    changed = False
    TARGET_KEYS = {"reasoning_content", "content", "reasoning"}

    def walk(node):
        nonlocal changed
        if isinstance(node, dict):
            for k, v in list(node.items()):
                if k in TARGET_KEYS and isinstance(v, str):
                    nv = fold_code_blocks(v, min_lines)
                    if nv != v:
                        node[k] = nv
                        changed = True
                elif isinstance(v, (dict, list)):
                    walk(v)
        elif isinstance(node, list):
            for item in node:
                if isinstance(item, (dict, list)):
                    walk(item)

    walk(data)
    if changed:
        return json.dumps(data, ensure_ascii=False, indent=2), True
    return text, False


def process_sts_text(text, min_lines=DEFAULT_MIN_LINES):
    """处理 .sts 会话文件（管道分隔 + escDs 转义态）。

    只折叠 #M 行的 content(字段3) 与 reasoning(字段6) 里的代码块，
    不动 id/role/createdAt/attachments，不破坏 #S 头行与字段结构。
    """
    if not isinstance(text, str) or not text:
        return text, False

    out_lines = []
    changed = False
    for line in text.split("\n"):
        if not line.startswith("#M|"):
            out_lines.append(line)
            continue
        parts = line[3:].split("|")
        if len(parts) < 4:
            out_lines.append(line)
            continue

        # content = parts[2]
        nc = fold_sts_code_blocks(parts[2], min_lines)
        if nc != parts[2]:
            parts[2] = nc
            changed = True

        # reasoning = parts[5]（若存在）
        if len(parts) >= 6:
            nr = fold_sts_code_blocks(parts[5], min_lines)
            if nr != parts[5]:
                parts[5] = nr
                changed = True

        out_lines.append("#M|" + "|".join(parts))

    return "\n".join(out_lines), changed


def process_file(path, min_lines=DEFAULT_MIN_LINES, backup=True):
    """处理单个文件，成功返回 True。原子写入，可选备份。"""
    path = Path(path)
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False

    suffix = path.suffix.lower()
    if suffix == ".sts":
        new_text, changed = process_sts_text(raw, min_lines)
    elif suffix == ".json":
        new_text, changed = process_json_text(raw, min_lines)
    else:
        new_text, changed = process_text(raw, min_lines)

    if not changed:
        return False

    if backup:
        bak = path.with_suffix(path.suffix + ".bak")
        try:
            bak.write_text(raw, encoding="utf-8")
        except OSError:
            pass

    tmp = path.with_suffix(path.suffix + ".ha_tmp")
    tmp.write_text(new_text, encoding="utf-8")
    os.replace(tmp, path)  # 原子替换，避免写一半崩溃损坏数据
    return True


# ---------------- 目录模式 ----------------
def clean_dir(directory, min_lines=DEFAULT_MIN_LINES, backup=True):
    """一次性优化目录下所有聊天记录。"""
    directory = Path(directory)
    if not directory.is_dir():
        print(f"❌ 目录不存在：{directory}")
        return 0

    files = [
        p for p in directory.rglob("*")
        if p.is_file() and p.suffix.lower() in SUPPORTED_SUFFIX
    ]
    count = 0
    for p in files:
        try:
            if process_file(p, min_lines, backup):
                print(f"  ✅ {p}")
                count += 1
        except Exception as e:
            print(f"  ⚠️ {p}: {e}")
    print(f"完成：扫描 {len(files)} 个文件，优化 {count} 个")
    return count


def watch_dir(directory, min_lines=DEFAULT_MIN_LINES, interval=DEFAULT_INTERVAL, backup=True):
    """持续监听目录，实时优化新产生的聊天记录。

    注意：若 Go 程序正在运行并向 .sts 追加写入，watch 会与之竞争。
    默认建议 Go 退出后用 clean；watch 仅用于 Go 未运行时的手动实时优化。
    """
    directory = Path(directory)
    if not directory.is_dir():
        print(f"❌ 目录不存在：{directory}")
        return

    print(f"👀 监听目录：{directory}（每 {interval}s 检查一次）")
    print("   ⚠️ 若 Go 程序正在写入 .sts，请立即停止监听，改用退出后 clean")
    print("   按 Ctrl+C 退出")
    seen = {}
    try:
        while True:
            for p in directory.rglob("*"):
                if not (p.is_file() and p.suffix.lower() in SUPPORTED_SUFFIX):
                    continue
                try:
                    stat = p.stat()
                    key = (stat.st_mtime_ns, stat.st_size)
                except OSError:
                    continue
                if seen.get(str(p)) == key:
                    continue
                seen[str(p)] = key
                try:
                    if process_file(p, min_lines, backup):
                        print(f"  ✅ 已优化：{p}")
                except Exception as e:
                    print(f"  ⚠️ {p}: {e}")
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\n已停止监听")


def export_dir(directory, out_dir, min_lines=DEFAULT_MIN_LINES):
    """生成展示副本到 out_dir，原文件不动（最安全的方案）。"""
    directory = Path(directory)
    out_dir = Path(out_dir)
    if not directory.is_dir():
        print(f"❌ 源目录不存在：{directory}")
        return

    out_dir.mkdir(parents=True, exist_ok=True)
    count = 0
    for p in directory.rglob("*"):
        if not (p.is_file() and p.suffix.lower() in SUPPORTED_SUFFIX):
            continue
        try:
            raw = p.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue

        suffix = p.suffix.lower()
        if suffix == ".sts":
            new_text, _ = process_sts_text(raw, min_lines)
        elif suffix == ".json":
            new_text, _ = process_json_text(raw, min_lines)
        else:
            new_text, _ = process_text(raw, min_lines)

        rel = p.relative_to(directory)
        target = out_dir / (str(rel) + ".md")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(new_text, encoding="utf-8")
        count += 1
    print(f"完成：导出 {count} 个展示副本到 {out_dir}")


# ---------------- 代理模式 ----------------
class ProxyHandler(BaseHTTPRequestHandler):
    upstream = DEFAULT_UPSTREAM
    min_lines = DEFAULT_MIN_LINES

    def do_GET(self):
        body = b"ha.py proxy is running\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        url = self.upstream.rstrip("/") + self.path
        req = Request(url, data=body, method="POST")
        for k, v in self.headers.items():
            if k.lower() in ("host", "content-length", "connection"):
                continue
            req.add_header(k, v)

        try:
            with urlopen(req, timeout=180) as resp:
                status = resp.status
                resp_body = resp.read()
                resp_headers = {k: v for k, v in resp.getheaders()}
        except Exception as e:
            err = json.dumps({"error": str(e)}).encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(err)))
            self.end_headers()
            self.wfile.write(err)
            return

        ctype = resp_headers.get("Content-Type", "")
        if "text/event-stream" in ctype:
            new_body = resp_body
        elif "application/json" in ctype:
            new_body = self._fold_json(resp_body)
        else:
            new_body = resp_body

        self.send_response(status)
        for k, v in resp_headers.items():
            if k.lower() in ("content-length", "connection", "transfer-encoding"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(new_body)))
        self.end_headers()
        self.wfile.write(new_body)

    def _fold_json(self, body):
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:
            return body
        new_text, _ = process_json_text(text, self.min_lines)
        return new_text.encode("utf-8")

    def log_message(self, fmt, *args):
        pass  # 静默日志


def run_proxy(port, upstream, min_lines):
    ProxyHandler.upstream = upstream
    ProxyHandler.min_lines = min_lines
    server_cls = ThreadingHTTPServer or HTTPServer
    server = server_cls(("127.0.0.1", port), ProxyHandler)
    print(f"🛡️  代理已启动：http://127.0.0.1:{port}")
    print(f"    上游 API：{upstream}")
    print(f"    Go 程序需将 API base URL 指向本代理地址")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止代理")


# ---------------- 主入口 ----------------
def main():
    parser = argparse.ArgumentParser(description="ha.py —— 聊天记录优化外挂")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_clean = sub.add_parser("clean", help="一次性优化目录下所有聊天记录")
    p_clean.add_argument("--dir", required=True, help="聊天记录目录")
    p_clean.add_argument("--min-lines", type=int, default=DEFAULT_MIN_LINES)
    p_clean.add_argument("--no-backup", action="store_true", help="不备份原文件")

    p_watch = sub.add_parser("watch", help="持续监听目录并实时优化")
    p_watch.add_argument("--dir", required=True, help="聊天记录目录")
    p_watch.add_argument("--min-lines", type=int, default=DEFAULT_MIN_LINES)
    p_watch.add_argument("--interval", type=float, default=DEFAULT_INTERVAL)
    p_watch.add_argument("--no-backup", action="store_true", help="不备份原文件")

    p_export = sub.add_parser("export", help="生成展示副本，不动原文件")
    p_export.add_argument("--dir", required=True, help="聊天记录目录")
    p_export.add_argument("--out", required=True, help="展示副本输出目录")
    p_export.add_argument("--min-lines", type=int, default=DEFAULT_MIN_LINES)

    p_proxy = sub.add_parser("proxy", help="HTTP 代理，实时折叠 LLM 响应")
    p_proxy.add_argument("--port", type=int, default=9000)
    p_proxy.add_argument("--upstream", default=DEFAULT_UPSTREAM)
    p_proxy.add_argument("--min-lines", type=int, default=DEFAULT_MIN_LINES)

    args = parser.parse_args()

    if args.cmd == "clean":
        clean_dir(args.dir, args.min_lines, backup=not args.no_backup)
    elif args.cmd == "watch":
        watch_dir(args.dir, args.min_lines, args.interval, backup=not args.no_backup)
    elif args.cmd == "export":
        export_dir(args.dir, args.out, args.min_lines)
    elif args.cmd == "proxy":
        run_proxy(args.port, args.upstream, args.min_lines)


if __name__ == "__main__":
    main()
