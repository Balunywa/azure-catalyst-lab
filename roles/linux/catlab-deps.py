#!/usr/bin/env python3
"""catlab dependency agent (Linux).

Keeps real TCP / HTTP keep-alive sessions open from this server to each upstream dependency listed in
/etc/catlab/deps.json, so agentless dependency analysis (which samples active connections) sees a
realistic, always-on dependency map. Reports per-dependency status as JSON on :9109.
"""
import http.client
import http.server
import json
import select
import socket
import threading
import time

DEPS = json.load(open('/etc/catlab/deps.json'))
STATUS = {}


def closed(sock):
    r, _, _ = select.select([sock], [], [], 0)
    if not r:
        return False
    try:
        return sock.recv(1, socket.MSG_PEEK) == b''
    except OSError:
        return True


def tcp_worker(d, key):
    while True:
        try:
            s = socket.create_connection((d['host'], d['port']), timeout=10)
            STATUS[key] = {'ok': True, 'since': time.time()}
            while not closed(s):
                time.sleep(5)
            s.close()
            STATUS[key] = {'ok': True, 'note': 'peer closed, reconnecting'}
            time.sleep(2)
        except Exception as e:  # noqa: BLE001
            STATUS[key] = {'ok': False, 'err': str(e)[:80]}
            time.sleep(15)


def http_worker(d, key):
    while True:
        try:
            c = http.client.HTTPConnection(d['host'], d['port'], timeout=10)
            while True:
                c.request('GET', d.get('path', '/'), headers={'User-Agent': 'catlab-deps'})
                r = c.getresponse()
                r.read()
                STATUS[key] = {'ok': r.status < 500, 'code': r.status}
                time.sleep(20)
        except Exception as e:  # noqa: BLE001
            STATUS[key] = {'ok': False, 'err': str(e)[:80]}
            time.sleep(10)


class Status(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = json.dumps(STATUS).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


for dep in DEPS:
    k = f"{dep['name']}:{dep['port']}"
    target = http_worker if dep.get('proto') == 'http' else tcp_worker
    threading.Thread(target=target, args=(dep, k), daemon=True).start()

http.server.ThreadingHTTPServer(('0.0.0.0', 9109), Status).serve_forever()
