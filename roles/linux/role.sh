#!/bin/bash
# catlab Linux role installer. Run once by cloud-init (runcmd) after packages are installed.
# /etc/catlab/env provides ROLE, APP_PW and <SERVER>_IP style variables (e.g. CAT_PGSQL01).
set -euo pipefail
set -a; . /etc/catlab/env; set +a
log() { echo "[catlab-role] $*"; }

marker_page() {  # $1 = title, $2 = marker
  mkdir -p /var/www/html
  cat > /var/www/html/index.html <<EOF
<html><body><h1>$1</h1><p>catalyst-lab marker: $2</p></body></html>
EOF
}

case "$ROLE" in

web-proxy)
  cat > /var/www/html/index.html <<EOF
<html><body><h1>Catlab Retail - public website (CAT-LNX01)</h1><p>catalyst-lab marker: debian-nginx</p>
<ul><li><a href="/shop/">Shop</a></li><li><a href="/hr/">HR portal</a></li><li><a href="/time/">Timesheets</a></li></ul></body></html>
EOF
  cat > /etc/nginx/sites-available/default <<EOF
upstream catlab_shop { server ${CAT_WEB01}:80; keepalive 8; }
upstream catlab_hr   { server ${CAT_HRWEB01}:80; keepalive 8; }
upstream catlab_time { server ${CAT_TIME01}:80; keepalive 8; }
server {
  listen 80 default_server;
  root /var/www/html;
  index index.html;
  location /shop/ { proxy_pass http://catlab_shop/; proxy_http_version 1.1; proxy_set_header Connection ""; }
  location /hr/   { proxy_pass http://catlab_hr/;   proxy_http_version 1.1; proxy_set_header Connection ""; }
  location /time/ { proxy_pass http://catlab_time/; proxy_http_version 1.1; proxy_set_header Connection ""; }
}
EOF
  nginx -t && systemctl restart nginx
  ;;

postgres)
  PGV=$(ls /etc/postgresql | sort -V | tail -1); CONF=/etc/postgresql/$PGV/main
  sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$CONF/postgresql.conf"
  grep -q '192.168.100.0/24' "$CONF/pg_hba.conf" || echo "host all all 192.168.100.0/24 scram-sha-256" >> "$CONF/pg_hba.conf"
  systemctl restart postgresql
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') THEN CREATE ROLE app LOGIN PASSWORD '${APP_PW}'; END IF;
END \$\$;
SQL
  for db in inventory hr fulfillment; do
    runuser -u postgres -- psql -tc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1 || runuser -u postgres -- createdb -O app "$db"
  done
  runuser -u postgres -- psql -d inventory -c "CREATE TABLE IF NOT EXISTS items(sku text primary key, name text, qty int); ALTER TABLE items OWNER TO app; INSERT INTO items VALUES ('SKU-1','Coffee beans',120),('SKU-2','Loose-leaf tea',80),('SKU-3','Travel mug',40) ON CONFLICT DO NOTHING;"
  runuser -u postgres -- psql -d fulfillment -c "CREATE TABLE IF NOT EXISTS orders(id serial primary key, sku text, qty int, created timestamptz default now()); ALTER TABLE orders OWNER TO app;"
  runuser -u postgres -- psql -d hr -c "CREATE TABLE IF NOT EXISTS employees(id serial primary key, name text, dept text); ALTER TABLE employees OWNER TO app; INSERT INTO employees(name,dept) SELECT * FROM (VALUES ('Ana','Finance'),('Ben','Operations'),('Chen','Sales')) v WHERE NOT EXISTS (SELECT 1 FROM employees);"
  ;;

redis)
  sed -i 's/^bind .*/bind 0.0.0.0/' /etc/redis/redis.conf
  sed -i 's/^protected-mode yes/protected-mode no/' /etc/redis/redis.conf
  systemctl restart redis-server
  ;;

rabbitmq)
  systemctl enable --now rabbitmq-server
  for i in $(seq 1 40); do rabbitmqctl status >/dev/null 2>&1 && break; sleep 5; done
  rabbitmqctl add_user app "$APP_PW" 2>/dev/null || rabbitmqctl change_password app "$APP_PW"
  rabbitmqctl set_permissions -p / app ".*" ".*" ".*"
  ;;

prometheus)
  cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 30s
scrape_configs:
  - job_name: node
    static_configs:
      - targets: [${PROM_TARGETS}]
EOF
  systemctl restart prometheus
  ;;

inventory-api)
  mkdir -p /opt/inventory-api
  cat > /opt/inventory-api/app.py <<'EOF'
"""Inventory API: GET / lists stock from PostgreSQL (inventory db) and counts hits in Redis."""
import http.server, json, os, threading, time
import psycopg2, redis
PG = dict(host=os.environ['CAT_PGSQL01'], dbname='inventory', user='app', password=os.environ['APP_PW'], connect_timeout=5)
R = redis.Redis(host=os.environ['CAT_CACHE01'], port=6379, socket_timeout=5)
lock = threading.Lock(); conn = None
def db():
    global conn
    if conn is None or conn.closed:
        conn = psycopg2.connect(**PG)
    return conn
def keepwarm():                      # keep the PG + Redis sessions alive even without traffic
    while True:
        try:
            with lock:
                c = db().cursor(); c.execute('select 1'); db().commit()
            R.ping()
        except Exception:
            pass
        time.sleep(30)
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_GET(self):
        global conn
        body = {'app': 'inventory-api', 'marker': 'catalyst-lab marker: inventory-api'}
        if not self.path.startswith('/health'):
            try:
                with lock:
                    c = db().cursor(); c.execute('select sku, name, qty from items order by sku'); rows = c.fetchall(); db().commit()
                body['items'] = [dict(sku=a, name=b, qty=q) for a, b, q in rows]
                body['hits'] = R.incr('inventory:hits')
            except Exception as e:
                conn = None; body['error'] = str(e)[:120]
        b = json.dumps(body).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
threading.Thread(target=keepwarm, daemon=True).start()
http.server.ThreadingHTTPServer(('0.0.0.0', 8080), H).serve_forever()
EOF
  cat > /etc/systemd/system/inventory-api.service <<EOF
[Unit]
Description=Catlab inventory API
After=network-online.target
[Service]
EnvironmentFile=/etc/catlab/env
ExecStart=/usr/bin/python3 /opt/inventory-api/app.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable --now inventory-api
  ;;

orders-worker)
  mkdir -p /opt/orders
  cat > /opt/orders/worker.py <<'EOF'
"""Order worker: publishes simulated web orders to RabbitMQ, consumes them into PostgreSQL (fulfillment),
and drops an invoice file on the CAT-FS01 'Invoices' SMB share every 5 minutes."""
import json, os, random, subprocess, threading, time
import pika, psycopg2
PW = os.environ['APP_PW']
params = pika.ConnectionParameters(host=os.environ['CAT_MQ01'], credentials=pika.PlainCredentials('app', PW), heartbeat=30)
def producer():
    while True:
        try:
            c = pika.BlockingConnection(params); ch = c.channel(); ch.queue_declare('orders', durable=True)
            while True:
                ch.basic_publish('', 'orders', json.dumps({'sku': random.choice(['SKU-1', 'SKU-2', 'SKU-3']), 'qty': random.randint(1, 5)}))
                c.sleep(20)
        except Exception:
            time.sleep(10)
def consumer():
    while True:
        try:
            db = psycopg2.connect(host=os.environ['CAT_PGSQL01'], dbname='fulfillment', user='app', password=PW, connect_timeout=5)
            c = pika.BlockingConnection(params); ch = c.channel(); ch.queue_declare('orders', durable=True)
            def cb(chan, m, p, body):
                o = json.loads(body); cur = db.cursor(); cur.execute('insert into orders(sku, qty) values (%s, %s)', (o['sku'], o['qty'])); db.commit(); chan.basic_ack(m.delivery_tag)
            ch.basic_consume('orders', cb); ch.start_consuming()
        except Exception:
            time.sleep(10)
def invoices():
    while True:
        try:
            name = f'invoice-{int(time.time())}.txt'
            open('/tmp/' + name, 'w').write(f'Catlab Retail invoice {name}\n')
            subprocess.run(['smbclient', f"//{os.environ['CAT_FS01']}/Invoices", '-W', 'CAT-FS01', '-U', f'svc_app%{PW}', '-c', f'put /tmp/{name} {name}'], timeout=60, capture_output=True)
            os.remove('/tmp/' + name)
        except Exception:
            pass
        time.sleep(300)
threading.Thread(target=producer, daemon=True).start()
threading.Thread(target=invoices, daemon=True).start()
consumer()
EOF
  cat > /etc/systemd/system/orders-worker.service <<EOF
[Unit]
Description=Catlab order worker
After=network-online.target
[Service]
EnvironmentFile=/etc/catlab/env
ExecStart=/usr/bin/python3 /opt/orders/worker.py
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable --now orders-worker
  ;;

legacy-edi)
  systemctl enable --now vsftpd
  mkdir -p /srv/edi/outbound
  cat > /usr/local/bin/edi-drop.sh <<EOF
#!/bin/bash
set -a; . /etc/catlab/env; set +a
f=/srv/edi/outbound/edi-\$(date +%s).x12
echo "ISA*00*CATLAB*PO*\$(date +%Y%m%d)~" > "\$f"
smbclient "//\${CAT_FS01}/EDI-Inbox" -W CAT-FS01 -U "svc_app%\${APP_PW}" -c "put \$f \$(basename \$f)" >/dev/null 2>&1 && rm -f "\$f"
EOF
  chmod 0755 /usr/local/bin/edi-drop.sh
  echo "*/5 * * * * root /usr/local/bin/edi-drop.sh" > /etc/cron.d/catlab-edi
  marker_page 'Legacy EDI gateway (CAT-LEGACY01)' 'legacy-edi'
  ;;

*)
  log "no role-specific setup for '$ROLE'"
  ;;
esac
log "role $ROLE configured"
