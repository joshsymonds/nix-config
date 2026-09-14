// Run via test-process-keepalive.sh. No credentials, network, polling or model spend.
import assert from 'node:assert/strict';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { once as childOnce } from 'node:events';
import { pathToFileURL } from 'node:url';
import { setImmediate as checkpoint } from 'node:timers/promises';
const [sdkPath, packagePath, installedPath] = process.argv.slice(2);
const sdk = await import(pathToFileURL(`${sdkPath}/dist/index.js`));
const require = createRequire(`${sdkPath}/dist/index.js`);
// Capture actual children for event-driven exit assertions, not PID polling.
const childProcessModule = require('node:child_process');
const originalSpawn = childProcessModule.spawn;
const spawnedChildren = new Map();
childProcessModule.spawn = (...args) => {
  const child = originalSpawn(...args);
  spawnedChildren.set(child.pid, { child, closed: childOnce(child, 'close') });
  return child;
};
syncBuiltinESMExports();
const { createJiti } = require('jiti');
const jiti = createJiti(import.meta.url, { fsCache: false, moduleCache: false,
  virtualModules: {
    '@earendil-works/pi-coding-agent': sdk,
    '@earendil-works/pi-ai': await import(pathToFileURL(`${sdkPath}/../pi-ai/dist/compat.js`)),
    '@earendil-works/pi-tui': await import(pathToFileURL(`${sdkPath}/../pi-tui/dist/index.js`)),
    'typebox': await import(pathToFileURL(require.resolve('typebox'))),
  },
});
const root = `${packagePath}/node_modules/@aliou/pi-processes`;
const { default: factory } = await jiti.import(`${root}/extensions/processes/index.ts`);
function harness() {
  const handlers = new Map(), tools = new Map(), sent = [];
  const pi = { events: sdk.createEventBus(), on: (name, fn) => {
    const group = handlers.get(name) ?? []; group.push(fn); handlers.set(name, group);
  }, registerTool: t => tools.set(t.name, t), registerCommand() {}, registerShortcut() {},
  registerMessageRenderer() {}, sendMessage: (m,o) => sent.push({m,o}) };
  const controller = new AbortController();
  const ctx = { cwd: process.cwd(), signal: controller.signal, hasUI: false };
  const emit = async (name, event = {}) => { for (const fn of handlers.get(name) ?? []) await fn(event,ctx); };
  return { pi, tools, sent, controller, ctx, emit };
}
const h = harness();
await factory(h.pi, true);
const tool = h.tools.get('process');
const call = args => tool.execute('test', args, h.ctx.signal, undefined, h.ctx);
try {
  const started = await call({action:'start', name:'held-child', command:'read line'});
  const id = started.details.process.id;
  let settled = false;
  const hold = h.emit('agent_end', { messages: [{role:'assistant',stopReason:'stop'}] }).then(() => { settled = true; });
  await checkpoint(); // one event-loop barrier, not a timed wait
  assert.equal(settled, false, 'Orchestrator agent_end must hold while its child waits for stdin');
  await call({action:'write', id, input:'done\n', end:true});
  await hold;
  assert.equal(h.sent.filter(x => x.o.triggerTurn).length, 1);
  console.log('PASS held child / native completion');
} finally { await h.emit('session_shutdown'); }

const { EventEmitter, once } = await import('node:events');
const { spawn } = await import('node:child_process');
const { existsSync } = await import('node:fs');
const { ProcessManager } = await jiti.import(`${root}/src/manager/index.ts`);
const { createNotificationService, createNotificationRegistry } = await jiti.import(`${root}/extensions/processes/notifications/service.ts`);
const { registerNotificationDelivery } = await jiti.import(`${root}/extensions/processes/handlers/notifications.ts`);
const { registerCleanupHook } = await jiti.import(`${root}/extensions/processes/hooks/cleanup.ts`);
const { registerProcessKeepalive } = await jiti.import(`${root}/extensions/processes/hooks/keepalive.ts`);
const { killIntentionally } = await jiti.import(`${root}/extensions/processes/handlers/kill-process.ts`);
const { CHANNELS } = await jiti.import(`${root}/extensions/shared/protocol/index.ts`);
const cleanups = new Set();
const watchdog = setTimeout(() => {
  for (const cleanup of cleanups) cleanup();
  console.error('FAIL test deadline (owned resources cleaned)'); process.exit(1);
}, 30000);
watchdog.unref();

class DeterministicManager {
  events = new EventEmitter(); records = new Map(); kills = 0; cleans = 0;
  onEvent(fn) { this.events.on('event', fn); return () => this.events.off('event',fn); }
  list() { return [...this.records.values()]; }
  get(id) { return this.records.get(id) ?? null; }
  emit(event) { this.events.emit('event',event); }
  start(id) {
    const info = {id,name:id,command:'fixture',pid:1,status:'running',startTime:1,endTime:null,exitCode:null};
    this.records.set(id,info); this.emit({type:'process_started',info}); return info;
  }
  end(id) {
    const info = {...this.get(id),status:'exited',exitCode:0,success:true,endReason:'exit',endTime:2};
    this.records.set(id,info); this.emit({type:'process_ended',info});
  }
  output(id) { this.emit({type:'process_output_changed', id, appendedText:[{type:'stdout',text:'READY'}]}); }
  async kill(id) { const info = {...this.get(id),status:'terminate_timeout'}; this.records.set(id,info); return {ok:false,reason:'timeout',info}; }
  killAll() { this.kills++; }
  cleanup() { this.cleans++; }
  stopWatcher() {}
}
function fixture(manager = new DeterministicManager(), beforeDelivery) {
  const h = harness(), registry = createNotificationRegistry();
  const service = createNotificationService({events:h.pi.events,manager,registry,getProcess:id=>manager.get(id)});
  beforeDelivery?.(h);
  let gate;
  const disposers = [registerNotificationDelivery(h.pi.events,h.pi,()=>gate.deliveredTurn())];
  const cleanup = registerCleanupHook(h.pi,{manager,notifications:registry,notificationService:service,disposers});
  gate = registerProcessKeepalive(h.pi,manager,cleanup);
  disposers.push(()=>gate.dispose());
  cleanups.add(cleanup);
  const close = () => {cleanup(); cleanups.delete(cleanup);};
  const end = (reason='stop') => h.emit('agent_end',{messages:[{role:'assistant',stopReason:reason}]});
  return {...h,manager,registry,close,end,gate};
}
async function test(name, fn) { await fn(); console.log(`PASS ${name}`); }
const wakeCount = f => f.sent.filter(x=>x.o.triggerTurn).length;
const pending = async promise => {
  let done=false; promise.then(()=>{done=true;}); await checkpoint(); assert.equal(done,false);
};
await test('immediate exit flushes deferred completion; simultaneous completions',async()=>{
  const f=fixture(); try {
    f.manager.start('a'); f.manager.start('b');
    f.manager.end('a'); f.manager.end('b');
    // Registry registration after synchronous end matches missing_pid ordering.
    f.registry.register('a',{onSuccess:'turn'}); f.registry.register('b',{onSuccess:'turn'});
    await f.end(); assert.equal(wakeCount(f),2);
    assert.equal(f.registry.get('a'),null); assert.equal(f.registry.get('b'),null);
  } finally {f.close();}
});
await test('wake before hook; readiness with live process; consumed at turn_start',async()=>{
  const f=fixture(); try {
    f.manager.start('a'); f.registry.register('a',{onSuccess:'context',logMatches:[{pattern:'READY',on:'turn'}]});
    f.manager.output('a'); await f.end(); assert.equal(wakeCount(f),1);
    assert.equal(f.manager.get('a').status,'running');
    await f.emit('turn_start'); const held=f.end(); await pending(held);
    f.manager.end('a'); await held; assert.equal(wakeCount(f),1);
    assert.equal(f.sent.at(-1).o.deliverAs,'nextTurn');
  } finally {f.close();}
});
await test('readiness while held releases AFTER native delivery with owned work live',async()=>{
  const f=fixture(); try {
    f.manager.start('a'); f.registry.register('a',{logMatches:[{pattern:'READY',on:'turn'}]});
    const held=f.end(); await pending(held);
    f.manager.output('a'); await held;
    assert.equal(wakeCount(f),1); assert.equal(f.manager.get('a').status,'running');
  } finally {f.close();}
});
for (const attention of ['context','ignore']) await test(`${attention}-only exit invents no turn`,async()=>{
  const f=fixture(); try {
    f.manager.start('a'); f.registry.register('a',{onSuccess:attention});
    const held=f.end(); await pending(held); f.manager.end('a'); await held;
    assert.equal(wakeCount(f),0); assert.equal(f.sent.length,attention==='ignore'?0:1);
  } finally {f.close();}
});
await test('stop timeout releases from actual kill promise, no process_ended',async()=>{
  const f=fixture(); try {
    f.manager.start('a'); f.registry.register('a',{});
    const held=f.end(); await pending(held);
    const result=await killIntentionally(f.manager,f.registry,'a');
    assert.equal(result.reason,'timeout'); await held; assert.equal(wakeCount(f),0);
    await f.emit('agent_settled'); assert.equal(f.manager.cleans,1);
    await f.emit('session_shutdown'); assert.equal(f.manager.cleans,1);
  } finally {f.close();}
});
await test('abort while held disables delivery and resolves waiters',async()=>{
  const f=fixture(); try {
    f.manager.start('a'); const held=f.end(); await pending(held);
    f.controller.abort(); f.manager.end('a'); await held;
    assert.equal(f.sent.length,0); assert.equal(f.manager.kills,1); assert.equal(f.manager.cleans,1);
  } finally {f.close();}
});
await test('error/aborted endings bypass hold; only terminal failure cleans',async()=>{
  for(const reason of ['error','aborted']) {
    const f=fixture(); try {
      f.manager.start('a'); await f.end(reason); assert.equal(f.manager.cleans,0);
      await f.emit('agent_settled'); assert.equal(f.manager.cleans,1);
    } finally {f.close();}
  }
  const f=fixture(); try {
    f.manager.start('a'); await f.end('error'); await f.emit('turn_start');
    const held=f.end(); await pending(held); f.manager.end('a'); await held;
    await f.emit('agent_settled'); assert.equal(f.manager.cleans,0);
  } finally {f.close();}
});
await test('shutdown during delivery (listener snapshot) cannot send or wake',async()=>{
  let f;
  f=fixture(undefined,h=>h.pi.events.on(CHANNELS.NOTIFICATION,()=>f.close()));
  f.manager.start('a'); const held=f.end(); await pending(held);
  f.manager.end('a'); await held;
  assert.equal(f.sent.length,0); assert.equal(f.manager.cleans,1);
});
await test('shutdown inside sendMessage cannot revive disposed gate',async()=>{
  const f=fixture();
  f.pi.sendMessage=()=>f.close();
  f.manager.start('a'); const held=f.end(); await pending(held);
  f.manager.end('a'); await held; assert.equal(f.manager.cleans,1);
});
await test('sibling ownership isolation',async()=>{
  const a=fixture(), b=fixture(); try {
    a.manager.start('same-id'); b.manager.start('same-id');
    const ah=a.end(), bh=b.end(); await pending(ah); await pending(bh);
    a.manager.end('same-id'); await ah; await pending(bh);
    a.close(); assert.equal(b.manager.kills,0);
    b.manager.end('same-id'); await bh; assert.equal(wakeCount(b),1);
  } finally {a.close();b.close();}
});
await test('real stop timeout cleanup kills owned child and removes logs',async()=>{
  const f=fixture(new ProcessManager());
  const child=spawn(process.execPath,['-e',`process.on('SIGTERM',()=>{}); process.stdin.resume(); console.log('READY')`],{detached:true,stdio:'pipe'});
  const closed=once(child,'close');
  try {
    const ready=once(child.stdout,'data');
    const info=f.manager.adopt('timeout','node fixture',process.cwd(),child);
    child.ref(); // Test owns the close-event assertion even after manager cleanup.
    f.registry.register(info.id,{}); await ready;
    const held=f.end(); await pending(held);
    const result=await killIntentionally(f.manager,f.registry,info.id,{timeoutMs:0});
    assert.equal(result.reason,'timeout'); await held; assert.equal(wakeCount(f),0);
    await f.emit('agent_settled'); await closed;
    assert.equal(existsSync(info.stdoutFile),false);
  } finally {f.close();}
});

await test('abort cleans timeout plus live child without rearming native watcher',async()=>{
  const f=fixture(new ProcessManager());
  const children=[];
  try {
    for(const name of ['timeout','live']) {
      const child=spawn(process.execPath,['-e',`process.on('SIGTERM',()=>{}); process.stdin.resume(); console.log('READY')`],{detached:true,stdio:'pipe'});
      const ready=once(child.stdout,'data'),closed=once(child,'close');
      const info=f.manager.adopt(name,'node fixture',process.cwd(),child);child.ref();
      children.push({child,closed,info});await ready;
    }
    await killIntentionally(f.manager,f.registry,children[0].info.id,{timeoutMs:0});
    const held=f.end();await pending(held);
    f.controller.abort();await held;
    await Promise.all(children.map(c=>c.closed));await checkpoint();
    assert.equal(f.manager.runtime.watcher,null,'cleanup must not rearm the native liveness timer');
  } finally {f.close();f.manager.stopWatcher();}
});

await test('real sibling entries isolate shared discovery bus and owned children',async()=>{
  const {default:orchestrator}=await jiti.import(`${packagePath}/orchestrator-processes/index.ts`);
  const a=harness(), b=harness();
  b.pi.events=a.pi.events; // Even when a caller shares a discovery bus.
  await orchestrator(a.pi); await orchestrator(b.pi);
  await a.emit('session_start'); await b.emit('session_start');
  const call=(h,args)=>h.tools.get('process').execute('sibling',args,h.ctx.signal,undefined,h.ctx);
  let ai,bi;
  try {
    ai=(await call(a,{action:'start',name:'a',command:'read line'})).details.process;
    bi=(await call(b,{action:'start',name:'b',command:'read line'})).details.process;
    spawnedChildren.get(ai.pid).child.ref(); spawnedChildren.get(bi.pid).child.ref();
    const ah=a.emit('agent_end',{messages:[]}),bh=b.emit('agent_end',{messages:[]});
    await pending(ah);await pending(bh);
    a.controller.abort();await ah;await spawnedChildren.get(ai.pid).closed;
    await pending(bh);process.kill(bi.pid,0);
    assert.equal(a.sent.length,0);assert.equal(b.sent.length,0);
    await call(b,{action:'write',id:bi.id,input:'done\n',end:true});await bh;
    assert.equal(b.sent.length,1);assert.equal(a.sent.length,0);
  } finally {
    await a.emit('session_shutdown');await b.emit('session_shutdown');
    if(ai)await spawnedChildren.get(ai.pid).closed;
    if(bi)await spawnedChildren.get(bi.pid).closed;
  }
});

const ai = await import(pathToFileURL(`${sdkPath}/../pi-ai/dist/compat.js`));
const { parseExtensionsSpec, extensionCanonicalNames, installExtensionToolScope } = await import(pathToFileURL(`${sdkPath}/../../@tintinweb/pi-subagents/dist/agent-runner.js`));
const entry = `${packagePath}/orchestrator-processes/index.ts`;
const oldEntry = `${root}/extensions/processes/index.ts`;
const spec = parseExtensionsSpec([entry],packagePath);
assert.deepEqual([...spec.names],['orchestrator-processes']);
assert.ok(extensionCanonicalNames(entry).includes('pi-processes'),'ext:pi-processes keeps its native selector identity');
assert.ok(!extensionCanonicalNames(oldEntry).some(n=>spec.names.has(n)),'absolute child entry must not retain ordinary process entry');
console.log('PASS installed custom-agent path injection / tool-selector identity');
const modelRuntime=await sdk.ModelRuntime.create({
  credentials:new ai.InMemoryCredentialStore(), modelsPath:null,
  modelsStorePath:`${packagePath}/test-models-store.json`, refreshOnCreate:false,
  allowModelNetwork:false,
});
const model=modelRuntime.getModels('anthropic')[0];
assert.ok(model);
await modelRuntime.setRuntimeApiKey(model.provider,'scripted-not-a-real-key');
// Fail closed if a fixture accidentally calls the provider instead of the script.
modelRuntime.streamSimple=()=>{throw new Error('Network/model calls forbidden in this test');};
function deferred() { let resolve; const promise=new Promise(r=>{resolve=r;}); return {resolve,promise}; }
function response(model, content, stopReason) {
  const message={role:'assistant',content,api:model.api,provider:model.provider,model:model.id,
    usage:{input:1,output:1,cacheRead:0,cacheWrite:0,totalTokens:2,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},
    stopReason,timestamp:Date.now(),...(stopReason==='error'?{errorMessage:'scripted terminal failure'}:{})};
  const stream=new ai.AssistantMessageEventStream();
  stream.push({type:'start',partial:message});
  if(stopReason==='error') stream.push({type:'error',reason:'error',error:message});
  else stream.push({type:'done',reason:stopReason,message});
  return stream;
}
async function sdkCase(mode) {
  const rootMode=mode==='root';
  const settings=sdk.SettingsManager.inMemory({
    extensions:[rootMode?oldEntry:`${installedPath}/node_modules/@aliou/pi-processes/extensions/processes/index.ts`], compaction:{enabled:false},retry:{enabled:false},
  });
  const loader=new sdk.DefaultResourceLoader({cwd:packagePath,agentDir:`${packagePath}/empty-agent`,
    settingsManager:settings, additionalExtensionPaths:rootMode?[]:spec.paths,
    noSkills:true,noPromptTemplates:true,noThemes:true,noContextFiles:true,
    systemPromptOverride:()=> 'Scripted lifecycle regression.',
    extensionsOverride:base=>({...base,extensions:base.extensions.filter(e=>
      rootMode?e.path===oldEntry:extensionCanonicalNames(e.path).some(n=>spec.names.has(n)))}),
  });
  await loader.reload();
  assert.deepEqual(loader.getExtensions().errors,[]);
  assert.deepEqual(loader.getExtensions().extensions.map(e=>e.path),[rootMode?oldEntry:entry]);
  const {session}=await sdk.createAgentSession({cwd:packagePath,agentDir:`${packagePath}/empty-agent`,
    resourceLoader:loader,modelRuntime,model,thinkingLevel:'off',
    excludeTools:['read','bash','grep','find','ls','edit','write'],
    sessionManager:sdk.SessionManager.inMemory(packagePath),settingsManager:settings});
  const errors=[];
  await session.bindExtensions({onError:e=>errors.push(e)});
  installExtensionToolScope(session,{loader,toolNames:[],extNames:new Set(['pi-processes']),
    narrowing:new Map(),readmitToolNames:new Set()});
  assert.deepEqual(session.getActiveToolNames(),['process'],'installed subagent scope admits late process tool');
  const cleanup=()=>{void session.extensionRunner.emit({type:'session_shutdown',reason:'quit'});};
  cleanups.add(cleanup);
  let calls=0,info,settled=false;
  const initialEnd=deferred();
  session.subscribe(e=>{
    if(process.env.PI_TEST_DEBUG) console.error(mode, e.type, e.result?.details, e.message?.errorMessage);
    if(e.type==='tool_execution_end' && e.result?.details?.action==='start') info=e.result.details.process;
    if(e.type==='turn_end' && calls===2) initialEnd.resolve();
  });
  session.agent.streamFunction=(model,context)=>{
    calls++;
    if(process.env.PI_TEST_DEBUG) console.error("MODEL", mode, calls);
    if(calls===1) return response(model,[{type:'toolCall',id:'start',name:'process',arguments:{
      action:'start',name:'sdk-child',
      command:mode==='readiness'?"read line; printf 'READY\\n'; read line":'read line',
      notify:mode==='readiness'?{onSuccess:'context',logMatches:[{pattern:'READY',on:'turn'}]}:{onSuccess:'turn'},
    }}],'toolUse');
    if(calls===2) return response(model,[{type:'text',text:'Initial response; waiting for native process result.'}],mode==='failure'?'error':'stop');
    if(mode==='readiness') {
      if(calls===3) {
        assert.match(JSON.stringify(context.messages),/READY/);
        process.kill(info.pid,0); // Native readiness must resume with the server still alive.
        return response(model,[{type:'toolCall',id:'finish',name:'process',arguments:{
          action:'write',id:info.id,input:'finish\n',end:true,
        }}],'toolUse');
      }
      assert.equal(calls,4);
      return response(model,[{type:'text',text:'Final response after native readiness.'}],'stop');
    }
    assert.equal(calls,3,'only native wake may cause continuation');
    assert.match(JSON.stringify(context.messages),/succeeded/,'continuation receives native process notification');
    return response(model,[{type:'text',text:'Final response after native completion.'}],'stop');
  };
  try {
    const prompt=session.prompt('Run the scripted child.').then(()=>{settled=true;});
    await initialEnd.promise;
    assert.ok(info?.pid>0);
    const ownedChild=spawnedChildren.get(info.pid);
    assert.ok(ownedChild, 'captured actual native process child');
    ownedChild.child.ref();
    if(rootMode || mode==='failure') {
      await prompt; assert.equal(calls,2);
      if(rootMode) {process.kill(info.pid,0);assert.equal(existsSync(info.stdoutFile),true);}
      if(mode==='failure') {
        await ownedChild.closed;
        assert.equal(existsSync(info.stdoutFile),false,'terminal failure cleans logs');
      }
    } else {
      await pending(prompt);
      assert.equal(session.isStreaming,true);
      assert.equal(session.agent.signal?.aborted,false,'hold has the active SDK signal');
      if(mode==='abort') {
        const abortedAt=performance.now();
        await session.abort(); await prompt;
        assert.ok(performance.now()-abortedAt<1000,'cancellation must settle promptly');
        await ownedChild.closed;
        assert.equal(calls,2); assert.equal(existsSync(info.stdoutFile),false);
      } else {
        const processTool=session.agent.state.tools.find(t=>t.name==='process');
        await processTool.execute('release',{action:'write',id:info.id,input:'complete\n',end:mode!=='readiness'},session.agent.signal);
        await prompt;
        assert.equal(calls,mode==='readiness'?4:3);
        assert.equal(session.messages.at(-1).content[0].text,mode==='readiness'?
          'Final response after native readiness.':'Final response after native completion.');
        assert.equal(session.messages.filter(m=>m.role==='custom'&&m.customType==='ad-process:notification').length,1,'excluded root factory must not duplicate native delivery');
      }
    }
    assert.equal(settled,true); assert.deepEqual(errors,[]);
  } finally {
    await session.extensionRunner.emit({type:'session_shutdown',reason:'quit'});
    session.dispose(); cleanups.delete(cleanup);
    if(info) await spawnedChildren.get(info.pid).closed;
  }
}
for(const mode of ['complete','readiness','root','abort','failure']) await test(`real installed SDK prompt: ${mode}`,()=>sdkCase(mode));
clearTimeout(watchdog);

childProcessModule.spawn=originalSpawn;
syncBuiltinESMExports();
