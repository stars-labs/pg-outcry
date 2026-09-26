# Fake chain APIs for smoke-stage12: an Esplora subset (Bitcoin) and an EVM JSON-RPC
# subset on /evm. Runs as a container on the Supabase network so Postgres can reach it.
# state.json: {"deposits": {address: [[txid, vout, sats], ...]}}; broadcasts land in broadcast.log
import json, http.server, os, re
D = os.environ.get("STATE_DIR", "/state")
def state():
    try: return json.load(open(os.path.join(D, "state.json")))
    except FileNotFoundError: return {"deposits": {}}
class H(http.server.BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json"):
        b = body if isinstance(body, bytes) else (body if isinstance(body, str) else json.dumps(body)).encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p, st = self.path, state()
        if p == "/fee-estimates": return self.send(200, {"1": 3.2, "3": 1.4, "6": 1.1})
        if p == "/blocks/tip/height": return self.send(200, "1000", "text/plain")
        m = re.match(r"^/address/([^/]+)/(utxo|txs)$", p)
        if m:
            a, kind = m.groups(); deps = st["deposits"].get(a, [])
            if kind == "utxo":
                return self.send(200, [{"txid": t, "vout": v, "value": s, "status": {"confirmed": True, "block_height": 990}} for t, v, s in deps])
            return self.send(200, [{"txid": t, "status": {"confirmed": True, "block_height": 990},
                                    "vout": [{"scriptpubkey_address": "tb1qother", "value": 1}] * v + [{"scriptpubkey_address": a, "value": s}]} for t, v, s in deps])
        if re.match(r"^/tx/[0-9a-f]{64}/status$", p): return self.send(200, {"confirmed": True, "block_height": 1001})
        return self.send(404, "not found", "text/plain")
    def do_POST(self):
        if self.path == "/evm":
            req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            m = req["method"]
            if m == "eth_sendRawTransaction": open(os.path.join(D, "evm.log"), "a").write(req["params"][0] + "\n")
            res = {"eth_getTransactionCount": "0x0", "eth_gasPrice": "0x3b9aca00",
                   "eth_sendRawTransaction": "0x" + "ab" * 32}.get(m)
            return self.send(200, {"jsonrpc": "2.0", "id": req.get("id", 1), "result": res})
        if self.path == "/tx":
            raw = self.rfile.read(int(self.headers["Content-Length"])).decode()
            open(os.path.join(D, "broadcast.log"), "a").write(raw + "\n")
            return self.send(200, "ok", "text/plain")
        return self.send(404, "not found", "text/plain")
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 18999), H).serve_forever()
