// The SD card manager page served by web.cpp. Written with an AI assistant.
namespace web {
extern const char PAGE[] = R"HTML(<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LisaNet</title>
<style>
:root{--bg:#f4f1ea;--fg:#1d1b18;--mut:#6b665d;--line:#d8d2c4;--acc:#2f5d8a;--bad:#a33;--card:#fffdf8}
@media (prefers-color-scheme:dark){:root{--bg:#181715;--fg:#ece8df;--mut:#9a9488;--line:#34312c;--acc:#7fa9d6;--bad:#e07b7b;--card:#211f1c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 system-ui,sans-serif}
main{max-width:900px;margin:0 auto;padding:16px}h1{font-size:20px;margin:0 0 4px}
.mut{color:var(--mut);font-size:13px}.bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:12px 0}
button,.btn{font:inherit;padding:5px 10px;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:6px;cursor:pointer;text-decoration:none}
button:hover,.btn:hover{border-color:var(--acc)}button.danger{color:var(--bad)}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden}
td,th{padding:7px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:middle}th{font-size:12px;color:var(--mut);font-weight:600}
td.s{text-align:right;white-space:nowrap;color:var(--mut)}td.a{white-space:nowrap;text-align:right}td.a button,td.a .btn{padding:2px 7px;font-size:13px}
a.dir{color:var(--acc);text-decoration:none;font-weight:600}.crumb a{color:var(--acc);text-decoration:none}
#msg{padding:8px 12px;border-radius:6px;margin:10px 0;display:none}#msg.err{display:block;background:color-mix(in srgb,var(--bad) 15%,transparent);color:var(--bad)}
#msg.ok{display:block;background:color-mix(in srgb,var(--acc) 15%,transparent)}
th.c,td.c{width:28px;padding-right:0}button:disabled{opacity:.45;cursor:default}button:disabled:hover{border-color:var(--line)}
.sp{display:flex;align-items:center;gap:6px}button.mini{padding:0 6px;font-size:14px;line-height:20px}
dialog{background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:8px;max-width:440px}
dialog::backdrop{background:rgba(0,0,0,.35)}dialog input{font:inherit;padding:3px 6px;max-width:100%}
progress{width:200px}.mn{font-size:11px;color:var(--acc);border:1px solid var(--acc);border-radius:4px;padding:0 4px;margin-left:6px}
@media (max-width:600px){td.c{padding-left:6px}td.s{display:none}td.a button,td.a .btn{padding:2px 5px}}
.tabs{display:flex;gap:4px;border-bottom:1px solid var(--line);margin:10px 0 4px}.tabs button{border:none;border-bottom:2px solid transparent;border-radius:0;background:none;padding:6px 12px}
.tabs button.on{border-bottom-color:var(--acc);color:var(--acc);font-weight:600}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;margin:10px 0}.card h3{margin:0 0 8px;font-size:15px}
.row{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:8px 0}.row label.k{min-width:110px;color:var(--mut)}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:6px;overflow:hidden}.seg button{border:none;border-radius:0;border-right:1px solid var(--line)}
.seg button:last-child{border-right:none}.seg button.on{background:var(--acc);color:#fff}
select,input[type=number]{font:inherit;padding:4px 6px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)}
input[type=number]{width:80px}.warn{color:var(--bad);font-weight:600}
</style></head><body><main>
<h1>LisaNet <span class="mut" id="who"></span></h1>
<nav class="tabs"><button id="tabS" class="on">Settings</button><button id="tabF">Files</button></nav>
<div id="msg"></div>
<section id="tFiles" hidden>
<div class="mut sp"><span id="info">Card space</span> <button id="infob" class="mini" title="Recalculate card space">&#x21bb;</button></div>
<div class="bar" id="nosd" hidden><span class="mut">Switch the board to:</span><button data-esp="1">Manage ESFloppy's card (WIFI FDD)</button><button data-esp="2">Manage ESProFile's card (WIFI HDD)</button></div>
<div class="bar"><span class="crumb" id="crumb"></span></div>
<div class="bar">
<label class="btn">Upload<input type="file" id="file" multiple hidden></label>
<button id="mkdir">New folder</button><button id="move" disabled>Move selected...</button><button id="refresh">Refresh</button>
<progress id="prog" max="1" value="0" hidden></progress><span class="mut" id="progt"></span>
</div>
<div class="mut" id="mnext"></div>
<dialog id="pdlg"><p><b>profile.image already exists.</b> ESProFile boots from it, so it has to make way for
<span id="psrc"></span>.</p>
<p><label>Keep it, renamed to <input id="pname" size="26"></label></p>
<div class="bar"><button id="pkeep">Rename it and copy</button><button id="pdisc" class="danger">Discard it and copy</button>
<button id="pcancel">Cancel</button></div></dialog>
<table><thead><tr><th class="c"><input type="checkbox" id="all" title="Select all"></th><th>Name</th><th class="s">Size</th><th></th></tr></thead><tbody id="list"></tbody></table>
<p class="mut" id="mnhelp">Disk images (.dc42, .image, .img) must be stored contiguously; uploads here always are. "Mount next" makes
ESFloppy insert that image in drive 1 every time it starts in FLOPPY mode, until cleared.</p>
</section>
<section id="tSet">
<div class="card"><h3>Lisa</h3>
<div class="row"><label class="k">Power</label><span id="sLisa">-</span></div>
<div class="row"><label class="k">FPGA die</label><span id="sTemp">-</span></div>
<div class="row"><button id="bPower">Press power button</button><button id="bReset" class="danger">Reset</button></div></div>
<div class="card"><h3>ESP32 mode</h3>
<div class="row"><div class="seg" id="sEsp"><button data-v="0">NORMAL</button><button data-v="1">WIFI FDD</button><button data-v="2">WIFI HDD</button></div></div>
<div class="mut" id="sEspNote">NORMAL: both drives are drives. WIFI FDD / WIFI HDD: that drive's SD card is managed from the Files tab instead,
and that drive is offline meanwhile. It can only change while the Lisa is off.</div></div>
<div class="card"><h3>Display</h3>
<div class="row"><label class="k" for="sRes">Resolution</label><select id="sRes"><option value="0">1080p30</option><option value="1">1080p60</option><option value="2">1024x768</option></select></div>
<div class="row"><label class="k">Horizontal</label><button data-ax="2" data-d="-8">&laquo;</button><button data-ax="2" data-d="-1">&lsaquo;</button>
<input type="number" id="sH" min="0"><button data-ax="2" data-d="1">&rsaquo;</button><button data-ax="2" data-d="8">&raquo;</button><span class="mut" id="sHl"></span></div>
<div class="row"><label class="k">Vertical</label><button data-ax="3" data-d="-8">&laquo;</button><button data-ax="3" data-d="-1">&lsaquo;</button>
<input type="number" id="sV" min="0"><button data-ax="3" data-d="1">&rsaquo;</button><button data-ax="3" data-d="8">&raquo;</button><span class="mut" id="sVl"></span></div>
<div class="row"><label class="k" for="sCon">Max contrast</label><input type="checkbox" id="sCon"><span class="mut" id="sConJ"></span></div></div>
<div class="card"><h3>CPU speed</h3>
<div class="row"><select id="sSpd"><option value="0">Follow the SPEED switches</option><option value="1">5 MHz</option><option value="2">10 MHz</option>
<option value="3">15 MHz</option><option value="4">18.75 MHz</option></select></div></div>
<div class="bar"><button id="bSave">Save settings</button><span class="mut" id="sSaved"></span></div>
<p class="mut">Changes apply at once, as in the on-screen menu, and are kept across a power cycle only after Save settings.</p>
<div class="card"><h3>WiFi board firmware</h3>
<div class="row"><label class="k">Running</label><span id="fwRun">-</span></div>
<div class="row"><label class="btn">Install update...<input type="file" id="fwFile" accept=".bin" hidden></label>
<button id="fwBack" hidden></button><progress id="fwProg" max="1" value="0" hidden></progress><span class="mut" id="fwT"></span></div>
<p class="mut">Choose <b>lisanet_wifi.ino.bin</b> from the firmware's build folder (not the .merged.bin). The board restarts into it.
A new version has to run for 20 s before it is kept: if it crashes sooner, the board goes back to this one by itself.</p></div>
</section>
<dialog id="rdlg"><p><b>Keep this resolution?</b></p><p class="mut">If the display went blank, do nothing: it goes back in <span id="rsec">15</span> s.</p>
<div class="bar"><button id="rkeep">Keep</button><button id="rrevert">Go back now</button></div></dialog>
</main><script>
let cwd='/',mountNext='',names=new Set(),profile=false;
const $=id=>document.getElementById(id);
const join=(d,n)=>(d.endsWith('/')?d:d+'/')+n;
const isImg=n=>/\.(dc42|image|img)$/i.test(n);
function msg(t,bad){const m=$('msg');m.textContent=t;m.className=t?(bad?'err':'ok'):'';}
async function api(url,opt){const r=await fetch(url,opt);let j={};try{j=await r.json()}catch(e){}
 if(!r.ok)throw new Error(r.status==503?'No SD card server is reachable: switch the board to WIFI FDD or WIFI HDD, below or on the Settings tab.':(j.error||('HTTP '+r.status)));return j;}
function size(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';if(b<1073741824)return (b/1048576).toFixed(1)+' MB';return (b/1073741824).toFixed(2)+' GB';}
function crumbs(){const c=$('crumb');c.innerHTML='';const parts=cwd.split('/').filter(Boolean);
 const add=(t,p)=>{const a=document.createElement('a');a.href='#';a.textContent=t;a.onclick=e=>{e.preventDefault();go(p)};c.append(a)};
 add('SD card','/');let p='';for(const x of parts){p+='/'+x;c.append(' / ');add(x,p);}}
function selected(){return [...document.querySelectorAll('input.sel:checked')].map(c=>c.dataset.n);}
function selChanged(){const n=selected().length;$('move').disabled=!n;$('move').textContent=n?'Move '+n+' selected...':'Move selected...';}
async function load(){msg('');crumbs();const tb=$('list');tb.innerHTML='<tr><td colspan=4 class=mut>Loading...</td></tr>';$('all').checked=false;
 try{const [h,l,m]=await Promise.all([api('/api/hello'),api('/api/ls?path='+encodeURIComponent(cwd)),api('/api/mountnext')]);mountNext=m.path||'';
  profile=/ESProFile/i.test(h.fw);$('who').textContent=profile?'- ESProFile hard disk card':'- ESFloppy floppy card';
  $('mnhelp').hidden=profile;
  $('mnext').textContent=mountNext?'Mount next: '+mountNext:'';names=new Set(l.entries.map(e=>e.n));
  const es=l.entries.filter(e=>!e.n.startsWith('._')).sort((a,b)=>(b.d-a.d)||a.n.localeCompare(b.n));tb.innerHTML='';
  if(cwd!=='/')es.unshift({n:'..',d:1,up:1});
  for(const e of es){const tr=document.createElement('tr'),p=e.up?cwd.replace(/\/[^/]*$/,'')||'/':join(cwd,e.n);
   const tc=document.createElement('td');tc.className='c';
   if(!e.up){const c=document.createElement('input');c.type='checkbox';c.className='sel';c.dataset.n=e.n;c.onchange=selChanged;tc.append(c);}
   tr.append(tc);
   const td=document.createElement('td');
   if(e.d){const a=document.createElement('a');a.href='#';a.className='dir';a.textContent=e.n+(e.up?'':'/');a.onclick=ev=>{ev.preventDefault();go(p)};td.append(a)}
   else{td.textContent=e.n;if(p===mountNext){const s=document.createElement('span');s.className='mn';s.textContent='mount next';td.append(s)}}
   const ts=document.createElement('td');ts.className='s';ts.textContent=e.d?'':size(e.s);
   const ta=document.createElement('td');ta.className='a';
   if(!e.up){
    if(!e.d){const d=document.createElement('a');d.className='btn';d.textContent='Download';d.href='/api/get?path='+encodeURIComponent(p);ta.append(d,' ');}
    if(!e.d&&!profile&&isImg(e.n)){const b=document.createElement('button');b.textContent=p===mountNext?'Clear mount':'Mount next';
     b.onclick=()=>act('/api/mountnext?path='+encodeURIComponent(p===mountNext?'':p));ta.append(b,' ');}
    if(!e.d&&profile&&/\.(image|img)$/i.test(e.n)&&p!==PROFILE){const b=document.createElement('button');b.textContent='Copy to profile.image';
     b.title='ESProFile boots from /profile.image. This copies '+e.n+' there and leaves the original in place.';
     b.onclick=()=>copyToProfile(p);ta.append(b,' ');}
    const r=document.createElement('button');r.textContent='Rename';r.onclick=async()=>{const n=prompt('New name',e.n);if(!n||n===e.n)return;const to=join(cwd,n);
     try{await api('/api/mv?from='+encodeURIComponent(p)+'&to='+encodeURIComponent(to),{method:'POST'});
      if(p===mountNext)await api('/api/mountnext?path='+encodeURIComponent(to),{method:'POST'});load();}catch(err){msg(err.message,1);}};
    const x=document.createElement('button');x.textContent='Delete';x.className='danger';x.onclick=()=>{if(confirm('Delete '+e.n+'?'))act('/api/rm?path='+encodeURIComponent(p))};
    ta.append(r,' ',x);}
   tr.append(td,ts,ta);tb.append(tr);}
  if(!es.length)tb.innerHTML='<tr><td colspan=4 class=mut>Empty folder</td></tr>';
 $('nosd').hidden=true;
 }catch(e){tb.innerHTML='';msg(e.message,1);$('nosd').hidden=!/No SD card server/.test(e.message);}
 selChanged();}
// Move: SdFat's rename moves only the directory entry, so data (and an image's contiguity) is untouched.
async function moveSelected(){const sel=selected();if(!sel.length)return;
 let d=prompt('Move '+sel.length+' item(s) to which folder?\nA name here, or a full path like /HD. It is created if needed.','');
 if(!d)return;d=d.trim().replace(/\/+$/,'');const dest=d.startsWith('/')?(d||'/'):join(cwd,d);
 if(dest===cwd){msg('They are already in '+dest,1);return;}
 try{
  if(dest!=='/'){try{await api('/api/mkdir?path='+encodeURIComponent(dest),{method:'POST'})}catch(e){if(!/EXISTS/.test(e.message))throw e}}
  for(const n of sel){const from=join(cwd,n),to=join(dest,n);
   if(dest===from||dest.startsWith(from+'/'))throw new Error('Cannot move '+n+' into itself');
   await api('/api/mv?from='+encodeURIComponent(from)+'&to='+encodeURIComponent(to),{method:'POST'});
   if(names.has('._'+n)){try{await api('/api/mv?from='+encodeURIComponent(join(cwd,'._'+n))+'&to='+encodeURIComponent(join(dest,'._'+n)),{method:'POST'})}catch(e){}}
   if(from===mountNext)await api('/api/mountnext?path='+encodeURIComponent(to),{method:'POST'});}
  await load();msg('Moved '+sel.length+' item(s) to '+dest);
 }catch(e){await load();msg(e.message,1);}}
$('move').onclick=moveSelected;
// Copy to profile.image (ESProFile card): an on-card copy, so even a big image takes about a second per MB rather than
// a trip through WiFi. An existing profile.image is renamed (kept) or discarded at the user's choice -- but only by the
// server, at the very end, in the same step that moves the finished copy into place (the copy itself goes to a
// temporary file). So if the copy is cut short, e.g. by the Lisa being switched on, the old profile.image is untouched.
const PROFILE='/profile.image';
function askProfile(src,suggest){return new Promise(res=>{const d=$('pdlg');$('psrc').textContent=src;$('pname').value=suggest;
 $('pkeep').onclick=()=>{const n=$('pname').value.trim();if(!n)return;d.close();res({keep:n});};
 $('pdisc').onclick=()=>{d.close();res({discard:1});};$('pcancel').onclick=()=>{d.close();res(null);};d.onclose=()=>res(null);d.showModal();});}
async function copyToProfile(src){
 try{
  const root=await api('/api/ls?path=%2F');const have=new Set(root.entries.map(e=>e.n));
  let start='/api/copystart?from='+encodeURIComponent(src)+'&to='+encodeURIComponent(PROFILE),backup='';
  if(have.has('profile.image')){
   let n=1;while(have.has('profile-backup-'+n+'.image'))n++;          // ESProFile's own backup naming
   const c=await askProfile(src,'profile-backup-'+n+'.image');if(!c)return;
   if(c.keep)backup=join('/',c.keep.replace(/^\/+/,''));
   start+='&replace=1&backup='+encodeURIComponent(backup);              // empty backup = discard the old one
  }
  $('prog').hidden=false;$('prog').value=0;$('progt').textContent='Copying '+src+' to profile.image...';
  const s=await api(start,{method:'POST'});
  let c={copied:0,total:s.total};
  while(c.copied<c.total){c=await api('/api/copystep',{method:'POST'});$('prog').max=c.total;$('prog').value=c.copied;
   $('progt').textContent='Copying to profile.image: '+size(c.copied)+' / '+size(c.total);}
  // The Mac's hidden ._ companion of the old profile.image follows it (not critical, so failures are ignored)
  if(have.has('._profile.image'))try{await api(backup?'/api/mv?from=%2F._profile.image&to='+encodeURIComponent(join('/','._'+backup.slice(1)))
   :'/api/rm?path=%2F._profile.image',{method:'POST'})}catch(e){}
  await load();msg('Copied '+src+' to profile.image. ESProFile will boot from it when ESP32 MODE is back to NORMAL.');
 }catch(e){await load();msg(e.message,1);}
 $('prog').hidden=true;$('progt').textContent='';}
$('all').onchange=e=>{document.querySelectorAll('input.sel').forEach(c=>c.checked=e.target.checked);selChanged();};
function go(p){cwd=p;load();}
async function act(url){try{await api(url,{method:'POST'});load();}catch(e){msg(e.message,1);}}
function upload(f){return new Promise((res,rej)=>{const x=new XMLHttpRequest();x.open('POST','/api/put');
 x.setRequestHeader('X-Path',encodeURIComponent(join(cwd,f.name)));x.setRequestHeader('Content-Type','application/octet-stream');
 x.upload.onprogress=e=>{$('prog').max=e.total;$('prog').value=e.loaded;$('progt').textContent=f.name+' '+size(e.loaded)+' / '+size(e.total)};
 x.onload=()=>{let j={};try{j=JSON.parse(x.responseText)}catch(e){}
  x.status==200?res():rej(new Error(x.status==503?'No SD card server is reachable: switch the board to WIFI FDD or WIFI HDD (Settings tab).':x.status==507?'No contiguous space on the card for '+f.name:(j.error||'HTTP '+x.status)))};
 x.onerror=()=>rej(new Error('Upload failed'));x.send(f);});}
$('file').onchange=async e=>{const fs=[...e.target.files];e.target.value='';$('prog').hidden=false;
 try{for(const f of fs)await upload(f);msg('Uploaded '+fs.length+' file(s)');}catch(err){msg(err.message,1);}
 $('prog').hidden=true;$('progt').textContent='';load();};
$('mkdir').onclick=()=>{const n=prompt('Folder name');if(n)act('/api/mkdir?path='+encodeURIComponent(join(cwd,n)))};
$('refresh').onclick=load;
// Free space needs a FAT scan on ESFloppy (up to ~10 s), so it is read after the listing rather than alongside it.
async function space(){const t=$('info'),b=$('infob');b.disabled=true;t.textContent='Card space: calculating (up to 10 s)...';
 try{const i=await api('/api/info');t.textContent=size(i.free)+' free of '+size(i.card);t.title=i.fw;}
 catch(e){t.textContent='Card space: unavailable';}
 b.disabled=false;}
$('infob').onclick=space;
// ---- Settings tab: the FPGA's own settings, through the WiFi board's control channel (/api/fpga) ----
let fst=null,fpoll=null;const ESPNOTE=$('sEspNote').textContent;
async function fpga(url,opt){const r=await fetch(url,opt);let j={};try{j=await r.json()}catch(e){}
 if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j;}
async function fset(reg,v){await fpga('/api/fpga/set?reg='+reg+'&value='+v,{method:'POST'});await frefresh();}
async function fdo(f){try{msg('');await f();}catch(e){msg(e.message,1);}}
function render(s){
 $('sLisa').textContent=s.lisaOn?'On':'Off';
 const t=$('sTemp');t.textContent=isNaN(s.tempC)?'-':s.tempC.toFixed(1)+' °C'+(s.tempC>=80?' (hot: 85 °C is its limit)':'');
 t.className=s.tempC>=80?'warn':'';
 document.querySelectorAll('#sEsp button').forEach(b=>{b.className=(+b.dataset.v===s.espMode)?'on':'';b.disabled=s.lisaOn;});
 $('sEspNote').style.color=s.lisaOn?'var(--bad)':'';
 $('sEspNote').textContent=s.lisaOn?'Locked while the Lisa is on. Shut it down first.':ESPNOTE;
 const res=$('sRes');res.querySelector('option[value="2"]').disabled=!s.has1024;if(document.activeElement!==res)res.value=s.videoMode;
 if(document.activeElement!==$('sH'))$('sH').value=s.hOff;$('sH').max=s.hLim;$('sHl').textContent='0 - '+s.hLim;
 const vroom=s.vLim>0;if(document.activeElement!==$('sV'))$('sV').value=s.vOff;$('sV').max=s.vLim;
 $('sVl').textContent=vroom?'0 - '+s.vLim:'no room in this mode';
 document.querySelectorAll('[data-ax="3"],#sV').forEach(e=>e.disabled=!vroom);
 $('sCon').checked=s.contrast;$('sConJ').textContent=s.contrastJumper?'(the MAX CONTRAST jumper is on; this flips it)':'';
 if(document.activeElement!==$('sSpd'))$('sSpd').value=s.speedUserSet?s.speedIdx+1:0;
 $('sSaved').textContent=s.saving?'Saving...':s.saved?'Saved settings are in flash.':'Nothing saved yet: defaults at power-up.';}
async function frefresh(){try{const s=await fpga('/api/fpga');fst=s;render(s);}catch(e){msg(e.message,1);}}
// Settings is the first tab; #files in the address keeps the Files tab across a reload. Card space (a slow FAT scan
// on ESFloppy) is read the first time Files is shown.
let spaced=false;
function showTab(set){$('tabF').className=set?'':'on';$('tabS').className=set?'on':'';$('tFiles').hidden=set;$('tSet').hidden=!set;msg('');
 try{history.replaceState(null,'',location.pathname+(set?'':'#files'))}catch(e){}
 clearInterval(fpoll);if(set){frefresh();fwInfo();fpoll=setInterval(frefresh,3000);}
 else if(!spaced){spaced=true;load().then(space);}else load();}
$('tabF').onclick=()=>showTab(false);$('tabS').onclick=()=>showTab(true);
// ESP32 mode, from the Settings tab or the Files tab's shortcut buttons. The chosen ESP32 restarts as the SD server.
async function espMode(v){await fdo(async()=>{await fset(6,v);
 msg(v?'Switching: the chosen drive restarts as the SD server, which takes a few seconds...':'Back to NORMAL: both drives are drives again.');
 if(v&&!$('tFiles').hidden){setTimeout(()=>load().then(space),4000);}});}
document.querySelectorAll('#sEsp button').forEach(b=>b.onclick=()=>espMode(+b.dataset.v));
document.querySelectorAll('#nosd button').forEach(b=>b.onclick=()=>espMode(+b.dataset.esp));
// Resolution, with a way back: the page runs on another screen, so if the display rejects the mode, it reverts by itself
$('sRes').onchange=async()=>{const old=fst?fst.videoMode:0,nv=+$('sRes').value;if(nv===old)return;
 await fdo(async()=>{await fset(1,nv);const d=$('rdlg');let left=15;$('rsec').textContent=left;
  const back=async()=>{clearInterval(tm);if(d.open)d.close();await fdo(()=>fset(1,old));};
  const tm=setInterval(()=>{left--;$('rsec').textContent=left;if(left<=0)back();},1000);
  $('rkeep').onclick=()=>{clearInterval(tm);d.close();};$('rrevert').onclick=back;d.showModal();});};
document.querySelectorAll('[data-ax]').forEach(b=>b.onclick=()=>{if(!fst)return;const ax=+b.dataset.ax,h=ax===2;
 const cur=h?fst.hOff:fst.vOff,lim=h?fst.hLim:fst.vLim,v=Math.max(0,Math.min(lim,cur+(+b.dataset.d)));fdo(()=>fset(ax,v));});
$('sH').onchange=()=>fdo(()=>fset(2,Math.max(0,+$('sH').value||0)));
$('sV').onchange=()=>fdo(()=>fset(3,Math.max(0,+$('sV').value||0)));
$('sCon').onchange=()=>fdo(()=>fset(4,$('sCon').checked?1:0));
$('sSpd').onchange=()=>fdo(()=>fset(5,+$('sSpd').value));
$('bSave').onclick=()=>fdo(async()=>{await fpga('/api/fpga/action?a=save',{method:'POST'});await frefresh();msg('Settings saved to flash.');});
$('bPower').onclick=()=>{const on=fst&&fst.lisaOn;
 if(confirm(on?'Press the Lisa’s power button? LOS will be asked to shut down, as with the real button.':'Press the Lisa’s power button to turn it on?'))
  fdo(async()=>{await fpga('/api/fpga/action?a=power',{method:'POST'});msg('Power button pressed.');setTimeout(frefresh,1500);});};
$('bReset').onclick=()=>{if(confirm('Reset the Lisa? This is a hard stop, like the real reset button: anything unsaved is lost, and a disk that was being written may need repairing.'))
  fdo(async()=>{await fpga('/api/fpga/action?a=reset',{method:'POST'});msg('Reset pressed.');});};
// ---- This board's firmware: upload to the other slot, restart, wait for it to come back ----
async function fwInfo(){try{const f=await fpga('/api/fw');
 $('fwRun').textContent=f.version+' ('+f.slot+(f.pending?', on trial: kept after 20 s':'')+')';
 const b=$('fwBack');b.hidden=!f.canRollBack;b.textContent='Go back to '+(f.prev||'the previous version');return f;}
 catch(e){$('fwRun').textContent='-';return null;}}
function fwBack(note){$('fwT').textContent=note+' Waiting for the board to come back...';let n=0;
 const t=setInterval(async()=>{n++;const f=await fwInfo();
  if(f){clearInterval(t);$('fwProg').hidden=true;$('fwT').textContent='';msg('The WiFi board is running firmware '+f.version+'.');}
  else if(n>30){clearInterval(t);$('fwT').textContent='';msg('The board has not come back after a minute. Reload the page; if it still fails, check its USB console.',1);}},2000);}
$('fwFile').onchange=e=>{const f=e.target.files[0];e.target.value='';if(!f)return;
 if(/merged/i.test(f.name)&&!confirm(f.name+' looks like a merged image, which will be refused. Try anyway?'))return;
 if(!confirm('Install '+f.name+' ('+size(f.size)+') on the WiFi board? It restarts afterwards; the page comes back in about 10 s.'))return;
 msg('');const x=new XMLHttpRequest();x.open('POST','/api/fw/update');x.setRequestHeader('Content-Type','application/octet-stream');
 $('fwProg').hidden=false;$('fwProg').value=0;
 x.upload.onprogress=e=>{$('fwProg').max=e.total;$('fwProg').value=e.loaded;$('fwT').textContent='Uploading '+size(e.loaded)+' / '+size(e.total)};
 x.onload=()=>{let j={};try{j=JSON.parse(x.responseText)}catch(e){}
  if(x.status==200){$('fwT').textContent='';fwBack('Installed '+(j.version||'')+', restarting.');}
  else{$('fwProg').hidden=true;$('fwT').textContent='';msg(j.error||('HTTP '+x.status),1);}};
 x.onerror=()=>{$('fwProg').hidden=true;$('fwT').textContent='';msg('Upload failed',1);};x.send(f);};
$('fwBack').onclick=()=>{if(!confirm($('fwBack').textContent+'? The board restarts.'))return;
 fdo(async()=>{await fpga('/api/fw/rollback',{method:'POST'});fwBack('Going back.');});};
showTab(location.hash!=='#files');
</script></body></html>
)HTML";
}  // namespace web
