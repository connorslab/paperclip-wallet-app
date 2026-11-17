"""Linux development shell for the shared wallet daemon; no wallet opens on import."""
import argparse
from pathlib import Path
import queue
import re
import sys
import threading
import webbrowser

# Source checkout and packaged preview both load only adjacent trusted helpers.
resources = Path(__file__).resolve().parent
sys.path.insert(0, str(resources if (resources / 'managed_daemon.py').is_file() else resources.parent))
from managed_daemon import ManagedDaemon, StartupError, default_data_root


def valid_handoff(value):
    if not isinstance(value, str):
        return False
    match = re.fullmatch(r'http://127\.0\.0\.1:([0-9]{1,5})/#desktop-handoff=[A-Za-z0-9_-]{44}', value)
    return bool(match and 1 <= int(match[1]) <= 65535)


class Session:
    """One worker owns the daemon; UI never waits on startup, network or shutdown."""
    def __init__(self, binary, root):
        self.binary, self.root = binary, root
        self.events = queue.Queue()
        self.commands = queue.Queue(maxsize=1)
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def open(self):
        if not self.stopping.is_set():
            try:
                self.commands.put_nowait('open')
            except queue.Full:
                pass

    def close(self):
        self.stopping.set()

    def run(self):
        runner = None
        try:
            if self.stopping.is_set():
                return
            runner = ManagedDaemon(self.binary, self.root)
            runner.start()
            if not self.stopping.is_set():
                self.events.put(('ready', runner.recovery_required))
            while not self.stopping.is_set():
                if runner.process.poll() is not None:
                    raise StartupError('Your wallet stopped unexpectedly. Open it again to recover.')
                try:
                    command = self.commands.get(timeout=0.1)
                except queue.Empty:
                    continue
                if command == 'open' and not self.stopping.is_set():
                    try:
                        self.events.put(('open', runner.browser_url()))
                    except StartupError as error:
                        self.events.put(('open_error', str(error)))
        except Exception as error:
            self.events.put(('error', str(error) if isinstance(error, StartupError) else 'The local wallet could not start.'))
        finally:
            if runner is not None:
                try:
                    runner.close()
                except Exception:
                    self.events.put(('error', 'The wallet did not close cleanly. Check Activity on the next launch.'))
            self.events.put(('closed', None))


class Window:
    def __init__(self, root, binary, data_root, opener=webbrowser.open):
        import tkinter as tk
        from tkinter import ttk
        self.root, self.binary, self.data_root, self.opener = root, binary, data_root, opener
        self.session = None
        self.state = 'starting'
        self.quitting = False
        self.closed = False
        self.recovery = False
        self.failure = None
        root.title('Paperclip Preview')
        root.geometry('480x460')
        root.minsize(420, 420)
        root.configure(background='#101c2c')
        root.protocol('WM_DELETE_WINDOW', self.close)
        root.bind('<Control-q>', lambda _: self.close())
        root.bind('<Return>', lambda _: self.activate())
        frame = tk.Frame(root, background='#101c2c')
        frame.place(relx=0.5, rely=0.5, anchor='center', relwidth=0.86)
        def label(text, size, color, weight='normal'):
            widget = tk.Label(frame, text=text, font=('TkDefaultFont', size, weight),
                              background='#101c2c', foreground=color, justify='center', wraplength=360)
            widget.pack(fill='x', pady=7)
            return widget
        label('PAPERCLIP', 13, '#ff8956', 'bold')
        label('Your wallet, on Linux', 22, '#f3f6fa', 'bold')
        self.status = label('Starting your wallet…', 12, '#b9c9db')
        style = ttk.Style(root)
        style.theme_use('clam')
        style.configure('Wallet.Horizontal.TProgressbar', background='#ff8956', troughcolor='#1e3047')
        self.progress = ttk.Progressbar(frame, mode='indeterminate', style='Wallet.Horizontal.TProgressbar')
        self.progress.pack(fill='x', padx=65, pady=12)
        self.action = tk.Button(frame, text='Open Wallet', command=self.activate, font=('TkDefaultFont', 12, 'bold'),
                                background='#ff8956', activebackground='#ffa578', foreground='#101c2c',
                                activeforeground='#101c2c', relief='flat', borderwidth=0, padx=28, pady=12,
                                highlightthickness=2, highlightcolor='#ffffff', highlightbackground='#101c2c',
                                disabledforeground='#64758b', takefocus=True)
        self.action.pack(pady=12)
        self.note = label('Keep this window open while using your wallet. Quitting stops the local wallet.', 10, '#a8bbd0')
        label('Development preview', 9, '#8b9fb8')
        root.bind('<Configure>', self.resize)
        self.start()
        root.after(50, self.poll)

    def resize(self, event):
        if event.widget is self.root:
            for widget in (self.status, self.note):
                widget.configure(wraplength=max(250, int(event.width * .86)))

    def start(self):
        if self.session is not None and self.session.thread.is_alive():
            return
        self.state, self.failure, self.recovery = 'starting', None, False
        self.status.configure(text='Starting your wallet…')
        self.action.configure(text='Open Wallet', state='disabled')
        self.progress.pack(before=self.action, fill='x', padx=65, pady=12)
        self.progress.start(12)
        self.session = Session(self.binary, self.data_root)
        self.session.start()

    def activate(self):
        if self.quitting or str(self.action['state']) == 'disabled':
            return
        if self.state == 'failed':
            self.start()
        elif self.state == 'ready':
            self.action.configure(state='disabled')
            self.status.configure(text='Opening your wallet…')
            self.session.open()

    def poll(self):
        while True:
            try:
                event, value = self.session.events.get_nowait()
            except queue.Empty:
                break
            if event == 'closed':
                self.state = 'closed'
            elif not self.quitting:
                if event == 'ready':
                    self.state, self.recovery = 'ready', value
                    self.progress.stop()
                    self.progress.pack_forget()
                    self.status.configure(text=('Your previous session did not close cleanly. Check Activity before making another payment.'
                                                if value else 'Ready when you are.'))
                    self.action.configure(text='Review Wallet' if value else 'Open Wallet', state='normal')
                    self.action.focus_set()
                elif event == 'open':
                    if not valid_handoff(value):
                        self.failure = 'The desktop connection was interrupted. Open Paperclip again.'
                        self.session.close()
                    else:
                        session = self.session
                        def open_browser(url=value, owner=session):
                            try:
                                opened = not owner.stopping.is_set() and self.opener(url)
                            except Exception:
                                opened = False
                            owner.events.put(('opened', bool(opened)))
                        threading.Thread(target=open_browser, daemon=True).start()
                elif event == 'opened':
                    self.status.configure(text='Your wallet is open in your browser.' if value else 'The browser could not open. Try Open Wallet again.')
                    self.action.configure(state='normal')
                elif event == 'open_error':
                    self.status.configure(text=value)
                    self.action.configure(state='normal')
                elif event == 'error':
                    self.failure = value
                    self.status.configure(text=value)
                    self.action.configure(state='disabled')
        if self.state == 'closed' and not self.session.thread.is_alive():
            if self.quitting:
                self.closed = True
                self.root.destroy()
                return
            self.state = 'failed'
            self.progress.stop()
            self.progress.pack_forget()
            self.status.configure(text=self.failure or 'Your wallet stopped. You can open it again.')
            self.action.configure(text='Try Again', state='normal')
        self.root.after(50, self.poll)

    def close(self):
        if self.quitting:
            return
        self.quitting = True
        self.status.configure(text='Closing your wallet safely…')
        self.action.configure(state='disabled')
        self.progress.pack(before=self.action, fill='x', padx=65, pady=12)
        self.progress.start(12)
        self.session.close()
        if not self.session.thread.is_alive():
            self.closed = True
            self.root.destroy()


def main():
    if not sys.platform.startswith('linux'):
        raise SystemExit('This launcher is for Linux. Use the native macOS launcher on a Mac.')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--qa-root', type=Path)
    args = parser.parse_args()
    if args.qa_root is not None and not args.qa_root.is_absolute():
        parser.error('QA storage must be an absolute, isolated path.')
    import tkinter as tk
    root = tk.Tk()
    Window(root, args.binary.resolve(strict=True), args.qa_root or default_data_root())
    root.mainloop()


if __name__ == '__main__':
    main()
