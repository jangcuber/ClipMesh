#!/usr/bin/env python3
"""Test actual Mac app↔Rust peer using a separate named OS pasteboard, never general clipboard."""
import asyncio, base64, binascii, hashlib, json, os, socket, struct, tempfile, uuid, zlib
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent

def png(color):
    def chunk(t,b): return struct.pack('!I',len(b))+t+b+struct.pack('!I',binascii.crc32(t+b)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',3,2,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+bytes(color)*3)*2))+chunk(b'IEND',b'')

async def main():
    core=str(ROOT/'target/release/clipmesh'); app=str(ROOT/'dist/ClipMesh.app/Contents/MacOS/ClipMesh')
    probe=str(ROOT/'.cache/macos-pasteboard-probe')
    proc=await asyncio.create_subprocess_exec('xcrun','swiftc',str(ROOT/'scripts/macos-pasteboard-probe.swift'),'-o',probe)
    if await proc.wait(): raise RuntimeError('Swift probe compilation failed')
    with tempfile.TemporaryDirectory(prefix='clipmesh-mac-image-') as tmp:
        tmp=Path(tmp); board='dev.clipmesh.validation.'+str(uuid.uuid4()); stop=tmp/'stop'
        with socket.socket() as sock: sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
        key=os.urandom(32); group={'name':'Native image validation','relay':f'ws://127.0.0.1:{port}','key':base64.b64encode(key).decode()}; gid=hashlib.sha256(key).hexdigest()
        paths=[]
        for i in range(2):
            path=tmp/f'{i}.json'; path.write_text(json.dumps({'v':1,'device':str(uuid.uuid4()),'name':'Image test','groups':[group],'active_group':gid,'paused':False})); path.chmod(0o600); paths.append(path)
        relay=await asyncio.create_subprocess_exec(core,'relay','--listen',f'127.0.0.1:{port}',stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
        peer=app_process=None
        app_log=(tmp/"app.log").open("wb")
        try:
            await asyncio.sleep(.4)
            peer=await asyncio.create_subprocess_exec(core,'run','--config',str(paths[0]),stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL,limit=25*1024*1024)
            app_process=await asyncio.create_subprocess_exec(app,'--config',str(paths[1]),'--test-pasteboard',board,'--test-stop-file',str(stop),stdout=app_log,stderr=app_log)
            async def receive(predicate):
                async def read():
                    while True:
                        line=await peer.stdout.readline()
                        if not line: raise RuntimeError('peer exited')
                        event=json.loads(line)
                        if predicate(event): return event
                return await asyncio.wait_for(read(),20)
            await receive(lambda v:v.get('connected') is True)
            for _ in range(100):
                if b'TEST receive status connected' in (tmp/'app.log').read_bytes(): break
                if app_process.returncode is not None: raise RuntimeError('Mac app exited')
                await asyncio.sleep(.2)
            else: raise RuntimeError('Mac app did not connect: '+(tmp/'app.log').read_text(errors='replace')[-2000:])
            source=tmp/'source.png'; source.write_bytes(png((230,10,100)))
            p=await asyncio.create_subprocess_exec(probe,'write',board,str(source)); assert await p.wait()==0
            ev=(await receive(lambda v:v.get('type')=='clipboard'))['event']
            assert ev['mime']=='image/png' and base64.b64decode(ev['text'])==source.read_bytes()
            data=png((10,240,60)); peer.stdin.write((json.dumps({'op':'copy_image','data':base64.b64encode(data).decode()})+'\n').encode()); await peer.stdin.drain()
            result=tmp/'result.png'
            for _ in range(60):
                p=await asyncio.create_subprocess_exec(probe,'read',board,str(result),stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
                if await p.wait()==0 and result.read_bytes()==data: break
                await asyncio.sleep(.2)
            else: raise RuntimeError('Mac did not apply remote PNG')
            print(json.dumps({'mac_app_to_peer_png':True,'peer_to_native_mac_png':True,'exact_bytes':True,'general_clipboard_modified':False}))
        except Exception:
            print((tmp/'app.log').read_text(errors='replace')[-3000:])
            raise
        finally:
            stop.touch()
            if peer:
                try: peer.stdin.write(b'{"op":"quit"}\n'); await peer.stdin.drain()
                except (BrokenPipeError,ConnectionResetError): pass
            for p in (app_process,peer,relay):
                if not p: continue
                if p is relay: p.terminate()
                try: await asyncio.wait_for(p.wait(),6)
                except asyncio.TimeoutError: p.kill(); await p.wait()
            app_log.close()

if __name__=='__main__': asyncio.run(main())
