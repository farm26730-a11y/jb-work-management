const assert = require('node:assert/strict');
const {readdirSync, readFileSync} = require('node:fs');
const {resolve} = require('node:path');
const {pathToFileURL} = require('node:url');
const {test} = require('node:test');
const vm = require('node:vm');

const root = resolve(__dirname, '../..');
const app = resolve(root, readdirSync(root).find(name => name.startsWith('JB_')));
const html = readFileSync(resolve(app, 'index.html'), 'utf8');
const handlers = html.slice(html.indexOf('async function loadTaskHistory('), html.indexOf('function resetTaskPhoto('));
const origin = Date.parse('2026-11-22T14:59:55Z');
const at = seconds => new Date(origin + seconds * 1000).toISOString();
const transition = (previous_status, new_status, seconds) => ({previous_status,new_status,changed_at:at(seconds)});

function loadClock(supa) {
 const records = {taskHistory:new Map()};
 const context = vm.createContext({records,supa,window:{},setInterval(){},performance:{now:()=>0}});
 return {records,...vm.runInContext(handlers+'\n({taskClock,loadTaskHistories,durationLabel})',context)};
}

test('recorded UTC transitions cross Seoul midnight, stop while held and resume after a reopen',()=>{
 const {taskClock,durationLabel}=loadClock();
 const task={id:'task',created_at:at(0),status:'completed'};
 const history=[
  transition('planned','in_progress',1),transition('in_progress','hold',4),
  transition('hold','in_progress',8),transition('in_progress','planned',11),
  transition('planned','in_progress',14),transition('in_progress','completed',18),
 ];
 const completed=taskClock(task,origin+30000,history,null);
 assert.equal(durationLabel(completed.running),'00:00:10');
 assert.equal(durationLabel(completed.holding),'00:00:04');
 assert.equal(taskClock(task,origin+86400000,history,null).running,completed.running);
 history.push(transition('completed','in_progress',20));
 task.status='in_progress';
 assert.equal(taskClock(task,origin+25000,history,null).running,15000);
 assert.equal(taskClock(task,origin-999999,history,null).running,10000);
});

test('empty, malformed, mismatched and rejected histories have distinct outcomes',()=>{
 const {taskClock}=loadClock();
 const task={id:'task',created_at:at(0),status:'in_progress'};
 assert.equal(taskClock(task,origin,[],null).reason,'missing');
 assert.equal(taskClock(task,origin,[],new Error()).reason,'query');
 assert.equal(taskClock(task,origin,[transition('hold','in_progress',1)]).reason,'invalid');
 assert.equal(taskClock(task,origin,[transition('planned','hold',1)]).reason,'mismatch');
 assert.equal(taskClock(task,origin,[transition('planned','in_progress',-1)]).reason,'invalid');
 assert.equal(taskClock(task,origin,[transition('planned','in_progress',1),transition('planned','in_progress',1)]).reason,'invalid');
});

test('history pagination crosses 5,000 rows, keeps tasks separate and rejects a failed later page',async()=>{
 const rows=Array.from({length:5101},(_,id)=>({id,task_id:'old',...transition('planned','planned',id+1)}));
 rows.push({id:5101,task_id:'new',...transition('planned','in_progress',5200)});
 rows.push({id:5102,task_id:'not-visible',...transition('planned','in_progress',5300)});
 let fail=false;
 const supa={from(table){
  assert.equal(table,'jb_task_history');
  let match;
  const builder={select:()=>builder,in(_,ids){match=rows.filter(row=>ids.includes(row.task_id));return builder},
   order:()=>builder,range(offset){return fail&&offset===3000
    ?{error:new Error('second half unavailable')}:{data:match.slice(offset,offset+300)}}
  };
  return builder;
 }};
 const {loadTaskHistories}=loadClock(supa);
 const tasks=[{id:'old'},{id:'new'}];
 const result=await loadTaskHistories(tasks);
 assert.equal(result.byTask.get('old').length,5101);
 assert.equal(result.byTask.get('new')[0].id,5101);
 assert.equal(result.byTask.has('not-visible'),false);
 fail=true;
 const partial=await loadTaskHistories(tasks);
 assert.equal(partial.byTask.size,0);
 assert.match(partial.error.message,/unavailable/);
});

test('server clock HTTP handler reports time without caching and rejects writes',async()=>{
 const {default: handler}=await import(pathToFileURL(resolve(app,'netlify/functions/task-clock-time.mjs')));
 const req=new Request('http://localhost');
 const before=Date.now();
 const response=handler(req);
 assert.equal(response.status,200);
 assert.equal(response.headers.get('cache-control'),'no-store');
 const {now}=await response.json();
 assert(now>=before&&now<=Date.now());
 assert.equal(handler(new Request(req,{method:'POST'})).status,405);
});
