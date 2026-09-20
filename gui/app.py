"""
Cheap Workflow Tool - a small desktop front end for night-run.ps1.

Pure stdlib (tkinter). No pip install, no server, no build step.

What it is for: running a queue of small, test-gated coding tasks against
whichever agent is cheapest right now, on a project you already have. It never
requires an empty directory - point it at existing work and it only adds the
two files it needs.

Every command opens in its OWN terminal window, titled, so a Claude run and a
Gemini run are two visible things you can watch and kill independently.
"""

import json
import os
import re
import subprocess
import sys
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

APP_NAME = "Cheap Workflow Tool"
ROOT_DIR = Path(__file__).resolve().parent.parent
BIN_DIR = ROOT_DIR / "bin"
NIGHT_RUN = BIN_DIR / "night-run.ps1"
NEW_PROJECT = BIN_DIR / "new-project.ps1"
STACKS_DIR = ROOT_DIR / "workflow" / "templates" / "stacks"
CONFIG_PATH = ROOT_DIR / "gui" / "config.json"

# Windows only: give each run its own console window.
CREATE_NEW_CONSOLE = 0x00000010

STACKS = [
    ("Laravel + React", "laravel-react.md"),
    ("Node + Prisma + React", "node-prisma-react.md"),
    ("Flutter", "flutter.md"),
    ("Generic / other", "generic.md"),
]

CLAUDE_MODELS = ["sonnet", "opus", "haiku"]
GEMINI_MODELS = [
    "google/gemini-3.5-flash-lite",
    "google/gemini-3.5-flash",
    "google/gemini-flash-lite-latest",
]


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------
def load_config():
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            pass
    return {"recent": [], "settings": {}}


def save_config(cfg):
    try:
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    except OSError:
        pass


# --------------------------------------------------------------------------
# TASKS.md parsing
# --------------------------------------------------------------------------
TASK_RE = re.compile(r"^\s*-\s*\[([ x!])\]\s+(.+?)\s*$")


def parse_tasks(tasks_path):
    """Return [(line_no, mark, text)], skipping anything inside <!-- -->.

    This mirrors Get-QueuedTasks in night-run.ps1 exactly, and for the same
    reason: the TASKS.md templates teach task sizing by SHOWING examples inside
    HTML comments. A naive scan treats those examples as real work - which is
    how a run once started with "Build the products module", the very task the
    template exists to warn against. What the GUI lists and what the runner
    picks up must be the same set, or the preview is a lie.
    """
    try:
        lines = tasks_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []

    out = []
    in_comment = False
    for i, raw in enumerate(lines, start=1):
        visible, rest = "", raw
        while True:
            if in_comment:
                close = rest.find("-->")
                if close < 0:
                    break
                rest = rest[close + 3:]
                in_comment = False
            else:
                open_at = rest.find("<!--")
                if open_at < 0:
                    visible += rest
                    break
                visible += rest[:open_at]
                rest = rest[open_at + 4:]
                in_comment = True
        m = TASK_RE.match(visible)
        if m:
            out.append((i, m.group(1), m.group(2)))
    return out


# --------------------------------------------------------------------------
# shell helpers
# --------------------------------------------------------------------------
def run_in_new_terminal(title, ps_command, cwd=None):
    """Open a new PowerShell window running ps_command, and leave it open."""
    prelude = f"$host.UI.RawUI.WindowTitle = '{title}'; "
    full = prelude + ps_command
    try:
        subprocess.Popen(
            ["powershell", "-NoExit", "-ExecutionPolicy", "Bypass", "-Command", full],
            cwd=str(cwd) if cwd else None,
            creationflags=CREATE_NEW_CONSOLE,
        )
        return True, ""
    except OSError as e:
        return False, str(e)


def run_capture(args, cwd=None, timeout=20):
    """Run something quietly and return (rc, stdout+stderr)."""
    try:
        p = subprocess.run(
            args, cwd=str(cwd) if cwd else None, capture_output=True,
            text=True, timeout=timeout,
        )
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except (OSError, subprocess.SubprocessError) as e:
        return -1, str(e)


def ps_quote(s):
    """Single-quote a string for PowerShell (doubling any internal quote)."""
    return "'" + str(s).replace("'", "''") + "'"


# --------------------------------------------------------------------------
# app
# --------------------------------------------------------------------------
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_NAME)
        self.geometry("980x660")
        self.minsize(820, 560)

        self.cfg = load_config()
        self.project = tk.StringVar(value=self._initial_project())

        self._build_header()
        self._build_tabs()
        self._build_status()

        self.refresh()

    def _initial_project(self):
        recent = self.cfg.get("recent", [])
        return recent[0] if recent else ""

    # ---------------------------------------------------------------- header
    def _build_header(self):
        bar = ttk.Frame(self, padding=(10, 8))
        bar.pack(fill="x")

        ttk.Label(bar, text="Project").pack(side="left")
        self.project_box = ttk.Combobox(
            bar, textvariable=self.project, values=self.cfg.get("recent", []), width=62
        )
        self.project_box.pack(side="left", padx=6)
        self.project_box.bind("<<ComboboxSelected>>", lambda e: self.refresh())
        self.project_box.bind("<Return>", lambda e: self.refresh())

        ttk.Button(bar, text="Browse...", command=self.browse).pack(side="left", padx=2)
        ttk.Button(bar, text="Refresh", command=self.refresh).pack(side="left", padx=2)
        ttk.Button(bar, text="Folder", command=self.open_folder).pack(side="left", padx=2)

        info = ttk.Frame(self, padding=(12, 0))
        info.pack(fill="x")
        self.info_var = tk.StringVar(value="No project selected.")
        self.info_lbl = ttk.Label(info, textvariable=self.info_var)
        self.info_lbl.pack(side="left")

    # ------------------------------------------------------------------ tabs
    def _build_tabs(self):
        nb = ttk.Notebook(self, padding=6)
        nb.pack(fill="both", expand=True)
        self._build_tasks_tab(nb)
        self._build_run_tab(nb)
        self._build_settings_tab(nb)

    def _build_tasks_tab(self, nb):
        f = ttk.Frame(nb, padding=8)
        nb.add(f, text="Tasks")

        cols = ("line", "state", "task")
        self.tree = ttk.Treeview(f, columns=cols, show="headings", height=18)
        self.tree.heading("line", text="Line")
        self.tree.heading("state", text="State")
        self.tree.heading("task", text="Task")
        self.tree.column("line", width=55, anchor="e", stretch=False)
        self.tree.column("state", width=90, anchor="center", stretch=False)
        self.tree.column("task", width=760, anchor="w")

        # colour by state so a morning review is a glance, not a read
        self.tree.tag_configure("done", foreground="#127a2b")
        self.tree.tag_configure("blocked", foreground="#b3261e")
        self.tree.tag_configure("queued", foreground="#1a1a1a")

        sb = ttk.Scrollbar(f, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="top", fill="both", expand=True)
        sb.place(relx=1.0, rely=0, relheight=1.0, anchor="ne")

        btns = ttk.Frame(f, padding=(0, 8))
        btns.pack(fill="x")
        ttk.Button(btns, text="Open TASKS.md", command=self.open_tasks).pack(side="left")
        ttk.Button(btns, text="Open AGENTS.md", command=self.open_agents).pack(side="left", padx=4)
        ttk.Button(btns, text="Re-queue selected  [!] -> [ ]",
                   command=self.requeue_selected).pack(side="left", padx=4)
        ttk.Button(btns, text="Write tasks with Claude",
                   command=self.plan_with_claude).pack(side="left", padx=4)

    def _build_run_tab(self, nb):
        f = ttk.Frame(nb, padding=12)
        nb.add(f, text="Run")

        opts = ttk.LabelFrame(f, text="Options", padding=10)
        opts.pack(fill="x")

        self.timeout_var = tk.StringVar(value=self.cfg["settings"].get("timeout", "20"))
        self.retries_var = tk.StringVar(value=self.cfg["settings"].get("retries", "1"))
        self.testcmd_var = tk.StringVar(value="")

        ttk.Label(opts, text="Task timeout (min)").grid(row=0, column=0, sticky="w", pady=3)
        ttk.Entry(opts, textvariable=self.timeout_var, width=8).grid(row=0, column=1, sticky="w", padx=6)
        ttk.Label(opts, text="Retries").grid(row=0, column=2, sticky="w", padx=(18, 0))
        ttk.Entry(opts, textvariable=self.retries_var, width=8).grid(row=0, column=3, sticky="w", padx=6)

        ttk.Label(opts, text="Test command").grid(row=1, column=0, sticky="w", pady=3)
        ttk.Entry(opts, textvariable=self.testcmd_var, width=52).grid(
            row=1, column=1, columnspan=3, sticky="w", padx=6)
        ttk.Label(opts, text="blank = auto-detect", foreground="#666").grid(
            row=1, column=4, sticky="w")

        runs = ttk.LabelFrame(f, text="Run  (each opens its own terminal window)", padding=10)
        runs.pack(fill="x", pady=12)

        def row(r, text, cmd, note, style=None):
            b = ttk.Button(runs, text=text, width=30, command=cmd)
            b.grid(row=r, column=0, sticky="w", pady=4)
            ttk.Label(runs, text=note, foreground="#555").grid(row=r, column=1, sticky="w", padx=12)

        row(0, "Dry run  (no model calls)", self.do_dryrun,
            "Lists the queue and exits. Always do this first.")
        row(1, "Run with CLAUDE", lambda: self.do_run("claude"),
            "Your subscription. Strongest. Uses your usage window.")
        row(2, "Run with GEMINI  (free)", lambda: self.do_run("opencode"),
            "Free tier, about 1000 requests/day. Costs nothing.")
        row(3, "Run AUTO", lambda: self.do_run("auto"),
            "Claude first, then Gemini when the window closes.")

        extra = ttk.Frame(f)
        extra.pack(fill="x")
        ttk.Button(extra, text="Open terminal here", command=self.open_terminal).pack(side="left")
        ttk.Button(extra, text="Commit everything (git add -A + commit)",
                   command=self.commit_all).pack(side="left", padx=6)
        ttk.Button(extra, text="Clear stale lock", command=self.clear_lock).pack(side="left")

    def _build_settings_tab(self, nb):
        f = ttk.Frame(nb, padding=12)
        nb.add(f, text="Settings")

        stack = ttk.LabelFrame(f, text="Stack preset for THIS project", padding=10)
        stack.pack(fill="x")
        ttk.Label(
            stack,
            text=("Writes AGENTS.md - the rules file every model call reads.\n"
                  "A small model follows concrete right/wrong examples; it ignores abstract advice."),
            foreground="#555", justify="left",
        ).pack(anchor="w", pady=(0, 8))

        self.stack_var = tk.StringVar(value=STACKS[0][1])
        for label, fname in STACKS:
            ttk.Radiobutton(stack, text=label, value=fname,
                            variable=self.stack_var).pack(anchor="w")
        ttk.Button(stack, text="Apply stack  ->  write AGENTS.md",
                   command=self.apply_stack).pack(anchor="w", pady=8)

        models = ttk.LabelFrame(f, text="Models", padding=10)
        models.pack(fill="x", pady=12)
        self.claude_model = tk.StringVar(value=self.cfg["settings"].get("claude_model", "sonnet"))
        self.gemini_model = tk.StringVar(
            value=self.cfg["settings"].get("gemini_model", GEMINI_MODELS[0]))
        ttk.Label(models, text="Claude model").grid(row=0, column=0, sticky="w", pady=3)
        ttk.Combobox(models, textvariable=self.claude_model, values=CLAUDE_MODELS,
                     width=34, state="readonly").grid(row=0, column=1, sticky="w", padx=8)
        ttk.Label(models, text="Gemini model").grid(row=1, column=0, sticky="w", pady=3)
        ttk.Combobox(models, textvariable=self.gemini_model, values=GEMINI_MODELS,
                     width=34, state="readonly").grid(row=1, column=1, sticky="w", padx=8)

        setup = ttk.LabelFrame(f, text="Project setup", padding=10)
        setup.pack(fill="x")
        ttk.Label(
            setup,
            text=("Adds AGENTS.md and TASKS.md, runs git init plus a first commit if needed,\n"
                  "then a preflight. It never overwrites a file that already exists, so it is\n"
                  "safe on a project you have been working on for months."),
            foreground="#555", justify="left",
        ).pack(anchor="w", pady=(0, 8))
        ttk.Button(setup, text="Set up this project",
                   command=self.setup_project).pack(anchor="w")
        ttk.Button(setup, text="Check environment (keys, CLIs)",
                   command=self.check_env).pack(anchor="w", pady=6)

    def _build_status(self):
        bar = ttk.Frame(self, padding=(12, 6))
        bar.pack(fill="x", side="bottom")
        self.status_var = tk.StringVar(value="Ready.")
        ttk.Label(bar, textvariable=self.status_var, foreground="#333").pack(side="left")

    # ------------------------------------------------------------- utilities
    def say(self, msg):
        self.status_var.set(msg)

    def proj(self):
        p = (self.project.get() or "").strip().strip('"')
        return Path(p) if p else None

    def need_project(self):
        p = self.proj()
        if not p or not p.is_dir():
            messagebox.showwarning(APP_NAME, "Pick a project folder first.")
            return None
        return p

    def remember(self, path):
        recent = [r for r in self.cfg.get("recent", []) if r != str(path)]
        recent.insert(0, str(path))
        self.cfg["recent"] = recent[:12]
        self.cfg.setdefault("settings", {})
        save_config(self.cfg)
        self.project_box["values"] = self.cfg["recent"]

    def persist_settings(self):
        self.cfg.setdefault("settings", {}).update({
            "timeout": self.timeout_var.get(),
            "retries": self.retries_var.get(),
            "claude_model": self.claude_model.get(),
            "gemini_model": self.gemini_model.get(),
        })
        save_config(self.cfg)

    # -------------------------------------------------------------- actions
    def browse(self):
        d = filedialog.askdirectory(title="Choose a project folder")
        if d:
            self.project.set(os.path.normpath(d))
            self.refresh()

    def refresh(self):
        for i in self.tree.get_children():
            self.tree.delete(i)

        p = self.proj()
        if not p or not p.is_dir():
            self.info_var.set("No project selected - click Browse.")
            return

        self.remember(p)
        tasks_file = p / "TASKS.md"

        if not tasks_file.exists():
            self.info_var.set(
                "No TASKS.md here yet - go to Settings and click 'Set up this project'.")
            return

        tasks = parse_tasks(tasks_file)
        counts = {" ": 0, "x": 0, "!": 0}
        label = {" ": ("queued", "queued"), "x": ("done", "done"), "!": ("blocked", "BLOCKED")}
        for line_no, mark, text in tasks:
            counts[mark] = counts.get(mark, 0) + 1
            tag, shown = label.get(mark, ("queued", mark))
            self.tree.insert("", "end", values=(line_no, shown, text), tags=(tag,))

        rc, out = run_capture(["git", "-C", str(p), "status", "--porcelain"])
        if rc != 0:
            git_state = "not a git repo (setup will fix)"
        else:
            n = len([ln for ln in out.splitlines() if ln.strip()])
            git_state = "clean" if n == 0 else f"{n} uncommitted file(s) - RUN WILL REFUSE"

        self.info_var.set(
            f"git: {git_state}   |   {counts[' ']} queued, {counts['x']} done, {counts['!']} blocked"
        )
        self.info_lbl.configure(foreground="#b3261e" if "REFUSE" in git_state else "#333")
        self.say(f"Loaded {len(tasks)} task(s) from TASKS.md")

    def open_folder(self):
        p = self.need_project()
        if p:
            subprocess.Popen(["explorer", str(p)])

    def _open_file(self, name):
        p = self.need_project()
        if not p:
            return
        f = p / name
        if not f.exists():
            messagebox.showinfo(APP_NAME, f"{name} does not exist yet.\n\n"
                                          "Settings -> 'Set up this project' creates it.")
            return
        os.startfile(str(f))

    def open_tasks(self):
        self._open_file("TASKS.md")

    def open_agents(self):
        self._open_file("AGENTS.md")

    def requeue_selected(self):
        """Turn selected [!] rows back into [ ] so the next run retries them."""
        p = self.need_project()
        if not p:
            return
        sel = self.tree.selection()
        if not sel:
            messagebox.showinfo(APP_NAME, "Select one or more blocked tasks first.")
            return

        line_nos = []
        for item in sel:
            line_no, shown, _ = self.tree.item(item, "values")
            if shown == "BLOCKED":
                line_nos.append(int(line_no))
        if not line_nos:
            messagebox.showinfo(APP_NAME, "Only BLOCKED tasks can be re-queued.")
            return

        f = p / "TASKS.md"
        lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
        changed = 0
        for n in line_nos:
            idx = n - 1
            if 0 <= idx < len(lines):
                new = re.sub(r"^(\s*-\s*)\[!\]", r"\1[ ]", lines[idx])
                # the runner appends a marker when it blocks; drop it too
                new = re.sub(r"\s*<!--\s*BLOCKED[^>]*-->\s*$", "", new)
                if new != lines[idx]:
                    lines[idx] = new
                    changed += 1
        # UTF-8 with no BOM, newline="" so we write exactly what we built
        with open(f, "w", encoding="utf-8", newline="") as fh:
            fh.write("\n".join(lines) + "\n")
        self.say(f"Re-queued {changed} task(s).")
        self.refresh()

    def plan_with_claude(self):
        p = self.need_project()
        if not p:
            return
        run_in_new_terminal(
            "PLAN - write TASKS.md with Claude",
            "Write-Host 'Ask Claude for a queue, for example:' -ForegroundColor Cyan; "
            "Write-Host '  read docs/ and write TASKS.md for the next feature, plus the tests' "
            "-ForegroundColor Gray; Write-Host ''; claude",
            cwd=p,
        )
        self.say("Opened a Claude session for planning.")

    # ------------------------------------------------------------------ runs
    def _night_run_cmd(self, executor=None, dry=False):
        p = self.proj()
        parts = ["&", ps_quote(NIGHT_RUN), "-Root", ps_quote(p)]
        if dry:
            parts.append("-DryRun")
        else:
            if executor:
                parts += ["-Executor", executor]
            if executor in ("claude", "auto"):
                parts += ["-ClaudeModel", self.claude_model.get()]
            if executor in ("opencode", "auto"):
                parts += ["-OpenCodeModel", self.gemini_model.get()]
            t = (self.timeout_var.get() or "").strip()
            if t.isdigit():
                parts += ["-TaskTimeoutMin", t]
            r = (self.retries_var.get() or "").strip()
            if r.isdigit():
                parts += ["-MaxRetries", r]
            tc = (self.testcmd_var.get() or "").strip()
            if tc:
                parts += ["-TestCmd", ps_quote(tc)]
        return " ".join(parts)

    def do_dryrun(self):
        p = self.need_project()
        if not p:
            return
        run_in_new_terminal("DRY RUN", self._night_run_cmd(dry=True), cwd=p)
        self.say("Dry run opened in a new terminal.")

    def do_run(self, executor):
        p = self.need_project()
        if not p:
            return

        rc, out = run_capture(["git", "-C", str(p), "status", "--porcelain"])
        dirty = rc == 0 and any(ln.strip() for ln in out.splitlines())
        if dirty:
            if not messagebox.askyesno(
                APP_NAME,
                "This project has uncommitted changes.\n\n"
                "The runner will refuse to start: a rollback would destroy that work.\n\n"
                "Open a terminal so you can commit or stash first?",
            ):
                return
            self.open_terminal()
            return

        self.persist_settings()
        titles = {"claude": "CLAUDE run", "opencode": "GEMINI run (free)", "auto": "AUTO run"}
        run_in_new_terminal(titles.get(executor, "run"),
                            self._night_run_cmd(executor=executor), cwd=p)
        self.say(f"Started {titles.get(executor, executor)} in its own terminal.")

    def open_terminal(self):
        p = self.need_project()
        if p:
            run_in_new_terminal(f"shell - {p.name}", "Get-Location", cwd=p)

    def commit_all(self):
        p = self.need_project()
        if not p:
            return
        run_in_new_terminal(
            f"commit - {p.name}",
            "git status; Write-Host ''; "
            "$m = Read-Host 'Commit message (blank = cancel)'; "
            "if ($m) { git add -A; git commit -m $m } else { 'cancelled' }",
            cwd=p,
        )

    def clear_lock(self):
        p = self.need_project()
        if not p:
            return
        lock = p / ".agent" / "night-run.lock"
        if not lock.exists():
            messagebox.showinfo(APP_NAME, "No lock file - nothing to clear.")
            return
        # The runner reclaims locks from dead processes by itself, so a lock
        # still here is either live or from an older version. Make the user look.
        if messagebox.askyesno(
            APP_NAME,
            f"{lock}\n\n{lock.read_text(encoding='utf-8', errors='replace')}\n\n"
            "Delete it? Do this only if no run is actually in progress.",
        ):
            try:
                lock.unlink()
                self.say("Lock cleared.")
            except OSError as e:
                messagebox.showerror(APP_NAME, str(e))

    # -------------------------------------------------------------- settings
    def apply_stack(self):
        p = self.need_project()
        if not p:
            return
        src = STACKS_DIR / self.stack_var.get()
        if not src.exists():
            messagebox.showerror(APP_NAME, f"Preset missing: {src}")
            return
        dest = p / "AGENTS.md"
        if dest.exists():
            if not messagebox.askyesno(
                APP_NAME,
                "AGENTS.md already exists in this project.\n\n"
                "Overwrite it with the preset? Any rules you added there are lost.",
            ):
                return
        dest.write_text(src.read_text(encoding="utf-8"), encoding="utf-8", newline="")
        self.say(f"Wrote AGENTS.md from {self.stack_var.get()}")
        messagebox.showinfo(
            APP_NAME,
            "AGENTS.md written.\n\nOpen it and replace the example versions and commands "
            "with this project's real ones - the model has no other source for them.",
        )

    def setup_project(self):
        p = self.proj()
        if not p:
            messagebox.showwarning(APP_NAME, "Pick or type a project folder first.")
            return
        cmd = f"& {ps_quote(NEW_PROJECT)} -Root {ps_quote(p)}"
        run_in_new_terminal("SETUP", cmd)
        self.say("Setup opened in a new terminal. Click Refresh when it finishes.")

    def check_env(self):
        run_in_new_terminal(
            "ENVIRONMENT CHECK",
            "Write-Host '--- CLIs ---' -ForegroundColor Cyan; "
            "foreach ($n in 'claude','opencode','git','node') { "
            "  $c = Get-Command $n -All -EA SilentlyContinue | Where-Object { $_.Source } | "
            "       Select-Object -First 1; "
            "  if ($c) { Write-Host ('  {0,-10} {1}' -f $n, $c.Source) } "
            "  else { Write-Host ('  {0,-10} NOT FOUND' -f $n) -ForegroundColor Red } }; "
            "Write-Host ''; Write-Host '--- keys ---' -ForegroundColor Cyan; "
            "foreach ($k in 'GEMINI_API_KEY','GOOGLE_API_KEY','OPENROUTER_API_KEY') { "
            "  $v = [Environment]::GetEnvironmentVariable($k,'User'); "
            "  if ($v) { Write-Host ('  {0,-20} set ({1} chars)' -f $k, $v.Length) } "
            "  else { Write-Host ('  {0,-20} not set' -f $k) -ForegroundColor DarkGray } }; "
            "Write-Host ''; Write-Host 'Free Gemini key (no card): https://aistudio.google.com/apikey' "
            "-ForegroundColor Yellow",
        )


def main():
    if os.name != "nt":
        print("This tool drives PowerShell and is Windows-only.", file=sys.stderr)
        return 1
    if not NIGHT_RUN.exists():
        print(f"Cannot find {NIGHT_RUN}", file=sys.stderr)
        return 1
    App().mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
