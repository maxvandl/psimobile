#!/usr/bin/env python3
# Переносит на подключённый iPhone аккаунт и PGP-ключи из Psi+ (см. Sources/App/PsiImport.swift).
#   ./scripts/run.sh device && ./scripts/import-psi.py [JID]
# Без JID берётся включённый аккаунт. Секреты не выводятся, временный файл удаляется.
import base64
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import xml.etree.ElementTree as ET
from datetime import datetime

ACCOUNTS = "~/Library/Application Support/Psi+/profiles/default/accounts.xml"
HISTORY = "~/Library/Application Support/Psi+/profiles/default/history/history.db"
OLD_DOMAINS = []  # прежние серверы: переписка с них вливается в чат с тем же логином на текущем
GPG = "/usr/local/bin/gpg"  # MacGPG: именно его ключи видит Psi+, у gpg из Homebrew своё хранилище
BUNDLE = "am.local.psimobile"
CONTAINER = ["--domain-type", "appDataContainer", "--domain-identifier", BUNDLE]


def run(*cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def tag(e):
    return e.tag.split("}")[-1]


def find_account(want):
    root = ET.parse(os.path.expanduser(ACCOUNTS)).getroot()
    for a in root.iter():
        jid, enabled = a.find("{*}jid"), a.find("{*}enabled")
        if jid is None or enabled is None:
            continue
        if jid.text == want or (want is None and enabled.text == "true"):
            return a
    sys.exit("Аккаунт не найден в Psi+")


def find_device():
    out = run("xcrun", "devicectl", "list", "devices").stdout
    for line in out.splitlines():
        if "iPhone" in line and "simulated" not in line and "unavailable" not in line:
            for word in line.split():
                if len(word) >= 25 and all(c in "0123456789ABCDEF-" for c in word):
                    return word
    sys.exit("iPhone не найден")


def read_history(jid):
    """Сообщения 1:1 из истории Psi+: type 0/1/4 — текст, direction 1 — исходящее, 2 — входящее."""
    domain = jid.split("@")[1]
    uri = "file:" + urllib.parse.quote(os.path.expanduser(HISTORY)) + "?mode=ro"
    db = sqlite3.connect(uri, uri=True)
    rows = db.execute("select c.jid, e.date, e.direction, e.m_text from events e "
                      "join contacts c on c.id = e.contact_id "
                      "where e.type in (0, 1, 4) and e.m_text is not null and e.m_text != ''").fetchall()
    db.close()
    current = {r[0].split("@")[0] for r in rows if r[0].endswith("@" + domain)}
    items, skipped = [], 0
    for contact, date, direction, text in rows:
        local, _, server = contact.partition("@")
        if server != domain and not (server in OLD_DOMAINS and local in current):
            skipped += 1
            continue
        items.append({"peer": f"{local}@{domain}", "text": text, "outgoing": direction == 1,
                      "date": datetime.fromisoformat(date).timestamp()})
    return items, skipped


def main():
    acc = find_account(sys.argv[1] if len(sys.argv) > 1 else None)
    jid = acc.find("{*}jid").text
    device = find_device()
    # На заблокированном телефоне приложение не запустится и не удалит файл с секретами.
    if "passcodeRequired: false" not in run("xcrun", "devicectl", "device", "info", "lockState", "--device", device).stdout:
        sys.exit("Разблокируйте iPhone и повторите")

    # Пароль Psi+ держит в Keychain; macOS может спросить разрешение.
    pw = run("security", "find-generic-password", "-s", "xmpp", "-a", jid, "-w", timeout=180)
    if pw.returncode != 0:
        sys.exit("Нет доступа к паролю в Keychain")

    secret = run(GPG, "--armor", "--export-secret-keys", acc.find("{*}pgp-secret-key-id").text, timeout=180)
    if "PRIVATE KEY" not in secret.stdout:
        sys.exit("Не удалось экспортировать секретный ключ")

    contacts, missing = {}, []
    for binding in acc.find("{*}pgp-key-bindings"):
        fields = {tag(c): (c.text or "").strip() for c in binding}
        armored = run(GPG, "--armor", "--export", fields["data"]).stdout
        if "PUBLIC KEY" in armored:
            contacts[fields["key"]] = armored
        else:
            missing.append(fields["key"])

    # Сертификат, принятый вручную в Psi+ (нужен, если сервер не проходит обычную проверку).
    override = acc.find("{*}tls/{*}override-certificate").text
    pin = hashlib.sha256(base64.b64decode(override)).hexdigest() if override else None

    history, skipped = read_history(jid)
    print(f"История: {len(history)} сообщений, пропущено {skipped}")

    payload = {"jid": jid, "password": pw.stdout.rstrip("\n"), "secretKey": secret.stdout,
               "passphrase": "", "contactKeys": contacts, "certPin": pin,
               "pgpDisabled": [i.text for i in acc.find("{*}pgp-disabled-chats")],
               "history": history}

    fd, path = tempfile.mkstemp(suffix=".json")  # права 0600
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        copy = run("xcrun", "devicectl", "device", "copy", "to", "--device", device, *CONTAINER,
                   "--source", path, "--destination", "Documents/psi-import.json")
        if copy.returncode != 0:
            sys.exit("Не удалось скопировать файл на iPhone:\n" + copy.stderr[-800:])
    finally:
        os.remove(path)

    def wipe_remote():
        """Затирает файл с секретами на iPhone пустым: его прочитает и удалит только Debug-сборка."""
        fd, empty = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        run("xcrun", "devicectl", "device", "copy", "to", "--device", device, *CONTAINER,
            "--source", empty, "--destination", "Documents/psi-import.json")
        os.remove(empty)

    launch = run("xcrun", "devicectl", "device", "process", "launch", "--device", device,
                 "--terminate-existing", BUNDLE)
    if launch.returncode != 0:
        wipe_remote()
        sys.exit("Не удалось запустить приложение, файл с секретами затёрт:\n" + launch.stderr[-800:])

    time.sleep(40)  # импорт, подключение и ростер
    fd, status = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    got = run("xcrun", "devicectl", "device", "copy", "from", "--device", device, *CONTAINER,
              "--source", "Documents/psi-import-status.json", "--destination", status)
    if got.returncode != 0:
        os.remove(status)
        # Release-сборка файл не читает и не удаляет, а Documents попадают в резервные копии.
        wipe_remote()
        sys.exit("Отчёт с iPhone не получен (установлена не Debug-сборка?), файл с секретами затёрт:\n" + got.stderr[-800:])
    with open(status) as f:
        print(json.dumps(json.load(f), indent=2, ensure_ascii=False))
    os.remove(status)
    if missing:
        print("Нет ключа в MacGPG:", ", ".join(missing))


main()
