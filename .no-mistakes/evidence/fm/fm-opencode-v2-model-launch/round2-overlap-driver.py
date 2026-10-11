import base64,json,os,time,urllib.request,threading
from pathlib import Path
root=Path.cwd(); ev=Path('/home/pikos/.no-mistakes/evidence/01M4N4YC14417GWP7DTBWSVHTF');headers={'Authorization':'Basic '+base64.b64encode(('opencode:'+os.environ['OPENCODE_PASSWORD']).encode()).decode(),'Content-Type':'application/json'}
def call(path,body=None):
 r=urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:18765'+path,data=None if body is None else json.dumps(body).encode(),headers=headers),timeout=40);b=r.read();return json.loads(b) if b else None
frames=[]
def stream():
 try:
  with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:18765/api/event',headers=headers),timeout=40) as r:
   for line in r:
    if line.startswith(b'data:'):
     try:frames.append(json.loads(line[5:]))
     except:pass
 except Exception:pass
threading.Thread(target=stream,daemon=True).start()
def state():return (root/'.l/home/state/oc-live.busy-state').read_text().strip()
log=[]
def note(label):log.append({'label':label,'state':state(),'time':time.time()});print(log[-1],flush=True)
a=call('/api/session',{'location':{'directory':str(root/'.l/wt')},'model':{'providerID':'opencode','id':'space-bunny-free'},'title':'live overlapping parent'})['data']['id']
call('/api/session/'+a+'/prompt',{'text':'Use the shell tool to execute exactly sleep 15, then reply with exactly OVERLAP_PARENT_DONE. This is an isolated timing check. Do not run other tools.'})
time.sleep(2)
note('parent active before child');assert 'state=busy' in state()
b=call('/api/session',{'parentID':a,'model':{'providerID':'opencode','id':'exo-free'},'title':'live overlapping failing child'})['data']['id']
call('/api/session/'+b+'/prompt',{'text':'Reply with exactly CHILD_DONE.'})
call('/api/experimental/session/'+b+'/wait',{})
bi=call('/api/session/'+b)['data'];note('child settled while parent remains active');assert bi.get('outcome')=='failed',bi;assert 'state=busy' in state()
call('/api/experimental/session/'+a+'/wait',{})
for _ in range(50):
 time.sleep(.1)
 if 'state=idle' in state():break
note('both settled');assert 'state=idle' in state()
ai=call('/api/session/'+a)['data'];assert ai.get('outcome')=='succeeded',ai
for sid,label in [(a,'parent'),(b,'child')]:
 x=call('/api/experimental/session/'+sid+'/export');(ev/('round2-overlap-'+label+'.json')).write_text(json.dumps(x,indent=2))
(ev/'round2-overlap-results.json').write_text(json.dumps({'parent':a,'child':b,'states':log},indent=2))
(ev/'round2-overlap-events.json').write_text(json.dumps(frames,indent=2));print('PASS real overlapping parent plus provider-failed child',flush=True)
