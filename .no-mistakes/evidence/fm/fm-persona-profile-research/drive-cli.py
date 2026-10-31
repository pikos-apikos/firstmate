import os,json,subprocess,shutil,hashlib
from pathlib import Path
root=Path.cwd(); evidence=Path('/home/pikos/.no-mistakes/evidence/01M69SY3M74SQMP9SDCE7XEATW'); lab=root/'.test-phase-tmp/live-home'
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('TASKS_AXI_'))};env['FM_HOME']=str(lab)
log=(evidence/'product-cli-transcript.txt').open('w')
def run(script,*args,ok=True,extra=None):
 cmd=['bash',str(root/'bin'/script),*map(str,args)]
 p=subprocess.run(cmd,env=dict(env,**(extra or {})),capture_output=True,text=True,timeout=60)
 log.write('$ '+script+' '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]\n\n');log.flush()
 assert (p.returncode==0)==ok,(script,args,p.returncode,p.stdout[-2000:],p.stderr[-2000:])
 return p.stdout
try:
 config=lab/'config/profile.json';config.write_text(json.dumps({'schema_version':1,'profession':'gunner-v1','theme':'space-fleet'}))
 assert json.loads(run('fm-profile.sh','inspect','--json'))['chat']['user_address']=='pilot'
 run('fm-profile.sh','refresh')
 for pair in ['space-fleet/pilot-gunner','space-fleet/captain-pilot','farm/farmer-donkey','fantasy/wizard-familiar','kitchen/chef-sous-chef']:
  assert json.loads(run('fm-profile.sh','inspect','--preset',pair,'--json'))['pair']==pair
 config.write_text('broken');run('fm-profile.sh','refresh',ok=False)
 assert 'worker launch contract' in run('fm-profile.sh','refresh',extra={'FM_TASK_ID':'test-worker'})
 run('fm-profile.sh','inspect','--preset','../../unsafe',ok=False)
 config.write_text(json.dumps({'schema_version':1,'profession':'pilot-v1','theme':'space-fleet'}))
 assert 'Pilot (Πιλότος)' in run('fm-profile.sh','context')
 project=lab/'projects/alpha';project.mkdir();subprocess.run(['git','init','-q',str(project)],check=True)
 (lab/'data/projects.md').write_text('- alpha [local-only] - Alpha (added 2026-10-31)\n- beta [local-only] - Beta (added 2026-10-31)\n')
 run('fm-entry.sh','inspect',project)
 for _ in range(2):run('fm-entry.sh','send',project,'--request-id','live-entry-request','--','Plan the next bounded unit.')
 assert run('fm-inbox.sh','receipts','--all-pending').count('Plan the next bounded unit.')==1
 assert not (lab/'state/.lock').exists()
 source=lab/'approved.md';source.write_bytes(b'# Evidence\r\nApproved exact snapshot.\r\n')
 cfg=lab/'config/project-brains/alpha.json';cfg.parent.mkdir();cfg.write_text(json.dumps({'schema_version':1,'sources':[{'id':'approved','path':str(source)}]}))
 summary=lab/'summary.json';summary.write_text(json.dumps({'title':'Completed profile unit','body':'Observed disk-owned roles.','sources':['approved'],'connections':[]}))
 generation=Path(json.loads(run('fm-brain.sh','complete','alpha','--unit','profile-unit','--summary',summary))['generation'])
 run('fm-brain.sh','check','alpha');run('fm-brain.sh','query','alpha','profile')
 assert (lab/'data/brains/alpha/raw'/f'{hashlib.sha256(source.read_bytes()).hexdigest()}.md').read_bytes()==source.read_bytes()
 for file in ['index.md','pages/units/profile-unit.md','graphify-out/graph.json']:shutil.copy2(generation/file,evidence/Path(file).name)
 prior=(lab/'data/brains/alpha/CURRENT').read_text()
 summary.write_text(json.dumps({'title':'Invalid connection','body':'Intentional failure.','sources':['approved'],'connections':['units/missing']}))
 run('fm-brain.sh','complete','alpha','--unit','bad-unit','--summary',summary,ok=False)
 assert (lab/'data/brains/alpha/CURRENT').read_text()==prior
 run('fm-brain.sh','status','alpha')
 source.write_text('# Changed evidence\nNew observation.\n');run('fm-brain.sh','check','alpha',ok=False);run('fm-brain.sh','build','alpha');run('fm-brain.sh','check','alpha')
 assert not (lab/'data/brains/beta').exists()
 # Directly drive teardown's completion safeguard using an isolated, windowless legacy task.
 (lab/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
 for verb,args in [('add',['task-live','Live teardown fixture','--kind','ship']),('start',['task-live'])]:
  p=subprocess.run(['tasks-axi',verb,*args,'--file',str(lab/'data/backlog.md')],env=env,cwd=lab,capture_output=True,text=True);assert p.returncode==0,(p.stdout,p.stderr)
 (lab/'state/task-live.meta').write_text(f'worktree={lab}/gone-worktree\nproject={project}\nkind=ship\nmode=local-only\n')
 cfg.write_text('broken')
 failure=run('fm-teardown.sh','task-live',ok=False)
 assert (lab/'state/task-live.meta').exists()
 assert 'project brain completion failed' in (evidence/'product-cli-transcript.txt').read_text()
 cfg.write_text(json.dumps({'schema_version':1,'sources':[{'id':'approved','path':str(source)}]}))
 run('fm-teardown.sh','task-live')
 assert not (lab/'state/task-live.meta').exists()
 run('fm-brain.sh','query','alpha','Completed work: task-live')
finally:
 log.close();shutil.rmtree(lab)
