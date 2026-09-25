const fs=require('fs');
const [,,script,image,...muts]=process.argv;
let src=fs.readFileSync(script,'utf8');
if(src.split('const STEPS_OFF = [];').length!==2){console.log('STEPS_OFF_ANCHOR_BAD');process.exit(9);}
src=src.replace('const STEPS_OFF = [];', "const STEPS_OFF = ['7 session memory','26 dispatch-cancellation rule in the system prompt','28 refusal fallback routes from config, top of lineup reachable'];");
for (const m of muts){ const [a,b]=JSON.parse(fs.readFileSync(m,'utf8')); if(src.split(a).length!==2){console.log('MUT_ANCHOR_BAD',m);process.exit(9);} src=src.replace(a,()=>b); }
let js=fs.readFileSync(image).toString('latin1')+(process.env.APPEND||'');
if (process.env.MARKERS === '1') {
  let seen = 0;
  js = js.replace(/\/\/ @bun @bytecode/g, (hit) => {
    seen++;
    if (seen === 1) return hit;
    return '\n/*__tweakcc_module_boundary_' + (seen - 1) + '__*/\n' + hit;
  });
  const inserted = seen > 0 ? seen - 1 : 0;
  if (inserted === 0) {
    console.log('RESULT throw\nno module headers');
    process.exit(3);
  }
  console.log('MARKERS ' + inserted);
}
const origErr=console.error; let log=''; console.error=(...a)=>{log+=a.join(' ')+'\n'};
try { const out=new Function('js',src)(js); console.log('RESULT ok +'+(out.length-js.length)); console.log(log.split('\n').filter(l=>/^\s+- (routing|proxy lane|a broken stream)/.test(l)).join('\n'));
  fs.writeFileSync(process.env.OUT||'/dev/null', out, 'latin1'); }
catch(e){ console.log('RESULT throw\n'+String(e.message).split('\n').filter(l=>/^\s+- (1 |11 |19 )|patches could not/.test(l)).join('\n')); process.exitCode=3; }
