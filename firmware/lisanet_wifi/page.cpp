// The SD card manager page served by web.cpp. Written with an AI assistant.
namespace web {
extern const char PAGE[] = R"HTML(<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LisaNet</title>
<style>
:root{--bg:#f4f1ea;--fg:#1d1b18;--mut:#6b665d;--line:#d8d2c4;--acc:#2f5d8a;--bad:#a33;--card:#fffdf8}
@media (prefers-color-scheme:dark){:root{--bg:#181715;--fg:#ece8df;--mut:#9a9488;--line:#34312c;--acc:#7fa9d6;--bad:#e07b7b;--card:#211f1c}}
*{box-sizing:border-box}[hidden]{display:none!important}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 system-ui,sans-serif}
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
<nav class="tabs"><button id="tabS" class="on">Settings</button><button id="tabF" hidden>Files</button></nav>
<div id="msg"></div>
<section id="tFiles" hidden>
<div class="card" id="fOff" hidden><h3>Not available while the Lisa is on</h3>
<p class="mut">The SD cards can only be managed while the Lisa is off. Shut it down (from LOS, or Press power button on the
Settings tab), and this page comes back by itself. To change the floppy disk while the Lisa runs, use Floppy drive on
the Settings tab.</p></div>
<div id="fBody">
<div class="mut sp"><span id="info">Card space</span> <button id="infob" class="mini" title="Recalculate card space">&#x21bb;</button></div>
<div class="bar" id="nosd" hidden><span class="mut">Switch to:</span><button data-esp="1">Manage ESFloppy files</button><button data-esp="2">Manage ESProFile files</button></div>
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
</div>
</section>
<section id="tSet">
<div class="card"><h3>Lisa</h3>
<div class="row"><label class="k">Power</label><span id="sLisa">-</span></div>
<div class="row"><label class="k">FPGA die</label><span id="sTemp">-</span></div>
<div class="row"><button id="bPower">Press power button</button><button id="bReset" class="danger">Reset</button><button id="bNmi" class="danger" hidden>NMI</button></div></div>
<div class="card" id="dCard" hidden><h3>Floppy drive</h3><div id="dRows"></div><div class="mut" id="dNote"></div></div>
<div class="card"><h3>ESP32 mode</h3>
<div class="row"><div class="seg" id="sEsp"><button data-v="0">Normal</button><button data-v="1">Manage ESFloppy files</button><button data-v="2">Manage ESProFile files</button></div></div>
<div class="mut" id="sEspNote">Normal: both drives are the Lisa's drives. Manage ESFloppy files / Manage ESProFile files: that drive's SD card
opens in the Files tab, and the drive is offline meanwhile. Those can only be chosen while the Lisa is off. (The on-screen
menu calls them WIFI FDD and WIFI HDD.)</div></div>
<div class="card"><h3>Display</h3>
<div class="row"><label class="k" for="sRes">Resolution</label><select id="sRes"><option value="0">1080p30</option><option value="1">1080p60</option><option value="2">1024x768</option></select></div>
<div class="row"><label class="k">Horizontal</label><button data-ax="2" data-d="-8">&laquo;</button><button data-ax="2" data-d="-1">&lsaquo;</button>
<input type="number" id="sH" min="0"><button data-ax="2" data-d="1">&rsaquo;</button><button data-ax="2" data-d="8">&raquo;</button><span class="mut" id="sHl"></span></div>
<div class="row"><label class="k">Vertical</label><button data-ax="3" data-d="-8">&laquo;</button><button data-ax="3" data-d="-1">&lsaquo;</button>
<input type="number" id="sV" min="0"><button data-ax="3" data-d="1">&rsaquo;</button><button data-ax="3" data-d="8">&raquo;</button><span class="mut" id="sVl"></span></div>
<div class="row"><label class="k" for="sCon">Max contrast</label><input type="checkbox" id="sCon"><span class="mut" id="sConJ"></span></div>
<div class="row mach" hidden><label class="k" for="sScan">Scanlines</label><input type="checkbox" id="sScan"><span class="mut" id="sScanJ"></span></div>
<div class="row mach" hidden><label class="k" for="sInv">Inverse video</label><input type="checkbox" id="sInv"><span class="mut" id="sInvJ"></span></div></div>
<div class="card"><h3>CPU speed</h3>
<div class="row"><select id="sSpd"><option value="0">Follow the SPEED switches</option><option value="1">5 MHz</option><option value="2">10 MHz</option>
<option value="3">15 MHz</option><option value="4">18.75 MHz</option></select></div></div>
<div class="card mach" hidden><h3>Machine</h3>
<div class="row"><label class="k">CPU ROM</label><div class="seg" id="sCpuRom"><button data-v="0">H</button><button data-v="1">3A</button></div><span class="mut" id="sCpuRomJ"></span></div>
<div class="row"><label class="k">I/O ROM</label><div class="seg" id="sIoRom"><button data-v="0">Sony (A8)</button><button data-v="1">Twiggy (40)</button></div><span class="mut" id="sIoRomJ"></span></div>
<div class="row"><label class="k" for="sRam">RAM</label><select id="sRam"><option value="0">Follow the RAM SIZE jumpers</option><option value="1">512 KB</option>
<option value="2">1 MB</option><option value="3">1.5 MB</option><option value="4">2 MB</option></select><span class="mut" id="sRamJ"></span></div>
<div class="mut" id="sMachNote">H ROMs work in every OS; 3A only in MacWorks. Use the Twiggy ROM only with a Twiggy drive. These can only change while the Lisa is off.</div></div>
<div class="card sb" hidden><h3>FujiNet (Serial B)</h3>
<div class="row"><label class="k" for="sFn">Serial B</label><select id="sFn"><option value="0">Its own port</option><option value="1">This WiFi board (FujiNet adapter)</option>
<option value="2">Bench test: the board's Serial B USB port to this board</option></select></div>
<div class="row"><label class="k" for="fnBaud">Baud rate</label><select id="fnBaud"><option>1200</option><option>2400</option><option>4800</option>
<option>9600</option><option>19200</option><option>38400</option><option>57600</option><option>115200</option></select></div>
<div class="row"><label class="k" for="fnTz">Time zone</label><input id="fnTz" size="26" placeholder="UTC0"><button id="fnTzB">Set</button></div>
<div class="row"><label class="k">Clock</label><span id="fnTime">-</span></div>
<div class="mut">For Lisa programs written for an RS-232 FujiNet, such as LisaFuji: web pages over HTTP and HTTPS, JSON, the network
clock. Serial B shares the WiFi board's two serial wires with the Serial A modem, so while it is on, Serial A is its own port
again. The time zone is in POSIX form (e.g. EST5EDT,M3.2.0,M11.1.0). Like the other settings, these apply at once and are
kept across a power cycle only after Save settings.</div>
<div class="row"><span class="mut" id="fnStat"></span></div>
<pre id="fnLog" class="mut" style="white-space:pre-wrap;font-size:12px;margin:4px 0 0"></pre></div>
<div class="card sb" hidden><h3>AI chat (for Lisa programs)</h3>
<div class="row"><label class="k" for="chEnable">AI chat</label><label><input type="checkbox" id="chEnable"> Enable AI chat</label><span class="mut">off by default</span></div>
<div id="chBody" hidden>
<div class="row"><label class="k" for="chProv">Default</label><select id="chProv"><option value="claude">Claude</option><option value="openai">OpenAI</option></select>
<span class="mut">used for chat:// ; chat://claude and chat://openai choose one</span></div>
<div class="row"><label class="k" for="chCKey">Claude key</label><input id="chCKey" type="password" size="30" autocomplete="off" placeholder="sk-ant-..."><span class="mut" id="chCSet"></span></div>
<div class="row"><label class="k" for="chCModel">Claude model</label><input id="chCModel" size="30"></div>
<div class="row"><label class="k" for="chOKey">OpenAI key</label><input id="chOKey" type="password" size="30" autocomplete="off" placeholder="sk-..."><span class="mut" id="chOSet"></span></div>
<div class="row"><label class="k" for="chOModel">OpenAI model</label><input id="chOModel" size="30"></div>
<div class="row"><label class="k" for="chTok">Reply length</label><input id="chTok" type="number" min="16" max="4000" style="width:80px"><span class="mut">tokens at most</span></div>
<div class="row"><label class="k" for="chTurns">Memory</label><input id="chTurns" type="number" min="2" max="40" style="width:80px"><span class="mut">messages kept per conversation</span></div>
<div class="row"><label class="k" for="chSys">Instructions</label><textarea id="chSys" rows="3" cols="46" maxlength="600"></textarea></div>
<div class="row"><label class="k" for="chVerify">Certificates</label><label><input type="checkbox" id="chVerify"> Verify certificates</label><span class="mut">turn off only if a provider changes its certificate authority</span></div>
<div class="row"><button id="chSave">Save chat settings</button><button id="chReset">Forget the conversation</button><span class="mut" id="chStat"></span></div>
<div class="row"><label class="k" for="chText">Try it</label><input id="chText" size="40" placeholder="Ask something"><button id="chAsk">Ask</button></div>
<pre id="chOut" class="mut" style="white-space:pre-wrap;font-size:12px;margin:4px 0 0"></pre>
</div>
<div class="mut">A Lisa program opens chat://claude or chat://openai on a network unit, writes a question and reads the answer, as plain
ASCII. The WiFi board keeps the API keys (blank leaves a key as it is; the page never shows one), the settings and the conversation.
AI chat is off unless you turn it on here; while it is off, nothing is ever sent to an AI service. These are kept at once, without Save settings. The HTTPS connections check the providers' certificates against Google Trust Services roots built into the firmware.</div></div>
<div class="bar"><button id="bSave">Save settings</button><span class="mut" id="sSaved"></span></div>
<p class="mut">Changes apply at once, as in the on-screen menu, and are kept across a power cycle only after Save settings.</p>
<div class="card"><h3>WiFi board firmware</h3>
<div class="row"><label class="k">Running</label><span id="fwRun">-</span></div>
<div class="row"><label class="btn">Install update...<input type="file" id="fwFile" accept=".bin" hidden></label>
<button id="fwBack" hidden></button><progress id="fwProg" max="1" value="0" hidden></progress><span class="mut" id="fwT"></span></div>
<p class="mut">Choose <b>lisanet_wifi.ino.bin</b> from the firmware's build folder (not the .merged.bin). The board restarts into it.
A new version has to run for 20 s before it is kept: if it crashes sooner, the board goes back to this one by itself.</p></div>
</section>
<dialog id="ddlg"><p><b>Insert a disk</b> <span class="mut" id="dfor"></span></p>
<div class="row"><select id="dsel" style="max-width:100%"><option value="">Scanning the card...</option></select></div>
<div class="mut" id="dstat"></div>
<div class="bar"><button id="dload" disabled>Load Disk</button><button id="dcancel">Cancel</button><button id="drescan" title="Read the card again (only needed if the SD card was swapped)">Rescan</button></div></dialog>
<dialog id="rdlg"><p><b>Keep this resolution?</b></p><p class="mut">If the display went blank, do nothing: it goes back in <span id="rsec">15</span> s.</p>
<div class="bar"><button id="rkeep">Keep</button><button id="rrevert">Go back now</button></div></dialog>
</main><script>
let cwd='/',mountNext='',names=new Set(),profile=false;
const $=id=>document.getElementById(id);
const join=(d,n)=>(d.endsWith('/')?d:d+'/')+n;
const isImg=n=>/\.(dc42|image|img)$/i.test(n);
function msg(t,bad){const m=$('msg');m.textContent=t;m.className=t?(bad?'err':'ok'):'';}
async function api(url,opt){const r=await fetch(url,opt);let j={};try{j=await r.json()}catch(e){}
 if(!r.ok)throw new Error(r.status==503?'No SD card server is reachable yet: the drive takes a few seconds to restart as one. Try again shortly, or switch below.':(j.error||('HTTP '+r.status)));return j;}
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
  await load();msg('Copied '+src+' to profile.image. ESProFile will boot from it once the drives are back to Normal.');
 }catch(e){await load();msg(e.message,1);}
 $('prog').hidden=true;$('progt').textContent='';}
$('all').onchange=e=>{document.querySelectorAll('input.sel').forEach(c=>c.checked=e.target.checked);selChanged();};
function go(p){cwd=p;load();}
async function act(url){try{await api(url,{method:'POST'});load();}catch(e){msg(e.message,1);}}
function upload(f){return new Promise((res,rej)=>{const x=new XMLHttpRequest();x.open('POST','/api/put');
 x.setRequestHeader('X-Path',encodeURIComponent(join(cwd,f.name)));x.setRequestHeader('Content-Type','application/octet-stream');
 x.upload.onprogress=e=>{$('prog').max=e.total;$('prog').value=e.loaded;$('progt').textContent=f.name+' '+size(e.loaded)+' / '+size(e.total)};
 x.onload=()=>{let j={};try{j=JSON.parse(x.responseText)}catch(e){}
  x.status==200?res():rej(new Error(x.status==503?'No SD card server is reachable: on the Settings tab, choose Manage ESFloppy files or Manage ESProFile files.':x.status==507?'No contiguous space on the card for '+f.name:(j.error||'HTTP '+x.status)))};
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
let fst=null,fpoll=null;const ESPNOTE=$('sEspNote').textContent,MACHNOTE=$('sMachNote').textContent;
async function fpga(url,opt){const r=await fetch(url,opt);let j={};try{j=await r.json()}catch(e){}
 if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j;}
async function fset(reg,v){await fpga('/api/fpga/set?reg='+reg+'&value='+v,{method:'POST'});await frefresh();}
async function fdo(f){try{msg('');await f();}catch(e){msg(e.message,1);}}
function render(s){
 $('sLisa').textContent=s.lisaOn?'On':'Off';
 const t=$('sTemp');t.textContent=isNaN(s.tempC)?'-':s.tempC.toFixed(1)+' °C'+(s.tempC>=80?' (hot: 85 °C is its limit)':'');
 t.className=s.tempC>=80?'warn':'';
 // While the Lisa is on, only the way back to Normal stays open (it brings the drive back; managing a drive's files
 // would take it away under the running Lisa). The Files tab exists only while a drive's files are being managed.
 const back=s.lisaOn&&s.espMode!==0;
 $('tabF').hidden=s.espMode===0;
 document.querySelectorAll('#sEsp button').forEach(b=>{b.className=(+b.dataset.v===s.espMode)?'on':'';b.disabled=s.lisaOn&&!(back&&+b.dataset.v===0);});
 $('sEspNote').style.color=s.lisaOn?'var(--bad)':'';
 $('sEspNote').textContent=!s.lisaOn?ESPNOTE:back?'The Lisa is on: you can switch back to Normal (the drive comes back online), but not manage a drive\'s files until it is off.':
  'Locked while the Lisa is on. Shut it down first.';
 const res=$('sRes');res.querySelector('option[value="2"]').disabled=!s.has1024;if(document.activeElement!==res)res.value=s.videoMode;
 if(document.activeElement!==$('sH'))$('sH').value=s.hOff;$('sH').max=s.hLim;$('sHl').textContent='0 - '+s.hLim;
 const vroom=s.vLim>0;if(document.activeElement!==$('sV'))$('sV').value=s.vOff;$('sV').max=s.vLim;
 $('sVl').textContent=vroom?'0 - '+s.vLim:'no room in this mode';
 document.querySelectorAll('[data-ax="3"],#sV').forEach(e=>e.disabled=!vroom);
 $('sCon').checked=s.contrast;$('sConJ').textContent=s.contrastJumper?'(the MAX CONTRAST jumper is on; this flips it)':'';
 if(document.activeElement!==$('sSpd'))$('sSpd').value=s.speedUserSet?s.speedIdx+1:0;
 $('sSaved').textContent=s.saving?'Saving...':s.saved?'Saved settings are in flash.':'Nothing saved yet: defaults at power-up.';
 // Serial B to this board (FujiNet): FPGA control version 3
 const sb=s.version>=3;document.querySelectorAll('.sb').forEach(e=>e.hidden=!sb);
 if(sb&&document.activeElement!==$('sFn'))$('sFn').value=s.serialB;
 // Jumper/switch overrides and NMI: only with an FPGA build that reports them (control version 2)
 const m=!!s.hasMachine;document.querySelectorAll('.mach').forEach(e=>e.hidden=!m);$('bNmi').hidden=!m;if(!m)return;
 const note=(eff,sw,what)=>'('+what+(eff!==sw?'; overridden here':'')+')';
 $('sScan').checked=s.scanlines;$('sScanJ').textContent=note(s.scanlines,s.scanlinesJumper,'jumper '+(s.scanlinesJumper?'ON':'OFF'));
 $('sInv').checked=s.inverse;$('sInvJ').textContent=note(s.inverse,s.inverseJumper,'jumper at '+(s.inverseJumper?'INV':'REG'));
 const seg=(id,v)=>document.querySelectorAll('#'+id+' button').forEach(b=>{b.className=(+b.dataset.v===v)?'on':'';b.disabled=s.lisaOn;});
 seg('sCpuRom',s.rom3A?1:0);$('sCpuRomJ').textContent=note(s.rom3A,s.rom3ASwitch,'switch at '+(s.rom3ASwitch?'3A':'H'));
 seg('sIoRom',s.twiggy?1:0);$('sIoRomJ').textContent=note(s.twiggy,s.twiggySwitch,'switch at '+(s.twiggySwitch?'Twiggy':'Sony'));
 const RAM=['512 KB','1 MB','1.5 MB','2 MB'],r=$('sRam');r.disabled=s.lisaOn;
 if(document.activeElement!==r)r.value=s.ramUserSet?s.ram+1:0;
 $('sRamJ').textContent='(jumpers: '+RAM[s.ramSwitch]+(s.ramUserSet?'; '+RAM[s.ram]+' set here':'')+')';
 $('sMachNote').style.color=s.lisaOn?'var(--bad)':'';
 $('sMachNote').textContent=s.lisaOn?'Locked while the Lisa is on. Shut it down first.':MACHNOTE;}
// An FPGA without the control channel can't say which mode it is in: then the Files tab stays available, as before.
async function frefresh(){try{const s=await fpga('/api/fpga');fst=s;render(s);}catch(e){msg(e.message,1);$('tabF').hidden=false;}drefresh();
 if(fst&&fst.version>=3){fninfo();if(!chLoaded)chinfo();}}
// FujiNet card: the adapter's own settings and what the Lisa has been asking for
function fnshow(i){if(document.activeElement!==$('fnBaud'))$('fnBaud').value=i.baud;if(document.activeElement!==$('fnTz'))$('fnTz').value=i.tz;
 $('fnTime').textContent=i.time+(i.unsaved?'  (baud rate or time zone not saved yet)':'');
 $('fnStat').textContent=(i.routed?'Active':'Not active (Serial B is on its own port)')+' - '+i.packets+' requests, '+i.naks+' refused';
 $('fnLog').textContent=i.log.slice().reverse().join('\n');}
async function fninfo(){try{fnshow(await fpga('/api/fujinet'));}catch(e){}}
async function fnset(q){await fdo(async()=>{fnshow(await fpga('/api/fujinet?'+q,{method:'POST'}));});}
// AI chat card: settings in the board's NVS, and a one-off test question
let chLoaded=false,chTimer=null;
function chShow(i){const f=(id,v)=>{if(document.activeElement!==$(id))$(id).value=v;};
 f('chProv',i.provider);f('chCModel',i.claudeModel);f('chOModel',i.openaiModel);f('chTok',i.maxTokens);f('chTurns',i.turns);f('chSys',i.system);$('chVerify').checked=i.verify;$('chEnable').checked=i.enabled;$('chBody').hidden=!i.enabled;
 $('chCKey').placeholder=i.claudeKey?'(set - leave blank to keep)':'sk-ant-...';$('chOKey').placeholder=i.openaiKey?'(set - leave blank to keep)':'sk-...';
 $('chCSet').textContent=i.claudeKey?'key set':'no key';$('chOSet').textContent=i.openaiKey?'key set':'no key';
 $('chStat').textContent='Conversation: Claude '+i.claudeTurns+', OpenAI '+i.openaiTurns+' messages'+(i.last?' - last: '+i.last:'');chLoaded=true;}
async function chinfo(){try{chShow(await fpga('/api/chat'));}catch(e){}}
$('chSave').onclick=()=>fdo(async()=>{const b=new URLSearchParams();
 b.set('provider',$('chProv').value);b.set('claudeModel',$('chCModel').value);b.set('openaiModel',$('chOModel').value);
 b.set('maxTokens',$('chTok').value);b.set('turns',$('chTurns').value);b.set('system',$('chSys').value);b.set('verify',$('chVerify').checked?'1':'0');
 if($('chCKey').value.trim())b.set('claudeKey',$('chCKey').value);if($('chOKey').value.trim())b.set('openaiKey',$('chOKey').value);
 chShow(await fpga('/api/chat/config',{method:'POST',body:b}));$('chCKey').value='';$('chOKey').value='';msg('Chat settings saved.');});
$('chEnable').onchange=()=>fdo(async()=>{const b=new URLSearchParams();b.set('enabled',$('chEnable').checked?'1':'0');
 chShow(await fpga('/api/chat/config',{method:'POST',body:b}));});
$('chReset').onclick=()=>fdo(async()=>{chShow(await fpga('/api/chat/reset',{method:'POST'}));});
$('chAsk').onclick=()=>fdo(async()=>{const b=new URLSearchParams();b.set('provider',$('chProv').value);b.set('text',$('chText').value);
 await fpga('/api/chat/test',{method:'POST',body:b});$('chOut').textContent='Thinking...';clearInterval(chTimer);
 chTimer=setInterval(async()=>{try{const r=await fpga('/api/chat/test');if(r.state==='reply'){clearInterval(chTimer);$('chOut').textContent=r.reply;}
  else if(r.state==='idle'){clearInterval(chTimer);$('chOut').textContent='(no answer)';}}catch(e){clearInterval(chTimer);$('chOut').textContent=e.message;}},1000);});
// Settings is the first tab; #files in the address keeps the Files tab across a reload. Card space (a slow FAT scan
// on ESFloppy) is read the first time Files is shown.
// While the Lisa is on, the Files tab shows only a notice; it checks every 3 s and loads the list once the Lisa is off.
// An FPGA without the control channel (no answer) counts as off, so the tab works as before there.
let spaced=false,filesLisaOn=null;
// The tab closes by itself if the drives go back to Normal some other way (the on-screen menu, or the Lisa switched on
// while ESProFile's files were open).
async function filesCheck(first){let on=false,mode=-1;try{const s=await fpga('/api/fpga');on=!!s.lisaOn;mode=s.espMode;}catch(e){}
 if($('tFiles').hidden)return;
 if(mode===0){$('tabF').hidden=true;showTab(true);msg('The Files tab closed: the drives are back to Normal.');return;}
 if(on===filesLisaOn&&!first)return;filesLisaOn=on;$('fOff').hidden=!on;$('fBody').hidden=on;
 if(on){msg('');return;}
 if(!spaced){spaced=true;load().then(space);}else load();}
function showTab(set){$('tabF').className=set?'':'on';$('tabS').className=set?'on':'';$('tFiles').hidden=set;$('tSet').hidden=!set;msg('');
 try{history.replaceState(null,'',location.pathname+(set?'':'#files'))}catch(e){}
 clearInterval(fpoll);if(set){frefresh();fwInfo();fpoll=setInterval(frefresh,3000);}
 else{filesCheck(true);fpoll=setInterval(()=>filesCheck(false),3000);}}
$('tabF').onclick=()=>showTab(false);$('tabS').onclick=()=>showTab(true);
// ESP32 mode, from the Settings tab or the Files tab's shortcut buttons. The chosen ESP32 restarts as the SD server.
async function espMode(v){await fdo(async()=>{if(v===0)dRetryAt=Date.now()+10000;   // ESFloppy needs ~8 s to restart as the drive
 await fset(6,v);
 msg(v?'Switching: the drive restarts as the SD card server, and its files open here in a few seconds...':'Back to Normal: both drives are the Lisa\'s drives again (the floppy drive is back in about 10 s).');
 // Give the drive ~4 s to restart as the server, then show its files
 if(v)setTimeout(()=>{if(!fst||fst.espMode!==v)return;if($('tFiles').hidden)showTab(false);else load().then(space);},4000);});}
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
$('sScan').onchange=()=>fdo(()=>fset(8,$('sScan').checked?1:0));
$('sInv').onchange=()=>fdo(()=>fset(9,$('sInv').checked?1:0));
document.querySelectorAll('#sCpuRom button').forEach(b=>b.onclick=()=>fdo(()=>fset(10,+b.dataset.v)));
document.querySelectorAll('#sIoRom button').forEach(b=>b.onclick=()=>fdo(()=>fset(11,+b.dataset.v)));
$('sRam').onchange=()=>fdo(()=>fset(12,+$('sRam').value));
$('sFn').onchange=()=>fdo(async()=>{await fset(13,+$('sFn').value);
 const v=+$('sFn').value;msg(v===1?'Serial B is now on the WiFi board: the FujiNet adapter is answering (Serial A is its own port again).':
  v===2?'Bench test: a PC on the board\x27s Serial B USB port now talks to the FujiNet adapter, and the Lisa\x27s Serial B is idle. Not saved.':'Serial B is back on its own port.');});
$('fnBaud').onchange=()=>fnset('baud='+$('fnBaud').value);
$('fnTzB').onclick=()=>fnset('tz='+encodeURIComponent($('fnTz').value));
$('bNmi').onclick=()=>{if(confirm('Press the NMI button? As with the real one, what happens depends on what the Lisa is running, and it may crash.'))
  fdo(async()=>{await fpga('/api/fpga/action?a=nmi',{method:'POST'});msg('NMI pressed.');});};
$('bSave').onclick=()=>fdo(async()=>{await fpga('/api/fpga/action?a=save',{method:'POST'});await frefresh();msg('Settings saved to flash.');});
$('bPower').onclick=()=>{const on=fst&&fst.lisaOn;
 if(confirm(on?'Press the Lisa’s power button? LOS will be asked to shut down, as with the real button.':'Press the Lisa’s power button to turn it on?'))
  fdo(async()=>{await fpga('/api/fpga/action?a=power',{method:'POST'});msg('Power button pressed.');setTimeout(frefresh,1500);});};
$('bReset').onclick=()=>{if(confirm('Reset the Lisa? This is a hard stop, like the real reset button: anything unsaved is lost, and a disk that was being written may need repairing.'))
  fdo(async()=>{await fpga('/api/fpga/action?a=reset',{method:'POST'});msg('Reset pressed.');});};
// ---- This board's firmware: upload to the other slot, restart, wait for it to come back ----
async function fwInfo(){try{const f=await fpga('/api/fw');
 const r=$('fwRun');r.textContent=f.version+(f.notes?' ('+f.notes+')':'')+(f.pending?' -- on trial: kept after 20 s':'');r.title='Running from flash slot '+f.slot;
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
// ---- Floppy drive remote control: ESFloppy's drive firmware answers in Normal mode, Lisa on or off ----
// Older ESFloppy firmware never answers; then only try again every 30 s, so the WiFi board isn't kept waiting.
let dRetryAt=0,dBusy=false;
async function drefresh(){const c=$('dCard');
 // While ESFloppy's files are being managed the drive is offline: say so, with the way back -- allowed even while
 // the Lisa is on, since returning to Normal only brings the drive back.
 if(fst&&fst.espMode===1){c.hidden=false;const rows=$('dRows');rows.innerHTML='';const row=document.createElement('div');row.className='row';
  const t=document.createElement('span');t.textContent='Offline while ESFloppy\'s files are being managed.';
  const b=document.createElement('button');b.textContent='Switch to Normal';b.onclick=()=>espMode(0);row.append(t,b);rows.append(row);
  $('dNote').textContent='Back in Normal, ESFloppy is the floppy drive again (mount-next inserts its disk), and you can insert or eject here.';return;}
 if(!fst||fst.espMode!==0||Date.now()<dRetryAt||dBusy){if(!fst||fst.espMode!==0)c.hidden=true;return;}
 dBusy=true;try{const r=await fetch('/api/drive');if(!r.ok)throw 0;drender(await r.json());c.hidden=false;dRetryAt=0;}
 catch(e){c.hidden=true;dRetryAt=Date.now()+30000;}dBusy=false;}
const base=p=>p.replace(/^.*\//,'');
function drender(d){const rows=$('dRows');rows.innerHTML='';
 for(const v of d.drives){if(!v.exists)continue;const row=document.createElement('div');row.className='row';
  const k=document.createElement('label');k.className='k';k.textContent=d.twiggy?(v.n===0?'Upper drive':'Lower drive'):'Drive';
  const t=document.createElement('span');t.textContent=v.ejecting?'Ejecting...':v.inserted?base(v.name):'Empty';if(v.inserted)t.title=v.name;
  row.append(k,t);
  if(v.inserted&&!v.ejecting){
   if(d.twiggy){const b=document.createElement('button');b.textContent='Eject';b.title='Like pressing the drive\'s eject button: the Lisa ejects the disk when it is ready';
    b.onclick=()=>deject(v,false);row.append(b);}
   const f=document.createElement('button');f.className='danger';f.textContent=d.twiggy?'Force eject':'Eject';f.onclick=()=>deject(v,true);row.append(f);}
  else if(!v.inserted&&!v.ejecting){const b=document.createElement('button');b.textContent='Insert disk...';b.disabled=d.uiBusy;b.onclick=()=>dpick(v.n,d.twiggy);row.append(b);}
  rows.append(row);}
 $('dNote').textContent=d.uiBusy?'ESFloppy\'s own menu is open on its screen; close it to insert a disk from here.':
  'Eject from LOS when you can; the eject here is like pulling the disk out of the drive.';}
function deject(v,force){
 if(force&&!confirm('Force-eject '+base(v.name)+'? This is like pulling the disk out of the drive: if the Lisa is using it, unsaved changes are lost and the disk may need repairing. Eject it from LOS instead when you can.'))return;
 fdo(async()=>{await fpga('/api/drive/eject?drive='+v.n+'&force='+(force?1:0),{method:'POST'});msg(force?'Ejected.':'Eject requested: the Lisa ejects the disk when it is ready.');dRetryAt=0;await drefresh();});}
// Insert: one dropdown of every image on the card that this drive mode accepts (the drive's own filter, as on its
// OLED; hidden folders excluded, 4 levels deep), then Load Disk. The WiFi board reads the card in the background in
// Normal mode and keeps the list (/api/drive/images), so it is normally there at once; while it is still being read,
// the dialog shows how far it has got and fills in when it is done.
let dDrive=1,dScan=0;
function derr(e,my){if(my!==dScan)return;$('dsel').innerHTML='<option value="">Could not read the card</option>';$('dstat').textContent=e.message;}
function dfill(r,my){if(my!==dScan||!$('ddlg').open)return;const s=$('dsel');$('dload').disabled=true;
 if(r.state!=='ready'){s.innerHTML='<option value="">Reading the card for disk images...</option>';
  $('dstat').textContent=r.state==='scanning'?'Reading the card: '+r.folders+' folder'+(r.folders===1?'':'s')+' so far.':'Waiting for ESFloppy to answer...';
  setTimeout(()=>fpga('/api/drive/images').then(x=>dfill(x,my)).catch(e=>derr(e,my)),1000);return;}
 s.innerHTML='';const list=r.images;
 s.add(new Option(list.length?'Choose a disk image...':'No disk images this drive can use',''));
 for(const f of list)s.add(new Option(f.p.replace(/^\//,'')+'  ('+size(f.s)+')',f.p));
 $('dstat').textContent=list.length+' image'+(list.length===1?'':'s')+' found'+(r.full?' (the list is full: only the first 400 are shown)':'')+'.';}
function dpick(n,twiggy){dDrive=n;$('dfor').textContent=twiggy?(n===0?'into the upper drive':'into the lower drive'):'';
 const my=++dScan;$('dsel').innerHTML='<option value="">Loading the list of disk images...</option>';$('dload').disabled=true;
 $('dstat').textContent='';$('ddlg').showModal();
 fpga('/api/drive/images').then(r=>dfill(r,my)).catch(e=>derr(e,my));}
$('drescan').onclick=()=>{const my=++dScan;$('dsel').innerHTML='<option value="">Reading the card for disk images...</option>';$('dload').disabled=true;
 fpga('/api/drive/images',{method:'POST'}).then(r=>dfill(r,my)).catch(e=>derr(e,my));};
$('dsel').onchange=()=>{$('dload').disabled=!$('dsel').value;};
$('dload').onclick=()=>{const p=$('dsel').value;if(p)dinsert(p);};
$('dcancel').onclick=()=>{dScan++;$('ddlg').close();};
async function dinsert(path){$('ddlg').close();
 await fdo(async()=>{try{await fpga('/api/drive/insert?drive='+dDrive+'&path='+encodeURIComponent(path),{method:'POST'});}
  catch(e){throw new Error(/UI_BUSY/.test(e.message)?'ESFloppy\'s own menu is open; close it and try again.':/EXISTS/.test(e.message)?'That drive already has a disk.':
   /IN_USE/.test(e.message)?'That image is already in the other drive.':/BAD_IMAGE/.test(e.message)?'That image can\'t be used in this drive.':
   /NO_CONTIGUOUS/.test(e.message)?'That image is fragmented on the card. Re-upload it from the Files tab (uploads are always contiguous).':e.message);}
  msg('Inserted '+base(path)+'.');dRetryAt=0;await drefresh();});}
showTab(location.hash!=='#files');
</script></body></html>
)HTML";
}  // namespace web
