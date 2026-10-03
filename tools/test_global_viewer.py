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
import uuid
from pathlib import Path
import websockets
ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER, TARGET = (str(Path(value).resolve()) for value in sys.argv[1:4])
root = Path(TARGET)
root.mkdir(mode=0o700)
started = threading.Event()
release = threading.Event()
current_flow = ""
call_ids = []
flow_requests = 0
class Provider(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  global flow_requests
  request = json.loads(self.rfile.read(int(self.headers['content-length'])))
  flow = current_flow
  request_index = flow_requests
  flow_requests += 1
  started.set()
  if flow in ["within-deadline", "after-deadline"]:
   time.sleep((4.2 if flow == "within-deadline" else 4.4) if request_index == 0 else .01)
  else: assert release.wait(25), 'viewer never received a frame during real HTTP wait'
  view = json.loads(request['messages'][0]['content'].split('\n\n',1)[1])
  body = json.dumps({'model':'fixture/viewer','stop_reason':'end_turn','usage':{'input_tokens':12,'output_tokens':4},'content':[{'type':'text','text':json.dumps({'note':'hold','cogs':[{'id':view['you']['id'],'intent':'screen','target':view['you']['choke_post']}]})}]}).encode()
  self.send_response(200)
  self.send_header('Content-Length',str(len(body)))
  if flow in ['within-deadline','after-deadline']:
   call_id = str(uuid.uuid4()); call_ids.append(call_id)
   self.send_header('X-Softmax-Llm-Call-Id',call_id)
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
for flow in ['mixed-no-credentials','during-http','terminal-grace','within-deadline','after-deadline']:
 current_flow = flow
 flow_requests = 0
 call_ids.clear()
 started.clear()
 release.clear()
 output=root/flow;output.mkdir(mode=0o700)
 with socket.socket() as reserve:
  reserve.bind(('127.0.0.1',0));port=reserve.getsockname()[1]
 config={'num_agents':4,'seed':7,'tokens':['t0','t1','t2','t3'],'players':[{'name':str(n)} for n in range(4)],'minPlayers':4,'maxTicks':24,'maxGames':1,'turnTicks':96,'turnBudgetMs':24000,'attempt1Ms':23000,'retryMs':1000,'startWaitTicks':0,'fastMode':True,'wallClockBudgetSeconds':90,'gameOverTicks':0}
 (output/'config.json').write_text(json.dumps(config))
 env={**os.environ,'COGAME_HOST':'127.0.0.1','COGAME_PORT':str(port),'COGAME_CONFIG_URI':(output/'config.json').as_uri(),'COGAME_RESULTS_URI':(output/'results.json').as_uri(),'COGAME_SAVE_REPLAY_URI':(output/'replay.bitreplay').as_uri()}
 if flow in ['within-deadline','after-deadline']:
  config.update(turnBudgetMs=7000,attempt1Ms=4500,retryMs=2000)
  (output/'config.json').write_text(json.dumps(config))
  env.update(COGAME_SAVE_TRAJECTORY_URI=(output/'trajectory.jsonl').as_uri(),COWORLD_EPISODE_ID=str(uuid.uuid4()),COWORLD_GAME_VERSION='fixture-package-0.1.4',COWORLD_SOURCE_REVISION=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip())
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
   if flow in ['during-http','within-deadline','after-deadline']:penv.update(COWORLD_LLM_ENDPOINT=f'http://127.0.0.1:{provider.server_port}',COWORLD_LLM_MODEL='fixture/viewer')
   binary=PLAYER
   if flow=="after-deadline" and model:
    binary=os.environ["COWORLD_TEST_MALFORMED_PLAYER"]
    penv["COWORLD_TEST_DELAY_ACTION"]="1"
   processes.append(subprocess.Popen([binary],cwd=ROOT,env=penv,stdout=log,stderr=log))
  if flow in ['during-http','within-deadline','after-deadline']:assert started.wait(15),'actual model request never reached HTTP fixture'
  elif flow=='terminal-grace':
   for n in range(400):
    if (output/'results.json').exists():break
    time.sleep(.05)
   else:raise AssertionError('engine never wrote terminal result')
  else:time.sleep(1)
  results[flow]=asyncio.run(receive(port,output));print(flow,results[flow],flush=True)
  if flow=='during-http':release.set()
  if flow in ['within-deadline','after-deadline']:
   for n in range(400):
    if (output/'trajectory.jsonl').exists():break
    time.sleep(.05)
   else:raise AssertionError('engine never wrote complete private episode')
   decisions=[json.loads(line) for line in (output/'trajectory.jsonl').read_text().splitlines() if json.loads(line)['event_type']=='decision']
   decision=next(d for d in decisions if d['seat']=='1')
   attempt=decision['attempts'][0]
   assert attempt['platform_call_id'] in call_ids
   assert attempt['raw_response'] is not None and attempt['response'] is not None
   if flow=='within-deadline':
    assert attempt['accepted'] and decision['selected_attempt_id']==attempt['attempt_id']
    assert decision['action_status']=='accepted' and attempt['parsed_action']==decision['executed_action']
    results[flow]['actual_4200ms_response_accepted']=True
   else:
    assert not attempt['accepted'] and attempt['rejection_reason']=='timeout'
    assert decision['selected_attempt_id']!=attempt['attempt_id']
    if decision['selected_attempt_id'] is not None:
     selected=next(a for a in decision['attempts'] if a['attempt_id']==decision['selected_attempt_id'])
     assert selected['accepted'] and selected['parsed_action']==decision['executed_action']
    results[flow]['actual_4500ms_deadline_retained_late_evidence']=True
 finally:
  release.set()
  for process in reversed(processes):
   if process.poll() is None:process.terminate()
   process.wait(timeout=10)
  for log in logs:log.close()
(root/'proof.json').write_text(json.dumps(results,indent=2)+'\n')
provider.shutdown()
