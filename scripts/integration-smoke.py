"""用临时凭据和本机回环 SSH 服务验证产品；不写用户 known_hosts，不开启系统 sshd。"""
import fcntl
import json
import os
from pathlib import Path
import secrets
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

import paramiko


class ResumeTraceHandle(paramiko.SFTPHandle):
    """仅显式标记的隔离测试目录记录偏移，不记录任何文件内容。"""
    def __init__(self, flags, path):
        super().__init__(flags)
        self.trace_path = path

    def trace(self, operation, offset, count):
        if (self.trace_path.parent / ".nc2-resume-trace-enabled").is_file():
            with (self.trace_path.parent / ".nc2-resume-trace.jsonl").open("a") as log:
                log.write(json.dumps({"operation": operation, "path": str(self.trace_path), "offset": offset, "count": count}) + "\n")

    def read(self, offset, length):
        self.trace("read", offset, length)
        options = self.pipeline_options()
        if offset == options.get("eofOffset"):
            return b""
        if options.get("shortRead"):
            length = min(length, options["shortRead"])
        return super().read(offset, length)

    def write(self, offset, data):
        self.trace("write", offset, len(data))
        if offset == self.pipeline_options().get("failWriteOffset"):
            return paramiko.SFTP_PERMISSION_DENIED
        return super().write(offset, data)

    def pipeline_options(self):
        marker = self.trace_path.parent / ".nc2-pipeline.json"
        return json.loads(marker.read_text()) if marker.is_file() else {}


class FixtureSFTPServer(paramiko.SFTPServer):
    """在显式标记目录对负载响应注入延迟/乱序，实际文件操作仍由 Paramiko 执行。"""
    def __init__(self, *args, **kwargs):
        self.packet_lock = threading.Lock()
        self.response_delay = 0
        super().__init__(*args, **kwargs)

    def _process(self, kind, request_number, message):
        self.response_delay = 0
        if kind in (5, 6):
            probe = paramiko.Message(message.get_remainder())
            handle = self.file_table.get(probe.get_binary())
            offset = probe.get_int64()
            if isinstance(handle, ResumeTraceHandle):
                options = handle.pipeline_options()
                if offset == options.get("wrongIDOffset"):
                    request_number += 100000
                self.response_delay = options.get("delay", 0)
                if options.get("reorder"):
                    self.response_delay += (15 - ((offset // 32768) % 16)) * 0.002
        try:
            super()._process(kind, request_number, message)
        finally:
            self.response_delay = 0

    def _send_packet(self, kind, message):
        def send():
            try:
                with self.packet_lock:
                    super(FixtureSFTPServer, self)._send_packet(kind, message)
            except (EOFError, OSError):
                pass
        if self.response_delay:
            timer = threading.Timer(self.response_delay, send)
            timer.daemon = True
            timer.start()
        else:
            send()


class FixtureSFTP(paramiko.SFTPServerInterface):
    def __init__(self, server, *, directory):
        super().__init__(server)
        self.root = directory.resolve()

    def path(self, value):
        path = Path(value) if value.startswith("/") else self.root / value
        # 测试服务器只允许访问自己创建的临时目录。
        path.resolve().relative_to(self.root)
        return path

    def canonicalize(self, path):
        return str(self.path(path).resolve())

    def list_folder(self, path):
        try:
            target = self.path(path)
            if target.name == "nc2-search-denied":
                return paramiko.SFTP_PERMISSION_DENIED
            if target.name == "nc2-search-missing":
                return paramiko.SFTP_NO_SUCH_FILE
            if target.name == "nc2-follow-slow-list": time.sleep(1.4)
            if target.name == "nc2-estimate-delayed":
                (target.parent / ".nc2-estimate-started").touch()
                deadline = time.monotonic() + 10
                while not (target.parent / ".nc2-estimate-release").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
            result = []
            for child in target.iterdir():
                attrs = paramiko.SFTPAttributes.from_stat(child.lstat())
                attrs.filename = child.name
                if child.name == "nc2-permissions-partial-listing":
                    attrs.st_size = attrs.st_atime = attrs.st_mtime = None
                result.append(attrs)
            if target.name == "nc2-search-invalid" and result:
                result.append(result[0])
            return result
        except (OSError, ValueError) as error:
            return paramiko.SFTPServer.convert_errno(getattr(error, "errno", None) or 13)

    def lstat(self, path):
        try:
            target = self.path(path)
            if target.name == "nc2-estimate-denied":
                return paramiko.SFTP_PERMISSION_DENIED
            attrs = paramiko.SFTPAttributes.from_stat(target.lstat())
            if target.name == "nc2-estimate-unknown-size": attrs.st_size = None
            if target.name == "nc2-estimate-max-size": attrs.st_size = (1 << 64) - 1
            _, options = self.metadata_options(target)
            if target.name == options.get("sourceName"):
                if "sourceMode" in options: attrs.st_mode = (attrs.st_mode & 0o170000) | options["sourceMode"]
                if options.get("unknownTime"): attrs.st_mtime = attrs.st_atime = None
                if options.get("unknownSize"): attrs.st_size = None
            return attrs
        except (OSError, ValueError) as error:
            return paramiko.SFTPServer.convert_errno(getattr(error, "errno", None) or 13)

    stat = lstat

    def metadata_options(self, target):
        for parent in target.parents:
            if not parent.is_relative_to(self.root): break
            marker = parent / ".nc2-metadata.json"
            if marker.is_file(): return parent, json.loads(marker.read_text())
        return None, {}

    def chattr(self, path, attr):
        try:
            target = self.path(path)
            if target.name.startswith("nc2-permissions-") and attr._flags != attr.FLAG_PERMISSIONS:
                return paramiko.SFTP_BAD_MESSAGE
            if target.name == "nc2-permissions-denied":
                return paramiko.SFTP_PERMISSION_DENIED
            if target.name == "nc2-permissions-ignored":
                return paramiko.SFTP_OK
            policy_root, options = self.metadata_options(target)
            if policy_root:
                before = target.stat()
                with (policy_root / ".nc2-metadata-events.jsonl").open("a") as stream:
                    stream.write(json.dumps({"path": str(target), "flags": attr._flags,
                                             "atimePreserved": attr.st_atime is None or attr.st_atime == int(before.st_atime)}) + "\n")
                if target.name == options.get("denyName"): return paramiko.SFTP_PERMISSION_DENIED
                if target.name == options.get("ignoreName"): return paramiko.SFTP_OK
                if target.name == options.get("partialName"):
                    if attr.st_mtime is not None: os.utime(target, (attr.st_atime, attr.st_mtime))
                    return paramiko.SFTP_PERMISSION_DENIED
            paramiko.SFTPServer.set_file_attr(str(target), attr)
            if target.name == "nc2-permissions-delay": time.sleep(1)
            if target.name == options.get("delayName"): time.sleep(1)
            return paramiko.SFTP_OK
        except (OSError, ValueError) as error:
            return paramiko.SFTPServer.convert_errno(getattr(error, "errno", None) or 13)

    def open(self, path, flags, attr):
        try:
            target = self.path(path)
            descriptor = os.open(target, flags, 0o600)
            handle = ResumeTraceHandle(flags, target)
            if flags & os.O_WRONLY:
                handle.writefile = os.fdopen(descriptor, "wb")
            else:
                handle.readfile = os.fdopen(descriptor, "rb")
            return handle
        except (OSError, ValueError) as error:
            return paramiko.SFTPServer.convert_errno(getattr(error, "errno", None) or 13)

    def mkdir(self, path, attr):
        try:
            self.path(path).mkdir()
            if Path(path).name == "nc2-delay-create": time.sleep(0.5)
            return paramiko.SFTP_OK
        except (OSError, ValueError) as error:
            return paramiko.SFTPServer.convert_errno(getattr(error, "errno", None) or 13)

    def rename(self, oldpath, newpath):
        try:
            source, target = self.path(oldpath), self.path(newpath)
            if target.name == "nc2-denied-install" and not source.name.startswith(".nc2shell-backup-"):
                return paramiko.SFTP_PERMISSION_DENIED
            if target.exists():
                return paramiko.SFTP_FAILURE
            if source.is_dir():
                source.rename(target)
            else:
                os.link(source, target)
                source.unlink()
            if target.name == "nc2-delay-rename": time.sleep(0.5)
            if source.name == "nc2-delay-backup" and target.name.startswith(".nc2shell-backup-"): time.sleep(1)
            return paramiko.SFTP_OK
        except (OSError, ValueError) as error:
            return paramiko.SFTPServer.convert_errno(getattr(error, "errno", None) or 13)

    def remove(self, path):
        try:
            target = self.path(path)
            # 通过真实 SFTP 状态验证权限错误，不修改宿主文件权限。
            if target.name == "nc2-denied-delete.txt":
                return paramiko.SFTP_PERMISSION_DENIED
            target.unlink()
            if target.name == "nc2-delay-delete.txt": time.sleep(0.5)
            return paramiko.SFTP_OK
        except (OSError, ValueError) as error:
            return paramiko.SFTPServer.convert_errno(getattr(error, "errno", None) or 13)

    def rmdir(self, path):
        try:
            self.path(path).rmdir()
            return paramiko.SFTP_OK
        except (OSError, ValueError) as error:
            return paramiko.SFTPServer.convert_errno(getattr(error, "errno", None) or 13)


auth_stats_lock = threading.Lock()


class Server(paramiko.ServerInterface):
    def __init__(self, password, client_key, directory=None):
        self.password = password
        self.client_key = client_key
        self.shell = threading.Event()
        self.size = (32, 100)
        self.master = None
        self.command = None
        self.username = None
        self.directory = directory
        self.primary_channel = None
        self.environment = None
        self.exec_workers = []

    def record_auth(self, key, credential_sent=False):
        if self.directory is None:
            return
        with auth_stats_lock:
            path = self.directory / "auth-stats.json"
            stats = json.loads(path.read_text()) if path.exists() else {}
            stats[key] = stats.get(key, 0) + 1
            if credential_sent:
                stats["savedPasswordSentToChallenge"] = True
            temporary = path.with_suffix(".tmp")
            temporary.write_text(json.dumps(stats))
            temporary.replace(path)

    def get_allowed_auths(self, username):
        if username == "challenge-test":
            return "keyboard-interactive"
        return "password" if username in ["password-test", "password-attempt-test"] else "publickey"

    def check_auth_password(self, username, password):
        self.username = username
        if username == "password-attempt-test":
            self.record_auth("passwordAttempts")
        return paramiko.AUTH_SUCCESSFUL if username in ["password-test", "password-attempt-test"] and secrets.compare_digest(password, self.password) else paramiko.AUTH_FAILED

    def check_auth_interactive(self, username, submethods):
        self.username = username
        if username != "challenge-test":
            return paramiko.AUTH_FAILED
        self.record_auth("interactiveRequests")
        # 刻意伪装成标准 password 提示，验证不能靠提示文字向任意 challenge 发送保存密码。
        return paramiko.InteractiveQuery("", "", ("challenge-test@127.0.0.1's password: ", False))

    def check_auth_interactive_response(self, responses):
        self.record_auth("interactiveResponses", any(secrets.compare_digest(value, self.password) for value in responses))
        return paramiko.AUTH_SUCCESSFUL if responses == ["manual-challenge"] else paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        self.username = username
        return paramiko.AUTH_SUCCESSFUL if username in ["key-test", "zsh-test", "slow-test", "fish-test", "bash-login-path-test", "zsh-login-path-test", "fish-login-path-test"] and key == self.client_key else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        self.size = (height, width)
        self.primary_channel = channel.get_id()
        return True

    def check_channel_window_change_request(self, channel, width, height, pixelwidth, pixelheight):
        self.size = (height, width)
        if self.master is not None:
            fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
        return True

    def check_channel_shell_request(self, channel):
        self.shell.set()
        return True

    def check_channel_exec_request(self, channel, command):
        if self.primary_channel is not None and channel.get_id() != self.primary_channel:
            worker = threading.Thread(target=self.serve_exec, args=(channel, command.decode("utf-8")), daemon=True)
            self.exec_workers.append(worker)
            worker.start()
            return True
        self.command = command.decode("utf-8")
        self.shell.set()
        return True

    def serve_exec(self, channel, command):
        child = None
        try:
            if (self.directory / ".nc2-follow-probe-delay").exists():
                command = "/bin/sleep 8; " + command
            child = subprocess.Popen([self.environment["SHELL"], "-c", command], cwd=self.directory,
                                     env=self.environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
            input_open = True
            while not channel.closed:
                sources = [child.stdout] + ([channel] if input_open else [])
                readable, _, _ = select.select(sources, [], [], 0.1)
                if channel in readable:
                    data = channel.recv(65536)
                    if data:
                        child.stdin.write(data); child.stdin.flush()
                    else:
                        child.stdin.close(); input_open = False
                if child.stdout in readable:
                    data = os.read(child.stdout.fileno(), 65536)
                    if not data: break
                    channel.sendall(data)
            if not channel.closed:
                channel.send_exit_status(child.wait(timeout=1))
                channel.close()
        except (EOFError, OSError, paramiko.SSHException, subprocess.TimeoutExpired):
            pass
        finally:
            if child is not None:
                # 观察循环读到 EOF 即正常退出，避免与短暂的 setuid ps 子进程同时强杀进程组。
                if not child.stdin.closed: child.stdin.close()
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    try: os.killpg(child.pid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        if child.poll() is None: child.kill()
                    child.wait()
                child.stdout.close()
            channel.close()


def serve_connection(connection, host_key, client_key, password, directory):
    transport = paramiko.Transport(connection)
    master = slave = None
    child = None
    try:
        transport.add_server_key(host_key)
        server = Server(password, client_key, directory)
        transport.set_subsystem_handler("sftp", FixtureSFTPServer, FixtureSFTP, directory=directory)
        transport.start_server(server=server)
        channel = transport.accept(20)
        if channel is None or not server.shell.wait(15):
            return
        master, slave = os.openpty()
        server.master = master
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", *server.size, 0, 0))

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        environment = {
            "HOME": str(directory), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8", "TERM": "xterm-256color", "HISTFILE": "/dev/null",
            "PS1": "nc2test$ ",
            "PROMPT_COMMAND": "printf '\\033]7;file://nc2shell-test%s\\007' \"$PWD\"",
            "SHELL": "/bin/zsh" if server.username in ["zsh-test", "zsh-login-path-test"] else "/bin/bash",
            "TMPDIR": str(directory / "startup-temporary"),
            "NC2_TEST_SLOW": "1" if server.username == "slow-test" else "0",
            "TMUX_TMPDIR": str(directory),
        }
        if os.environ.get("NC2SHELL_TEST_TMUX"):
            tmux_bin = str(Path(os.environ["NC2SHELL_TEST_TMUX"]).parent)
            if server.username.endswith("-login-path-test"):
                environment["NC2_TEST_TMUX_BIN"] = tmux_bin
            else:
                environment["PATH"] = tmux_bin + ":" + environment["PATH"]
        if os.environ.get("NC2SHELL_TEST_TERMINFO"):
            environment["TERMINFO"] = os.environ["NC2SHELL_TEST_TERMINFO"]
        if server.username in ["fish-test", "fish-login-path-test"]:
            environment["SHELL"] = os.environ["NC2SHELL_TEST_FISH"]
            environment["XDG_CONFIG_HOME"] = str(directory / ".config")
            environment["XDG_DATA_HOME"] = str(directory / "fish-data")
        server.environment = environment
        command = [environment["SHELL"], "-c", server.command] if server.command is not None else ["/bin/bash", "--noprofile", "--norc", "-i"]
        child = subprocess.Popen(command,
                                 stdin=slave, stdout=slave, stderr=slave,
                                 cwd=directory, env=environment, preexec_fn=controlling_terminal)
        os.close(slave)
        slave = None
        while transport.is_active() and not channel.closed:
            # 用例明确写入一次性标记，模拟服务器断开传输，不向产品注入退出通知。
            trigger = directory / ("disconnect-" + str(server.username))
            if trigger.is_file():
                try:
                    trigger.unlink()
                except FileNotFoundError:
                    pass
                else:
                    transport.close()
                    return
            readable, _, _ = select.select([master, channel], [], [], 0.1)
            if master in readable:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                channel.sendall(data)
            if channel in readable:
                data = channel.recv(65536)
                if not data:
                    break
                os.write(master, data)
            if child.poll() is not None:
                break
        if transport.is_active() and not channel.closed:
            # PTY EOF 可能早于 waitpid 可见，必须等退出码再关闭通道。
            try:
                channel.send_exit_status(child.wait(timeout=1))
            except subprocess.TimeoutExpired:
                pass
        channel.close()
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        if child is not None:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        if master is not None:
            os.close(master)
        if slave is not None:
            os.close(slave)
        transport.close()
        for worker in server.exec_workers:
            worker.join(timeout=2)


def main():
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="nc2shell-ssh-", dir=root / "work") as temporary:
        directory = Path(temporary)
        (directory / "My Files").mkdir()
        (directory / "startup-temporary").mkdir()
        (directory / ".bash_profile").write_text('''if [ "$NC2_TEST_SLOW" = 1 ]; then
printf 'STARTUP_WAIT\\n'
if read -r -t 1 NC2_TEST_INPUT; then printf 'UNEXPECTED_STARTUP_INPUT\\n'; fi
printf 'STARTUP_READY\\n'
fi
PS1='nc2test$ '
if [ -n "${NC2_TEST_TMUX_BIN-}" ]; then export PATH="$NC2_TEST_TMUX_BIN:$PATH"; fi
''')
        (directory / ".zshenv").write_text('export NC2_STARTUPS=$(( ${NC2_STARTUPS:-0} + 1 ))\n')
        (directory / ".zprofile").write_text('if [ -n "${NC2_TEST_TMUX_BIN-}" ]; then export PATH="$NC2_TEST_TMUX_BIN:$PATH"; fi\ncd "$HOME/My Files"\n')
        (directory / ".zshrc").write_text("PROMPT='nc2test$ '; __old_prompt() { :; }; precmd_functions+=(__old_prompt)\n")
        (directory / ".config/fish").mkdir(parents=True)
        (directory / ".config/fish/config.fish").write_text("set -g fish_greeting\nif set -q NC2_TEST_TMUX_BIN; set -gx PATH \"$NC2_TEST_TMUX_BIN\" $PATH; end\nfunction fish_prompt; printf 'nc2fish$ '; end\ncd \"$HOME/My Files\"\n")
        host_key = paramiko.RSAKey.generate(2048)
        client_key = paramiko.RSAKey.generate(2048)
        wrong_key = paramiko.RSAKey.generate(2048)
        key_path = directory / "client key"
        client_key.write_private_key_file(str(key_path))
        encrypted_key = directory / "encrypted client key"
        key_passphrase = secrets.token_urlsafe(24)
        client_key.write_private_key_file(str(encrypted_key), password=key_passphrase)
        password = secrets.token_urlsafe(24)
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(10)
        port = listener.getsockname()[1]
        known_hosts = directory / "known_hosts"
        wrong_hosts = directory / "wrong_hosts"
        for path, key in [(known_hosts, host_key), (wrong_hosts, wrong_key)]:
            path.write_text(f"[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n")
        fixture = directory / "fixture.json"
        with open(fixture, "w", opener=lambda path, flags: os.open(path, flags, 0o600)) as stream:
            json.dump(dict(port=port, key=str(key_path), knownHosts=str(known_hosts), wrongKnownHosts=str(wrong_hosts), password=password, directory=str(directory), encryptedKey=str(encrypted_key), keyPassphrase=key_passphrase), stream)

        workers = []

        def accept():
            while True:
                try:
                    connection, _ = listener.accept()
                except OSError:
                    return
                worker = threading.Thread(target=serve_connection, args=(connection, host_key, client_key, password, directory), daemon=True)
                workers.append(worker)
                worker.start()

        threading.Thread(target=accept, daemon=True).start()
        environment = os.environ | {"NC2SHELL_TEST_FIXTURE": str(fixture)}
        try:
            result = subprocess.run(["bash", "scripts/swift.sh", "test", *sys.argv[1:]], cwd=root, env=environment)
        finally:
            listener.close()
            for worker in workers:
                worker.join(timeout=3)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
