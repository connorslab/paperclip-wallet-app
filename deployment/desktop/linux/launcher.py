"""Linux development shell for the shared wallet daemon; no wallet opens on import."""
import argparse
import os
from pathlib import Path
import queue
import re
import sys
import subprocess
import threading
import webbrowser

sys.dont_write_bytecode = True

# Source checkout and packaged preview both load only adjacent trusted helpers.
resources = Path(__file__).resolve().parent
sys.path.insert(0, str(resources if (resources / 'managed_daemon.py').is_file() else resources.parent))
from managed_daemon import ManagedDaemon, StartupError, default_data_root
from managed_tor import packaged_binary as packaged_tor_binary
from node_setup_client import choose_runtime


def open_default_browser(url):
    if not getattr(sys, 'frozen', False):
        return webbrowser.open(url)
    # The frozen loader's library search path belongs to our bundled runtime,
    # not the user's desktop browser or its xdg-open helper.
    environment = os.environ.copy()
    original = environment.pop('LD_LIBRARY_PATH_ORIG', None)
    if original is None:
        environment.pop('LD_LIBRARY_PATH', None)
    else:
        environment['LD_LIBRARY_PATH'] = original
    return subprocess.run(['xdg-open', url], env=environment, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, timeout=10).returncode == 0


def valid_handoff(value):
    if not isinstance(value, str):
        return False
    match = re.fullmatch(r'http://127\.0\.0\.1:([0-9]{1,5})/#desktop-handoff=[A-Za-z0-9_-]{44}', value)
    return bool(match and 1 <= int(match[1]) <= 65535)


class Session:
    """One worker owns the daemon; UI never waits on startup, network or shutdown."""
    def __init__(self, binary, root, jam_runtime=None, tor_runtime=None, guided_setup=False):
        self.binary, self.root = binary, root
        self.jam_runtime = jam_runtime
        self.tor_runtime = tor_runtime
        self.guided_setup = guided_setup
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

    def setup(self, request):
        if not self.stopping.is_set():
            try: self.commands.put_nowait(request)
            except queue.Full: pass

    def run(self):
        runner = None
        try:
            if self.stopping.is_set():
                return
            tor = packaged_tor_binary(self.tor_runtime) if self.tor_runtime else None
            runtime = self.jam_runtime
            if self.guided_setup:
                def receive():
                    try: return self.commands.get(timeout=0.1)
                    except queue.Empty: return None
                runtime = choose_runtime(runtime,self.root,tor,self.stopping,receive,
                    lambda event,value:self.events.put((event,value)))
            if self.stopping.is_set(): return
            runner = ManagedDaemon(self.binary, self.root, jam_runtime=runtime, tor_binary=tor)
            runner.start()
            if not self.stopping.is_set():
                self.events.put(('ready', runner.recovery_required))
            while not self.stopping.is_set():
                runner.ensure_running()
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
    def __init__(self, root, binary, data_root, opener=open_default_browser, jam_runtime=None, tor_runtime=None):
        import tkinter as tk
        from tkinter import ttk
        self.root, self.binary, self.data_root, self.opener = root, binary, data_root, opener
        self.jam_runtime = jam_runtime
        self.tor_runtime = tor_runtime
        self.session = None
        self.state = 'starting'
        self.quitting = False
        self.closed = False
        self.recovery = False
        self.failure = None
        self.setup_panel = None
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
        label('Your wallet', 22, '#f3f6fa', 'bold')
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
        self.poll_id = root.after(50, self.poll)

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
        self.session = Session(self.binary, self.data_root, self.jam_runtime, self.tor_runtime, guided_setup=True)
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
        self.poll_id = None
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
                elif event == 'setup':
                    self.show_setup()
                elif event in ('setup_progress','setup_error'):
                    if self.setup_panel is None:
                        continue
                    self.setup_message.configure(text=value)
                    if event == 'setup_error':
                        self.setup_submit.configure(state='normal')
                        self.setup_later.configure(text='Set up Jars later',state='normal')
                elif event == 'setup_complete':
                    self.hide_setup()
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
                elif event == 'opened' and self.state == 'ready' and self.failure is None:
                    self.status.configure(text='Your wallet is open in your browser.' if value else 'The browser could not open. Try Open Wallet again.')
                    self.action.configure(state='normal')
                elif event == 'open_error' and self.state == 'ready' and self.failure is None:
                    self.status.configure(text=value)
                    self.action.configure(state='normal')
                elif event == 'error':
                    self.hide_setup()
                    self.failure = value
                    self.status.configure(text=value)
                    self.action.configure(state='disabled')
        if self.state == 'closed' and not self.session.thread.is_alive():
            if self.quitting:
                self.finish_close()
                return
            self.state = 'failed'
            self.progress.stop()
            self.progress.pack_forget()
            self.status.configure(text=self.failure or 'Your wallet stopped. You can open it again.')
            self.action.configure(text='Try Again', state='normal')
        self.poll_id = self.root.after(50, self.poll)

    def close(self):
        if self.quitting:
            return
        self.quitting = True
        self.hide_setup()
        self.status.configure(text='Closing your wallet safely…')
        self.action.configure(state='disabled')
        self.progress.pack(before=self.action, fill='x', padx=65, pady=12)
        self.progress.start(12)
        self.session.close()
        if not self.session.thread.is_alive():
            self.finish_close()

    def finish_close(self):
        self.closed = True
        self.progress.stop()
        if self.poll_id is not None:
            self.root.after_cancel(self.poll_id)
            self.poll_id = None
        self.root.destroy()

    def show_setup(self):
        import tkinter as tk
        from tkinter import filedialog
        self.state='setup'
        self.progress.stop(); self.progress.pack_forget()
        self.action.configure(state='disabled')
        self.status.configure(text='Connect an XBT node to host Jars on this computer.')
        panel=tk.Toplevel(self.root); self.setup_panel=panel
        panel.title('Set up Jars'); panel.configure(background='#101c2c')
        panel.transient(self.root); panel.grab_set(); panel.protocol('WM_DELETE_WINDOW',self.defer_setup)
        frame=tk.Frame(panel,background='#101c2c'); frame.pack(padx=26,pady=22,fill='both',expand=True)
        def label(text,size=11):
            widget=tk.Label(frame,text=text,bg='#101c2c',fg='#d9e5f3',font=('TkDefaultFont',size),
                anchor='w',justify='left',wraplength=390);widget.pack(fill='x',pady=(6,3));return widget
        label('Your Jars, on this computer',20)
        label('Connect your XBT node. Your Jars wallet stays separate from your main wallet.')
        self.setup_fields={}
        for key,title in [('endpoint','Node RPC address'),('username','RPC username'),('password','RPC password')]:
            label(title)
            entry=tk.Entry(frame,font=('TkDefaultFont',12),show='•' if key=='password' else '',
                bg='#1e3047',fg='#f3f6fa',insertbackground='#ffffff',relief='flat')
            entry.pack(fill='x',ipady=7);self.setup_fields[key]=entry
        self.setup_tor=tk.BooleanVar(value=False)
        tk.Checkbutton(frame,text='Use Tor',variable=self.setup_tor,bg='#101c2c',fg='#d9e5f3',
            selectcolor='#1e3047',activebackground='#101c2c',activeforeground='#ffffff').pack(anchor='w',pady=10)
        self.setup_ca=''
        def certificate():
            path=filedialog.askopenfilename(parent=panel,title='Choose public CA certificate')
            if not path:return
            try:
                with open(path,'rb') as stream: data=stream.read(65537)
                text=data.decode('ascii')
                if len(data)>65536 or 'PRIVATE KEY' in text or 'BEGIN CERTIFICATE' not in text:raise ValueError()
                self.setup_ca=text; ca.configure(text='Certificate selected')
            except (OSError,ValueError):self.setup_message.configure(text='Choose a public CA certificate, not a private key.')
        ca=tk.Button(frame,text='Add certificate (optional)',command=certificate);ca.pack(anchor='w')
        self.setup_message=label('Your connection is verified before it is saved.')
        self.setup_submit=tk.Button(frame,text='Verify and save',command=self.save_setup,bg='#ff8956',fg='#101c2c',
            font=('TkDefaultFont',12,'bold'),relief='flat',pady=10);self.setup_submit.pack(fill='x',pady=(14,6))
        self.setup_later=tk.Button(frame,text='Set up Jars later',command=self.defer_setup);self.setup_later.pack(fill='x')
        panel.bind('<Return>',lambda _:self.save_setup())
        self.setup_fields['endpoint'].focus_set()

    def save_setup(self):
        if str(self.setup_submit['state'])=='disabled':return
        settings={key:field.get().strip() if key!='password' else field.get() for key,field in self.setup_fields.items()}
        settings.update(tor=self.setup_tor.get(),ca_pem=self.setup_ca)
        self.setup_fields['password'].delete(0,'end')
        self.setup_submit.configure(state='disabled');self.setup_later.configure(text='Cancel setup')
        self.setup_message.configure(text='Checking your connection…')
        self.session.setup({'action':'configure_jars','settings':settings})

    def defer_setup(self):
        if self.setup_panel is None:return
        if str(self.setup_submit['state'])=='disabled':
            self.session.close();self.hide_setup();self.status.configure(text='Cancelling setup…');return
        self.session.setup({'action':'skip_jars'});self.hide_setup()

    def hide_setup(self):
        if getattr(self,'setup_panel',None) is not None:
            self.setup_panel.destroy();self.setup_panel=None
            self.setup_ca='';self.state='starting'
            self.status.configure(text='Starting your wallet…')
            self.progress.pack(before=self.action,fill='x',padx=65,pady=12);self.progress.start(12)


def main():
    if not sys.platform.startswith('linux'):
        raise SystemExit('This launcher is for Linux. Use the native macOS launcher on a Mac.')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--qa-root', type=Path)
    parser.add_argument('--jam-python', type=Path)
    parser.add_argument('--jam-entry', type=Path)
    parser.add_argument('--jam-executable', type=Path)
    parser.add_argument('--tor-runtime', type=Path)
    args = parser.parse_args()
    if args.jam_executable and (args.jam_python or args.jam_entry):
        parser.error('Choose bundled Jars or development Python paths')
    if bool(args.jam_python) != bool(args.jam_entry):
        parser.error('Supply both packaged Jars runtime paths')
    if args.qa_root is not None and not args.qa_root.is_absolute():
        parser.error('QA storage must be an absolute, isolated path.')
    import tkinter as tk
    root = tk.Tk()
    Window(root, args.binary.resolve(strict=True), args.qa_root or default_data_root(),
           jam_runtime=(args.jam_executable, None) if args.jam_executable else ((args.jam_python, args.jam_entry) if args.jam_python else None), tor_runtime=args.tor_runtime)
    root.mainloop()


if __name__ == '__main__':
    main()
