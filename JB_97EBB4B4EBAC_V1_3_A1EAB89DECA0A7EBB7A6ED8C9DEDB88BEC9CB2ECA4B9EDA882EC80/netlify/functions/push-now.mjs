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
 if(!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(eventId)||!['comment','task'].includes(type))return new Response('',{status:400});
 try{
  const db=createPushServer();
  const {data:auth,error:authError}=await db.auth.getUser(token);
  if(authError||!auth?.user?.id)return new Response('',{status:401});
  const {data:worker,error:workerError}=await db.from('jb_employees')
   .select('id').eq('auth_user_id',auth.user.id).eq('active',true).maybeSingle();
  if(workerError||!worker)return new Response('',{status:403});
  const sourceTable=type==='comment'?'jb_task_comments':'jb_tasks';
  const authorField=type==='comment'?'author_id':'created_by';
  const {data:eventRow,error:eventError}=await db.from(sourceTable)
   .select('id').eq('id',eventId).eq(authorField,worker.id).maybeSingle();
  if(eventError||!eventRow)return new Response('',{status:403});
  const {data:jobs,error:jobsError}=await db.from('jb_push_outbox')
   .select('id,event_key,employee_id,event_type,created_at,sent_at,attempts,last_error')
   .eq('event_key',type+':'+eventId).eq('event_type',type)
   .is('sent_at',null).lt('attempts',5)
   .gte('created_at',new Date(Date.now()-120000).toISOString())
   .limit(5);
  if(jobsError)throw jobsError;
  for(const job of jobs||[])await deliverQueuedPush(db,job);
  return new Response(null,{status:204});
 }catch(error){
  console.error('JB immediate push dispatch:',String(error?.message||error));
  return new Response('',{status:503});
 }
};
export const config={method:'POST',rateLimit:{windowLimit:90,windowSize:60,aggregateBy:['ip','domain']}};
