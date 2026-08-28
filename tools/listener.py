# Подслушивающий стенд для ручных проб: печатает, кто и с какой моделью пришёл.
# Своей таблицы кодов выхода не имеет -- работает до сигнала и останавливается
# им; ни один гейт кита его не зовёт.
import http.server, socketserver, sys, json, threading
PORT=9317
LOG=sys.argv[1] if len(sys.argv)>1 else "/tmp/cc_listener.log"
class H(http.server.BaseHTTPRequestHandler):
    def _h(self):
        ln=int(self.headers.get('Content-Length','0') or 0)
        body=self.rfile.read(ln) if ln else b''
        model='?'
        try: model=json.loads(body).get('model','?')
        except: pass
        with open(LOG,'a') as f:
            f.write(f"HIT {self.command} {self.path} host={self.headers.get('Host')} model={model}\n")
        self.send_response(401); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(b'{"type":"error","error":{"type":"authentication_error","message":"dummy"}}')
    def do_POST(self): self._h()
    def do_GET(self): self._h()
    def log_message(self,*a): pass
open(LOG,'w').close()
with socketserver.TCPServer(("127.0.0.1",PORT),H) as s:
    s.serve_forever()
