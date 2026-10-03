"""Real public frames at model/lifecycle boundaries; local HTTP fixture only."""
import asyncio
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
import websockets
ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER, TARGET = (str(Path(value).resolve()) for value in sys.argv[1:4])
root = Path(TARGET)
root.mkdir(mode=0o700)
started = threading.Event()
release = threading.Event()
class Provider(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  request = json.loads(self.rfile.read(int(self.headers['content-length'])))
  started.set()
  assert release.wait(25), 'viewer never received a frame during real HTTP wait'
  view = json.loads(request['messages'][0]['content'].split('\n\n',1)[1])
  body = json.dumps({'model':'fixture/viewer','content':[{'type':'text','text':json.dumps({'note':'hold','cogs':[{'id':view['you']['id'],'intent':'screen','target':view['you']['choke_post']}]})}]}).encode()
  self.send_response(200)
  self.send_header('Content-Length',str(len(body)))
  self.end_headers()
  self.wfile.write(body)
 def log_message(self,*args): pass
provider = http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider)
threading.Thread(target=provider.serve_forever,daemon=True).start()
async def receive(port,output):
 begin = time.monotonic()
 async with websockets.connect(f'ws://127.0.0.1:{port}/global',max_size=None) as viewer:
  await asyncio.wait_for(await viewer.ping(),2)
  frame = await asyncio.wait_for(viewer.recv(),5)
  assert isinstance(frame,bytes) and len(frame)>1000
  (output/'global-frame.bin').write_bytes(frame)
  return {'bytes':len(frame),'elapsed_seconds':time.monotonic()-begin}
results={}
for flow in ['mixed-no-credentials','during-http','terminal-grace']:
 output=root/flow;output.mkdir(mode=0o700)
 with socket.socket() as reserve:
  reserve.bind(('127.0.0.1',0));port=reserve.getsockname()[1]
 config={'num_agents':4,'seed':7,'tokens':['t0','t1','t2','t3'],'players':[{'name':str(n)} for n in range(4)],'minPlayers':4,'maxTicks':24,'maxGames':1,'turnTicks':96,'turnBudgetMs':24000,'attempt1Ms':23000,'retryMs':1000,'startWaitTicks':0,'fastMode':True,'wallClockBudgetSeconds':90,'gameOverTicks':0}
 (output/'config.json').write_text(json.dumps(config))
 env={**os.environ,'COGAME_HOST':'127.0.0.1','COGAME_PORT':str(port),'COGAME_CONFIG_URI':(output/'config.json').as_uri(),'COGAME_RESULTS_URI':(output/'results.json').as_uri(),'COGAME_SAVE_REPLAY_URI':(output/'replay.bitreplay').as_uri()}
 processes=[];logs=[]
 try:
  log=(output/'game.log').open('w');logs.append(log)
  processes.append(subprocess.Popen([GAME],cwd=ROOT,env=env,stdout=log,stderr=log))
  for n in range(150):
   with socket.socket() as check:
    if check.connect_ex(('127.0.0.1',port))==0:break
   time.sleep(.05)
  else:raise AssertionError('listener unavailable')
  for slot in range(4):
   log=(output/f'player{slot}.log').open('w');logs.append(log)
   model=slot==1 and flow!='terminal-grace'
   penv={**env,'COWORLD_PLAYER_WS_URL':f'ws://127.0.0.1:{port}/player?slot={slot}&token=t{slot}','PLAYER_SCRIPTED':'' if model else 'phalanx','PLAYER_PROMPT':'boundary fixture' if model else ''}
   if flow=='during-http':penv.update(COWORLD_LLM_ENDPOINT=f'http://127.0.0.1:{provider.server_port}',COWORLD_LLM_MODEL='fixture/viewer')
   processes.append(subprocess.Popen([PLAYER],cwd=ROOT,env=penv,stdout=log,stderr=log))
  if flow=='during-http':assert started.wait(15),'actual model request never reached HTTP fixture'
  elif flow=='terminal-grace':
   for n in range(400):
    if (output/'results.json').exists():break
    time.sleep(.05)
   else:raise AssertionError('engine never wrote terminal result')
  else:time.sleep(1)
  results[flow]=asyncio.run(receive(port,output));print(flow,results[flow],flush=True)
  if flow=='during-http':release.set()
 finally:
  release.set()
  for process in reversed(processes):
   if process.poll() is None:process.terminate()
   process.wait(timeout=10)
  for log in logs:log.close()
(root/'proof.json').write_text(json.dumps(results,indent=2)+'\n')
provider.shutdown()
