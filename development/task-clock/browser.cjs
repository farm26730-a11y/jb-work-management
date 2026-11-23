const assert=require('node:assert/strict');
const {execFileSync}=require('node:child_process');
const {readFileSync,readdirSync}=require('node:fs');
const {pathToFileURL}=require('node:url');
const {chromium,devices,expect}=require('playwright/test');
const root=require('node:path').resolve(__dirname,'../..');
const path=readdirSync(root).find(p=>p.startsWith('JB_'))+'/index.html';
const baseline=execFileSync('git',['show','4ef6354:'+path],{cwd:root,maxBuffer:4e6});
const fixed=readFileSync(root+'/'+path);
const origin='http://jb.localhost';
const clockHandler=import(pathToFileURL(root+'/'+path.replace('index.html','netlify/functions/task-clock-time.mjs')));
const stub=`
window.supabase={createClient(){
 const role=()=>localStorage.getItem('test-role');
 function query(table){
  const q={table,filters:{},offset:0,limit:5000};
  const chain={
   select:()=>chain,order:()=>chain,in(key,vals){q.filters[key]=vals;return chain},is:()=>chain,gte:()=>chain,lt:()=>chain,lte:()=>chain,
   eq(key,val){q.filters[key]=val;return chain},
   limit(n){q.limit=n;return chain},
   range(a,b){q.offset=a;q.limit=b-a+1;return chain},
   maybeSingle(){q.single=true;return chain},single(){q.single=true;return chain},
   then(ok,bad){return window.testBackend(role(),q).then(ok,bad)}
  };
  return chain;
 }
 return {from:query,rpc:(name,args)=>window.testBackend(role(),{name,args}),auth:{
  getSession:async()=>({data:{session:role()?{user:{id:role()}}:null}}),
  getUser:async()=>({data:{user:role()?{id:role()}:null}}),
  signInWithPassword:async({email})=>{localStorage.setItem('test-role',email.split('@')[0]);return {}},
  signOut:async()=>{localStorage.removeItem('test-role');return {}}
 }};
}};
`;
const options={timeout:4500};
async function scenario(browser,{role,mobile,base=false,cap=false}){
 const ctx=await browser.newContext(mobile?devices['Pixel 7']:{viewport:{width:1380,height:920}});
 try {
 const page=await ctx.newPage();
 const errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 await ctx.addInitScript(skew=>{
  localStorage.setItem('JB_V53_SUPABASE_PUBLIC_CONFIG',JSON.stringify({url:'https://fixture.supabase.co',key:'sb_publishable_fixture'}));
  const nativeNow=Date.now;
  Date.now=()=>nativeNow()+skew;
 },base?0:mobile?3600000:-3600000);
 const now=Date.now();
 const iso=t=>new Date(t).toISOString();
 const employees=['owner','manager','staff','other'].map((id,i)=>({id,name:id,app_role:id==='other'?'staff':id,department_id:i===3?'elsewhere':'dept',active:true}));
 const task={id:'subject',title:'Clock fixture',status:base?'in_progress':'planned',created_at:iso(now-60000),assignee_id:role,created_by:role,department_id:'dept'};
 const foreign={...task,id:'foreign',title:'Foreign fixture',status:'planned',assignee_id:'other',department_id:'elsewhere'};
 const older={...task,id:'older',title:'Older fixture',status:'planned'};
 const dummy=Array.from({length:5101},(_,id)=>({id,task_id:'older',previous_status:'planned',new_status:'planned',changed_at:iso(now-59000+id)}));
 const history=base&&!cap?[]:[...dummy];
 if(base)history.push({id:'initial',task_id:task.id,previous_status:'planned',new_status:'in_progress',changed_at:iso(now-10000)});
 let historyError=false, omitHistory=false, staleStatus=false, rpcFailure=false, rpcDelay=0;
 let rpcCalls=0;
 const additional=[];
 const saveStatus=(target,status,changed_at)=>{
  if(target.status===status)return;
  history.push({id:'transition-'+history.length,task_id:target.id,previous_status:target.status,new_status:status,changed_at});
  target.status=status;
  if(status==='completed')target.completed_at=changed_at;
 };
 const offsets=[];
 await ctx.exposeBinding('testBackend',async (_,identity,q)=>{
  const result=data=>({data,error:null});
  if(q.name==='jb_set_task_status_exclusive'){
   assert.equal(identity,role);
   rpcCalls++;
   if(rpcDelay)await new Promise(resolve=>setTimeout(resolve,rpcDelay));
   if(rpcFailure)return {error:{message:'fixture network failure'}};
   const target=[task,older,...additional].find(t=>t.id===q.args.p_task_id);
   assert(target);
   const status=q.args.p_new_status,changed_at=iso(Date.now());
   if(status==='in_progress'){
    for(const t of [task,older,...additional]){
     if(t!==target&&t.assignee_id===target.assignee_id&&t.status==='in_progress')saveStatus(t,'hold',changed_at);
    }
   }
   saveStatus(target,status,changed_at);
   return result(null);
  }
  if(q.name==='jb_public_staff_directory') return result(employees);
  if(q.name==='jb_annual_leave_auto_overview_v13') return result({items:[]});
  if(q.name) return result([]);
  const {table,filters,offset,limit,single}=q;
  let rows=[];
  if(table==='jb_employees')rows=filters.auth_user_id?employees.filter(e=>e.id===identity):employees;
  if(table==='jb_departments')rows=[{id:'dept',name:'Fixture dept'},{id:'elsewhere',name:'Other dept'}];
  if(table==='jb_tasks')rows=identity==='owner'?[task,older,foreign,...additional]:[task,older];
  if(table==='jb_task_history'){
   if(historyError)return {data:null,error:{message:'fixture unavailable'}};
   if(Array.isArray(filters.task_id)&&filters.task_id.includes('subject'))offsets.push(offset);
   rows=omitHistory?[]:staleStatus?history.slice(0,-1):history;
  }
  rows=rows.filter(r=>Object.entries(filters).every(([k,v])=>k==='auth_user_id'||(Array.isArray(v)?v.includes(r[k]):r[k]===v)));
  if(single)return result(rows[0]||null);
  return result(rows.slice(offset,offset+Math.min(limit,table==='jb_task_history'&&!base?400:5000)));
 });
 await ctx.route('**/*',async route=>{
  const u=new URL(route.request().url());
  if(u.hostname==='cdn.jsdelivr.net')return route.fulfill({contentType:'application/javascript',body:stub});
  if(u.origin===origin&&u.pathname==='/.netlify/functions/task-clock-time'){
   const response=await (await clockHandler).default(new Request(u));
   return route.fulfill({status:response.status,headers:Object.fromEntries(response.headers),body:await response.text()});
  }
  if(u.origin===origin&&u.pathname==='/')return route.fulfill({contentType:'text/html',body:base?baseline:fixed});
  if(u.origin===origin)return route.fulfill({status:404,body:''});
  return route.abort();
 });
 async function login(){
  await page.locator('#srvEmail').fill(role+'@example.test');
  await page.locator('#srvPassword').fill('test-password');
  await page.locator('#srvLogin').click();
  await page.locator('#srvLogout').waitFor(options);
 }
 async function tab(name){
  const button=page.locator('[data-view="'+name+'"]:visible').first();
  if(!await button.count())await page.locator('#srvMobileMore').click();
  await button.click(options);
 }
 const clock=(kind='running')=>page.locator('[data-clock-task=subject] [data-clock-'+kind+']');
 const values=async(kind)=>clock(kind).allTextContents();
 const same=async(kind)=>{const list=await values(kind);assert(list.length>=2);assert.equal(new Set(list).size,1);return list[0]};
 const seconds=s=>s.split(':').reduce((n,v)=>n*60+Number(v),0);
 const waitChange=(kind,old)=>expect.poll(async()=>seconds((await values(kind))[0]||'0'),options).toBeGreaterThan(seconds(old));
 const taskSelect=page.locator('.srv-status[data-task=subject]');
 async function transition(status){
  await taskSelect.selectOption(status);
  if(status==='completed')await expect(taskSelect).toHaveCount(0,options);
  else await expect(page.locator('.srv-my-task-card[data-task-status='+status+'] '+'.srv-status[data-task=subject]')).toHaveValue(status,options);
 }
 await page.goto(origin);
 await login();
 if(base&&cap){
  await tab('tasks');
  await expect(page.getByText('과거 상태 변경 이력이 부족해 누적 시간을 확정할 수 없습니다.')).toBeVisible(options);
  assert.equal(await clock().count(),0);
  console.log('main: reproduced a missing latest transition after the 5,000-row limit');
  return;
 }
 if(base){
  await page.locator('.srv-current-title[data-task-id=subject]').click();
  await clock().first().waitFor(options);
  const first=await clock().first().textContent();
  await page.waitForTimeout(1350);
  assert.equal(await clock().first().textContent(),first);
  await tab('tasks');
  const previous=await clock().first().textContent();
  await waitChange('running',previous);
  console.log('main: reproduced frozen home detail and ticking Tasks tab');
  return;
 }
 await page.locator('.srv-home-person-tasks[data-employee='+role+']').click();
 await page.locator('.srv-home-task-detail[data-task-id=subject]').click();
 assert.equal(await same('running'),'00:00:00');
 assert.equal(await page.getByText('Foreign fixture',{exact:true}).count(),0);
 if(role==='owner'){
  await page.locator('.srv-home-person-tasks[data-employee=other]').click();
  await expect(page.getByText('Foreign fixture',{exact:true})).toBeVisible(options);
  await page.locator('.srv-home-task-detail[data-task-id=foreign]').click();
  assert.equal(await page.locator('.srv-home-status[data-task=foreign]').count(),0);
 }else{
  await page.locator('.srv-home-person-tasks[data-employee=other]').click();
  await expect(page.getByText('Foreign fixture',{exact:true})).toHaveCount(0,options);
 }
 await tab('tasks');
 await transition('in_progress');
 await waitChange('running','00:00:00');
 await tab('home');
 await page.locator('.srv-current-title[data-task-id=subject]').click();
 const home=await same('running');
 await waitChange('running',home);
 assert(seconds(await same('running'))>seconds(home));
 await tab('tasks');
 await page.locator('.srv-task-detail[data-id=subject]').click();
 assert(seconds(await same('running'))>=seconds(home));
 assert(seconds((await values('running'))[0])<60,'browser clock skew must not set live elapsed time');
 await transition('hold');
 const running=await same('running');
 await waitChange('holding','00:00:00');
 assert.equal(await same('running'),running);
 await page.reload();
 await page.locator('#srvLogout').waitFor(options);
 await tab('tasks');
 await expect(clock()).toHaveText(running,options);
 await tab('home');
 await tab('tasks');
 await expect(clock()).toHaveText(running,options);
 await page.locator('#srvLogout').click();
 await login();
 await tab('tasks');
 await expect(clock()).toHaveText(running,options);
 await transition('in_progress');
 await waitChange('running',running);
 const holding=await clock('holding').textContent();
 await transition('completed');
 await tab('archive');
 await page.locator('.srv-archive-detail-toggle[data-id=subject]').click(options);
 const archive=page.locator('.jb-archive-details .srv-clock');
 await expect(archive).toBeVisible(options);
 const finished=await clock().textContent();
 assert(seconds(finished)>seconds(running));
 const [start,pause,resume,complete]=history.filter(row=>String(row.id).startsWith('transition-')).map(row=>Date.parse(row.changed_at));
 assert.equal(seconds(finished),Math.floor((pause-start+complete-resume)/1000));
 assert.equal(seconds(await clock('holding').textContent()),Math.floor((resume-pause)/1000));
 assert(seconds(await clock('holding').textContent())>=seconds(holding));
 await page.waitForTimeout(1100);
 assert.equal(await clock().textContent(),finished);
 assert(offsets.includes(800)&&offsets.some(offset=>offset>=5101),JSON.stringify(offsets));
 if(role==='owner'&&!mobile){
  const downloadPromise=page.waitForEvent('download');
  await page.locator('[data-srv-archive-export=month]').click();
  const csv=readFileSync(await (await downloadPromise).path(),'utf8');
  assert(csv.includes('"진행 누적","보류 누적","시간 확인 상태"'));
  assert(csv.includes('"'+finished+'","'+await clock('holding').textContent()+'","확인"'));
  const holdValue=await clock('holding').textContent();
  await tab('home');
  const reportPromise=page.waitForEvent('download');
  await page.locator('#srvReportCsv').click();
  const report=readFileSync(await (await reportPromise).path(),'utf8');
  assert(report.includes('"'+finished+'","'+holdValue+'","0"'));
  await tab('archive');
  await page.locator('.srv-archive-detail-toggle[data-id=subject]').waitFor(options);
  if(!await page.locator('.jb-archive-details').count())await page.locator('.srv-archive-detail-toggle[data-id=subject]').click();
  await page.locator('.srv-archive-detail-toggle[data-id=subject]').click();
  historyError=true;
  await page.locator('.srv-archive-detail-toggle[data-id=subject]').click();
  await expect(page.locator('.jb-archive-details')).toContainText('업무 상태 이력을 조회하지 못했습니다',options);
  await page.locator('.srv-archive-detail-toggle[data-id=subject]').click();
  historyError=false;omitHistory=true;
  await page.locator('.srv-archive-detail-toggle[data-id=subject]').click();
  await expect(page.locator('.jb-archive-details')).toContainText('저장된 업무 상태 변경 이력이 없어',options);
  await page.locator('.srv-archive-detail-toggle[data-id=subject]').click();
  omitHistory=false;staleStatus=true;
  await page.locator('.srv-archive-detail-toggle[data-id=subject]').click();
  await expect(page.locator('.jb-archive-details')).toContainText('마지막 변경 이력이 일치하지 않습니다',options);
  staleStatus=false;
  additional.push({...older,id:'second',title:'Second fixture'});
  await page.reload();
  await page.locator('#srvLogout').waitFor(options);
  await tab('tasks');
  const olderSelect=page.locator('.srv-status[data-task=older]');
  const secondSelect=page.locator('.srv-status[data-task=second]');
  await olderSelect.selectOption('in_progress');
  await expect.poll(()=>older.status,options).toBe('in_progress');
  const olderClock=page.locator('[data-clock-task=older] [data-clock-running]');
  await expect.poll(async()=>seconds(await olderClock.textContent()),options).toBeGreaterThan(0);
  rpcDelay=350;
  const before=rpcCalls;
  await secondSelect.selectOption('in_progress');
  await expect(olderSelect).toBeDisabled(options);
  await secondSelect.evaluate(el=>el.dispatchEvent(new Event('change')));
  await expect.poll(()=>older.status,options).toBe('hold');
  await expect(olderSelect).toHaveValue('hold',options);
  assert.equal(rpcCalls,before+1);
  const autoHold=history.slice(-2);
  assert.deepEqual(autoHold.map(h=>[h.task_id,h.previous_status,h.new_status]),[
   ['older','in_progress','hold'],['second','planned','in_progress']
  ]);
  assert.equal(autoHold[0].changed_at,autoHold[1].changed_at);
  const held=await olderClock.textContent();
  assert(seconds(held)>0);
  const alert=page.waitForEvent('dialog').then(dialog=>dialog.accept());
  rpcFailure=true;
  await secondSelect.selectOption('planned');
  await alert;
  await expect(secondSelect).toHaveValue('in_progress',options);
  await expect(secondSelect).toBeEnabled(options);
  assert.equal(additional[0].status,'in_progress');
  rpcFailure=false;rpcDelay=0;
  await secondSelect.selectOption('planned');
  await expect.poll(()=>additional[0].status,options).toBe('planned');
  await expect(secondSelect).toHaveValue('planned',options);
  assert.deepEqual(history.slice(-1).map(h=>[h.previous_status,h.new_status]),[['in_progress','planned']]);
  assert.equal(await olderClock.textContent(),held);
 }
 assert.deepEqual(errors,[]);
 console.log(role,mobile?'mobile':'desktop','PASS',running,holding,finished);
 }finally{await ctx.close()}
}
(async()=>{const browser=await chromium.launch({executablePath:'/usr/bin/chromium',args:['--no-sandbox']});try{
 if(process.argv.includes('main')){
  await scenario(browser,{role:'staff',mobile:false,base:true});
  await scenario(browser,{role:'staff',mobile:false,base:true,cap:true});
 }
 else {
  const matrix=['owner','manager','staff'].flatMap(role=>[false,true].map(mobile=>({role,mobile})));
  const results=await Promise.allSettled(matrix.map(c=>scenario(browser,c)));
  for(const [i,res] of results.entries())if(res.status==='rejected'){console.error(matrix[i],res.reason);process.exitCode=1}
 }
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
