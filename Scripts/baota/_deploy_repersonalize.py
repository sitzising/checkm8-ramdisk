#!/usr/bin/env python3
import paramiko
from pathlib import Path

HOST = "tool.a-cheng.cn"
USER = "root"
PASSWORD = "XYP1004xyp"
ROOT = "/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down"
LOCAL = Path(__file__).resolve().parent

FILES = [
    (LOCAL / "personalize_shsh.py", f"{ROOT}/personalize_shsh.py"),
    (LOCAL / "personalize-ramdisk.sh", f"{ROOT}/personalize-ramdisk.sh"),
    (LOCAL / "personalize_shsh.py", f"{ROOT}/Scripts/personalize_shsh.py"),
    (LOCAL / "personalize-ramdisk.sh", f"{ROOT}/Scripts/personalize-ramdisk.sh"),
    (LOCAL / "_remote-repersonalize.sh", f"{ROOT}/_remote-repersonalize.sh"),
]


def main() -> int:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASSWORD, timeout=20)
    sftp = ssh.open_sftp()
    try:
        sftp.mkdir(f"{ROOT}/Scripts")
    except OSError:
        pass
    for loc, rem in FILES:
        data = loc.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        with sftp.file(rem, "wb") as f:
            f.write(data)
        print("OK", rem)
    sftp.close()

    cmd = f"bash {ROOT}/_remote-repersonalize.sh"
    stdin, stdout, stderr = ssh.exec_command(cmd, timeout=600)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    print("===STDOUT===")
    print(out)
    if err:
        print("===STDERR===")
        print(err[-5000:])
    print("exit", code)
    ssh.close()
    return code


if __name__ == "__main__":
    raise SystemExit(main())
