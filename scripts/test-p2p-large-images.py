#!/usr/bin/env python3
"""Exercise simultaneous large-image replay using two real QUIC hosts."""
import asyncio, base64, binascii, json, os, socket, struct, tempfile, uuid, zlib
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent

async def main():
    core = os.environ.get('CLIPMESH_TEST_CORE', str(ROOT/'target/release/clipmesh'))
    peer_core = os.environ.get('CLIPMESH_TEST_PEER_CORE', core)
    def chunk(t, b):
        return struct.pack('!I', len(b))+t+b+struct.pack('!I', binascii.crc32(t+b)&0xffffffff)
    raw = b''.join(b'\0'+os.urandom(1536*3) for _ in range(1024))
    image = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',1536,1024,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
    command = (json.dumps({'op':'copy_image','data':base64.b64encode(image).decode()})+'\n').encode()
    with tempfile.TemporaryDirectory(prefix='clipmesh-duplex-') as tmp:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
        group={'name':'Duplex test','relay':f'ws://127.0.0.1:{port}','key':base64.b64encode(os.urandom(32)).decode(),'transport':'p2p'}
        processes=[]; readers=[]; queue=asyncio.Queue(); relay=None
        async def pump(index, process):
            while line:=await process.stdout.readline():
                item=json.loads(line)
                if item.get('type')=='clipboard':
                    event=item['event']
                    item={'type':'clipboard','mime':event['mime'],'tag':event['text'] if event['mime']=='text/plain' else None}
                await queue.put((index,item))
        async def until(predicate):
            async def read():
                while True:
                    index,item=await queue.get()
                    if item.get('type')=='error': raise RuntimeError(item.get('message'))
                    if predicate(index,item): return
            await asyncio.wait_for(read(),18)
        try:
            import hashlib
            for i in range(2):
                path=Path(tmp)/f'{i}.json'
                path.write_text(json.dumps({'v':1,'device':str(uuid.uuid4()),'name':f'Duplex {i}','groups':[group],'active_group':hashlib.sha256(base64.b64decode(group['key'])).hexdigest(),'paused':False}))
                path.chmod(0o600)
                process=await asyncio.create_subprocess_exec(core if i==0 else peer_core,'run','--config',str(path),stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL,limit=25*1024*1024)
                processes.append(process); readers.append(asyncio.create_task(pump(i,process)))
                process.stdin.write(command); await process.stdin.drain()
                await until(lambda n,v:n==i and v.get('type')=='copied')
            print('Both hosts queued large images before connection',flush=True)
            # Both hosts already have a large clipboard when discovery starts.
            relay=await asyncio.create_subprocess_exec(core,'relay','--listen',f'127.0.0.1:{port}',stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
            await until(lambda n,v:v.get('type')=='clipboard' and v.get('mime')=='image/png')
            for sender in range(2):
                tag=f'duplex-recovered-{sender}'
                processes[sender].stdin.write((json.dumps({'op':'copy','text':tag})+'\n').encode()); await processes[sender].stdin.drain()
                await until(lambda n,v:n!=sender and v.get('type')=='clipboard' and v.get('tag')==tag)
            print(json.dumps({'simultaneous_large_image_replay':True,'image_bytes':len(image),'subsequent_bidirectional_text':True}))
        finally:
            for reader in readers: reader.cancel()
            await asyncio.gather(*readers,return_exceptions=True)
            for process in processes+([relay] if relay else []):
                if process.returncode is None:
                    process.terminate()
                    try: await asyncio.wait_for(process.wait(),4)
                    except asyncio.TimeoutError: process.kill(); await process.wait()

if __name__=='__main__': asyncio.run(main())
