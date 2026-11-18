#!/usr/bin/env python3
"""Run local HTTP(S) and WS(S) fixtures through the real asset runtimes."""
import argparse
from contextlib import contextmanager
import base64
import hashlib
import http.server
import json
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading

ROOT=Path(__file__).resolve().parents[2]
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*args):pass
    def cors(self):
        self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Headers","*")
        self.send_header("Cross-Origin-Resource-Policy","cross-origin")
    def do_OPTIONS(self):
        self.send_response(204);self.cors();self.send_header("Content-Length","0");self.end_headers()
    def frame(self,payload,opcode,final=True):
        first=(128 if final else 0)|opcode
        length=len(payload)
        header=bytes([first,length]) if length<126 else bytes([first,126])+struct.pack("!H",length)
        self.wfile.write(header+payload);self.wfile.flush()
    def do_GET(self):
        try:self.handle_get()
        except (BrokenPipeError,ConnectionResetError,ssl.SSLError,TimeoutError):pass
    def handle_get(self):
        self.close_connection=True
        self.connection.settimeout(5)
        path=self.path.split("?",1)[0]
        if self.headers.get("Upgrade","").lower()=="websocket":
            key=self.headers.get("Sec-WebSocket-Key","")
            accept=base64.b64encode(hashlib.sha1((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101);self.send_header("Upgrade","websocket");self.send_header("Connection","Upgrade");self.send_header("Sec-WebSocket-Accept",accept)
            if "asset.v1" in self.headers.get("Sec-WebSocket-Protocol",""):self.send_header("Sec-WebSocket-Protocol","asset.v1")
            self.end_headers();self.wfile.flush()
            if path=="/idle":
                self.frame(b"welcome",1);self.connection.recv(2048);return
            if path=="/queued-error":
                self.frame(b'{"seq":7}',1);self.frame(bytes(2048),2);return
            if path=="/oversize":self.frame(bytes(2048),2);return
            if path=="/json":
                self.frame(b'{"seq":1}',1);self.frame(b'{"seq":2}',2)
            else:
                self.frame(b"hel",1,False);self.frame(b"lo",0)
                self.frame(bytes([0,1,255]),2);self.frame(b"",2);self.frame(b"",1)
            self.frame(struct.pack("!H",1000),8)
            try:self.connection.recv(2048)
            except (TimeoutError,ConnectionResetError):pass
            return
        if path=="/snapshot":body=b'{"revision":23}';status=200
        elif path=="/chunks":body=bytes(range(32));status=200
        else:body=b"missing";status=404
        self.send_response(status);self.cors();self.send_header("Content-Type","application/octet-stream");self.send_header("Content-Length",str(len(body)));self.end_headers();self.wfile.write(body)

def execute(args,timeout=120,**kw):subprocess.run([str(v) for v in args],check=True,timeout=timeout,**kw)
@contextmanager
def fixture():
    (ROOT/"target").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="asset-remote-",dir=ROOT/"target") as work:
        work=Path(work)
        with (work/"openssl.log").open("w") as log:
            execute(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-sha256","-days","2","-subj","/CN=hxn-assets-test-ca","-keyout",work/"ca.key","-out",work/"ca.pem"],stdout=log,stderr=log)
            execute(["openssl","req","-new","-newkey","rsa:2048","-nodes","-subj","/CN=localhost","-keyout",work/"server.key","-out",work/"server.csr"],stdout=log,stderr=log)
            (work/"extensions").write_text("basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n")
            execute(["openssl","x509","-req","-in",work/"server.csr","-CA",work/"ca.pem","-CAkey",work/"ca.key","-CAcreateserial","-days","2","-sha256","-extfile",work/"extensions","-out",work/"server.pem"],stdout=log,stderr=log)
        servers=[];threads=[]
        for secure in (False,True):
            server=http.server.ThreadingHTTPServer(("127.0.0.1",0),Handler);server.daemon_threads=True
            if secure:
                context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(work/"server.pem",work/"server.key");server.socket=context.wrap_socket(server.socket,server_side=True)
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();servers.append(server);threads.append(thread)
        plain,secure=[server.server_address[1] for server in servers]
        def literal(value):return json.dumps(value)
        (work/"RemoteConfig.hx").write_text('class RemoteConfig { public static final ca='+literal((work/"ca.pem").read_text())+';'+''.join('public static final '+name+'='+literal(uri)+';' for name,uri in {
            'idle':f'ws://localhost:{plain}/idle','oversize':f'ws://localhost:{plain}/oversize','missing':f'http://localhost:{plain}/missing','secure':f'https://localhost:{secure}/snapshot'}.items())+'}')
        fields=[('Snapshot',f'https://localhost:{secure}/snapshot','{revision:Int}'),('QueuedMessages',f'ws://localhost:{plain}/queued-error','hxn.assets.AssetStream<{seq:Int}>'),('Messages',f'ws://localhost:{plain}/messages','hxn.assets.AssetStream<haxe.io.Bytes>'),('TypedMessages',f'ws://localhost:{plain}/json','hxn.assets.AssetStream<{seq:Int}>'),('SecureMessages',f'wss://localhost:{secure}/json','hxn.assets.AssetStream<{seq:Int}>'),('Chunks',f'https://localhost:{secure}/chunks','hxn.assets.AssetStream<haxe.io.Bytes>')]
        (work/"RemoteAssets.hx").write_text('@:build(hxn.assets.Assets.build()) class RemoteAssets {'+''.join('@:asset('+literal(uri)+') @:dynamicAsset public static var '+name+':'+type+';' for name,uri,type in fields)+'}')
        try:
            yield work, (plain, secure)
        finally:
            for server in servers:server.shutdown();server.server_close()
            for thread in threads:thread.join(timeout=5)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("modes",nargs="+")
    parser.add_argument("--ash",default="ash")
    parser.add_argument("--cli",type=Path)
    parser.add_argument("--hxn",type=Path,default=ROOT.parent/"hxn")
    parser.add_argument("--chrome")
    options=parser.parse_args()
    with fixture() as (work, ports):
        # This browser trust flag applies only to the temporary fixture CA.
        execute([sys.executable,ROOT/"tests/assets/runtimes.py",*options.modes,"--hxn",options.hxn,"--ash",options.ash,*(["--cli",options.cli] if options.cli else []),*(["--chrome",options.chrome] if options.chrome else []),"--main","RemoteCheck","--class-path",work,"--expect","PASS: remote URI","--browser-arg=--ignore-certificate-errors"],timeout=1200)
if __name__=="__main__":main()
