import os,shutil,subprocess,json
from pathlib import Path
root=Path.cwd();evidence=Path('/home/pikos/.no-mistakes/evidence/01M69SY3M74SQMP9SDCE7XEATW');runtime=root/'.test-phase-tmp/hook-runtime'
# A disposable plain installation of the exact product, with no tool or process shims.
runtime.mkdir();
for directory in ['bin','docs']:shutil.copytree(root/directory,runtime/directory)
shutil.copy2(root/'AGENTS.md',runtime/'AGENTS.md')
subprocess.run(['git','init','-q',str(runtime)],check=True)
home=runtime/'lab';subprocess.run(['bash',str(runtime/'bin/fm-lab-home.sh'),'create',str(home)],check=True,capture_output=True)
env={k:v for k,v in os.environ.items() if not(k.startswith('FM_') or k=='NO_MISTAKES_GATE' or k.startswith('TASKS_AXI_'))};env['FM_HOME']=str(home)
log=(evidence/'session-hook-product.txt').open('w')
def run(*args):
 p=subprocess.run(['bash',str(runtime/'bin/fm-sessionstart-run.sh'),*args],env=env,cwd=runtime,text=True,capture_output=True,timeout=30)
 log.write('$ fm-sessionstart-run.sh '+' '.join(args)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]\n\n');log.flush();assert p.returncode==0
 return p.stdout
try:
 # A fresh client gets the public session-start instruction, before acquiring a lock.
 assert 'fm-session-start.sh' in run('--source','resume')
 (home/'state/.lock').write_text(str(os.getpid())+'\n')
 profile=home/'config/profile.json'
 for source,profession,name in [('resume','gunner-v1','Gunner (WSO)'),('reload','pilot-v1','Pilot (Πιλότος)'),('fork','donkey-v1','Donkey')]:
  profile.write_text(json.dumps({'schema_version':1,'profession':profession}))
  assert name in run('--source',source)
 profile.write_text('broken');assert 'PROFILE_INVALID' in run('--source','resume')
 profile.unlink();assert run('--source','resume')==''
 assert (home/'state/.lock').read_text()==str(os.getpid())+'\n'
finally:
 log.close();shutil.rmtree(runtime)
