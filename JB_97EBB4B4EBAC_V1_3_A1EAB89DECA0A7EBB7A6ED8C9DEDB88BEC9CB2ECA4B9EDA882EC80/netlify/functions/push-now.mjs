import {createPushServer,deliverQueuedPush} from '../lib/push-core.mjs';

// Authenticated immediate delivery for a just-created comment or task.
// Every event must be backed by a real DB record authored by the caller.
// The one-minute scheduled dispatcher is the reliable fallback.
export default async request=>{
 if(request.method!=='POST')return new Response('',{status:405});
 const token=/^Bearer\s+(.+)$/i.exec(request.headers.get('authorization')||'')?.[1];
 if(!token)return new Response('',{status:401});
 let payload;
 try{payload=await request.json()}catch(_){return new Response('',{status:400})}
 const eventId=String(payload?.eventId||'');
 const type=String(payload?.type||'');
 if(!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(eventId)||!['comment','task','report'].includes(type))return new Response('',{status:400});
 try{
  const db=createPushServer();
  const {data:auth,error:authError}=await db.auth.getUser(token);
  if(authError||!auth?.user?.id)return new Response('',{status:401});
  const {data:worker,error:workerError}=await db.from('jb_employees')
   .select('id').eq('auth_user_id',auth.user.id).eq('active',true).maybeSingle();
  if(workerError||!worker)return new Response('',{status:403});
  const recentSince=new Date(Date.now()-120000).toISOString();
  let eventKeys;
  if(type==='report'){
   // Report RPCs return either a request ID or void; the task ID is stable.
   // Verify the author's recent report comment and server-side request.
   const {data:requests,error:requestError}=await db.from('jb_task_report_requests')
    .select('id,note,created_at').eq('task_id',eventId).eq('requester_id',worker.id)
    .order('created_at',{ascending:false}).limit(10);
   if(requestError||!requests?.length)return new Response('',{status:403});
   const {data:comments,error:commentError}=await db.from('jb_task_comments')
    .select('id,body,created_at').eq('task_id',eventId).eq('author_id',worker.id)
    .gte('created_at',recentSince).order('created_at',{ascending:false}).limit(20);
   if(commentError)return new Response('',{status:503});
   const validComments=(comments||[]).filter(c=>requests.some(r=>r.note===c.body));
   if(!validComments.length)return new Response('',{status:403});
   // First report request + comment share one transaction timestamp.
   // Do not wake unrelated old reports for the same task.
   const freshRequestIds=requests.filter(r=>validComments.some(c=>
    r.note===c.body&&new Date(r.created_at).getTime()===new Date(c.created_at).getTime()
   )).map(r=>'report:'+r.id);
   // Re-report events have comment-specific keys.
   eventKeys=[...new Set([
    ...freshRequestIds,
    ...validComments.map(c=>'report:comment:'+c.id)
   ])];
  }else{
   const sourceTable=type==='comment'?'jb_task_comments':'jb_tasks';
   const authorField=type==='comment'?'author_id':'created_by';
   const {data:eventRow,error:eventError}=await db.from(sourceTable)
    .select('id').eq('id',eventId).eq(authorField,worker.id).maybeSingle();
   if(eventError||!eventRow)return new Response('',{status:403});
   eventKeys=[type+':'+eventId];
  }
  const {data:jobs,error:jobsError}=await db.from('jb_push_outbox')
   .select('id,event_key,employee_id,event_type,created_at,sent_at,attempts,last_error')
   .in('event_key',eventKeys).eq('event_type',type)
   .is('sent_at',null).lt('attempts',5)
   .gte('created_at',recentSince)
   .limit(30);
  if(jobsError)throw jobsError;
  const outcomes=[];
  for(const job of jobs||[])outcomes.push(await deliverQueuedPush(db,job));
  // 204 means every selected queue item was actually delivered.
  // 202 means queued, in progress, skipped or failed; scheduled fallback remains.
  const fullySent=outcomes.length>0&&outcomes.every(outcome=>outcome==='sent');
  return new Response(null,{status:fullySent?204:202});
 }catch(error){
  console.error('JB immediate push dispatch:',String(error?.message||error));
  return new Response('',{status:503});
 }
};
export const config={method:'POST',rateLimit:{windowLimit:90,windowSize:60,aggregateBy:['ip','domain']}};
