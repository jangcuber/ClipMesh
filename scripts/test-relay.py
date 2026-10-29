#!/usr/bin/env python3
"""Exercise encrypted two-way text and PNG images through a reachable ws/wss relay; no OS clipboard access."""
import argparse, asyncio, base64, binascii, hashlib, json, os, struct, tempfile, time, uuid, zlib
from pathlib import Path

async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--relay', required=True)
    parser.add_argument('--core', default='target/release/clipmesh')
    parser.add_argument('--large-image', action='store_true', help='also verify a real ~5.5MiB PNG through the enlarged frame limit')
    args = parser.parse_args()
    key = os.urandom(32)
    group = {'name':'Relay connectivity test','relay':args.relay,'key':base64.b64encode(key).decode()}
    gid = hashlib.sha256(key).hexdigest()
    processes = []
    async def receive(process, kind, expected=None):
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            line = await asyncio.wait_for(process.stdout.readline(), max(.1, deadline-time.monotonic()))
            if not line:
                raise RuntimeError('Sync core exited before relay exchange completed')
            obj = json.loads(line)
            if obj.get('type') == kind and (expected is None or expected(obj)):
                return obj
        raise TimeoutError('Relay exchange timed out')
    async def send(p, obj):
        p.stdin.write((json.dumps(obj, ensure_ascii=False)+'\n').encode())
        await p.stdin.drain()
    try:
        with tempfile.TemporaryDirectory(prefix='clipmesh-relay-test-') as tmp:
            for index in range(2):
                config = {'v':1,'device':str(uuid.uuid4()),'name':f'Relay test {index}',
                          'groups':[group],'active_group':gid,'paused':False}
                path = Path(tmp)/f'client{index}.json'
                path.write_text(json.dumps(config)); path.chmod(0o600)
                process = await asyncio.create_subprocess_exec(args.core,'run','--config',str(path),
                        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, limit=26*1024*1024)
                processes.append(process)
            await asyncio.gather(*(receive(p,'status',lambda o:o.get('connected') is True) for p in processes))
            for sender,receiver,text in [(processes[0],processes[1],'CLIPMESH-WSS-A-'+str(uuid.uuid4())),
                                         (processes[1],processes[0],'CLIPMESH-WSS-B-한글😀\n'+str(uuid.uuid4()))]:
                await send(sender,{'op':'copy','text':text})
                event = await receive(receiver,'clipboard')
                if event.get('event',{}).get('text') != text:
                    raise RuntimeError('Relay delivered unexpected text')
            png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMwbPr2HwAFOgKpyNxwqgAAAABJRU5ErkJggg==')
            for sender, receiver in [(processes[0], processes[1]), (processes[1], processes[0])]:
                await send(sender, {'op':'copy_image','data':base64.b64encode(png).decode()})
                event = (await receive(receiver, 'clipboard'))['event']
                if event.get('mime') != 'image/png' or base64.b64decode(event.get('text','')) != png:
                    raise RuntimeError('Relay delivered unexpected image')
            large_image_bytes = 0
            if args.large_image:
                def chunk(t, b): return struct.pack('!I',len(b))+t+b+struct.pack('!I',binascii.crc32(t+b)&0xffffffff)
                width, height = 1400, 1300
                rows = b''.join(b'\0'+os.urandom(width*3) for _ in range(height))
                large = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')
                await send(processes[0], {'op':'copy_image','data':base64.b64encode(large).decode()})
                event = (await receive(processes[1], 'clipboard'))['event']
                if event.get('mime') != 'image/png' or base64.b64decode(event.get('text','')) != large:
                    raise RuntimeError('Large PNG was not received intact')
                large_image_bytes = len(large)
            print(json.dumps({'relay':args.relay,'connected_clients':2,'bidirectional_text':True,
                              'unicode':True,'bidirectional_png':True,'large_png_bytes':large_image_bytes,'os_clipboards_modified':False},ensure_ascii=False))
    finally:
        for p in processes:
            if p.returncode is None:
                try: await send(p,{'op':'quit'})
                except (BrokenPipeError,ConnectionResetError): pass
        for p in processes:
            try: await asyncio.wait_for(p.wait(),5)
            except asyncio.TimeoutError: p.kill(); await p.wait()

if __name__ == '__main__':
    asyncio.run(main())
