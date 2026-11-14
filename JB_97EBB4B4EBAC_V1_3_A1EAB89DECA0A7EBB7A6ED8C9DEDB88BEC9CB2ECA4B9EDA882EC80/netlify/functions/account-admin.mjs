import {createClient} from '@supabase/supabase-js';

// V1.3 시험용: 직원 계정 관리. 항상 Supabase Auth JWT 및 서버 직원 권한 재검사.
// SERVICE_ROLE_KEY는 Netlify 서버에서만 사용하며 브라우저로 절대 전달하지 않는다.
const send=(data,status=200)=>new Response(JSON.stringify(data),{
 status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store'}
});
const uuid=s=>typeof s==='string'&&/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(s);
const fail=(message,status=400)=>send({error:message},status);
function initServer(){
 const {SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY}=process.env;
 if(!SUPABASE_URL||!SUPABASE_SERVICE_ROLE_KEY)throw new Error('Netlify Auth 서버 설정 누락');
 return createClient(SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,{
  auth:{persistSession:false,autoRefreshToken:false}
 });
}
async function getOperator(db,request){
 const token=/^Bearer\s+(.+)$/i.exec(request.headers.get('authorization')||'')?.[1];
 if(!token)return null;
 const {data,error}=await db.auth.getUser(token);
 if(error||!data?.user?.id)return null;
 const {data:staff,error:profileError}=await db.from('jb_employees')
  .select('id,app_role,active,auth_user_id,department_id').eq('auth_user_id',data.user.id)
  .eq('active',true).maybeSingle();
 if(profileError||!staff||!['owner','manager'].includes(staff.app_role))return null;
 return staff;
}
async function getAccounts(db){
 const all=[];
 for(let page=1;page<=5;page++){
  const {data,error}=await db.auth.admin.listUsers({page,perPage:200});
  if(error)throw error;
  const users=data?.users||[];
  all.push(...users);
  if(users.length<200)return all;
 }
 throw new Error('회원가입 계정이 1,000건을 초과합니다. 페이지 처리 점검이 필요합니다.');
}
async function lookupEmployee(db,userId){
 const {data,error}=await db.from('jb_employees')
  .select('id,name,position,department_id,app_role,active,auth_user_id')
  .eq('auth_user_id',userId).maybeSingle();
 if(error)throw error;
 return data;
}
function targetAllowed(actor,employee){
 return !employee||(
  employee.id!==actor.id&&employee.app_role!=='owner'&&
  (actor.app_role==='owner'||(employee.app_role==='staff'&&
   actor.department_id&&employee.department_id===actor.department_id))
 );
}
export default async request=>{
 if(!['GET','POST'].includes(request.method))return fail('허용되지 않는 요청 방식',405);
 let db,actor;
 try{db=initServer();actor=await getOperator(db,request)}
 catch(error){console.error('JB account config/auth:',error?.message);return fail('관리 서버 연결 오류',503)}
 if(!actor)return fail('대표님 또는 관리자의 로그인 인증이 필요합니다.',403);
 try{
  if(request.method==='GET'){
   const [users,employeeRes]=await Promise.all([
    getAccounts(db),
    db.from('jb_employees').select('id,name,position,department_id,app_role,active,auth_user_id')
   ]);
   if(employeeRes.error)throw employeeRes.error;
   const staff=employeeRes.data||[];
   const byAuth=new Map(staff.filter(x=>x.auth_user_id).map(x=>[x.auth_user_id,x]));
   const accounts=users.filter(u=>u.email).map(u=>{
    const e=byAuth.get(u.id)||null;
    if(actor.app_role==='manager'&&!targetAllowed(actor,e))return null;
    return {
     protected:!targetAllowed(actor,e),
     id:u.id,email:u.email,confirmed:!!u.email_confirmed_at,
     created_at:u.created_at,confirmation_sent_at:u.confirmation_sent_at,
     employee:e?{id:e.id,name:e.name,position:e.position,app_role:e.app_role,active:e.active}:null
    };
   }).filter(Boolean);
   const availableEmployees=staff.filter(e=>e.active===true&&!e.auth_user_id&&targetAllowed(actor,e))
    .map(e=>({id:e.id,name:e.name,position:e.position,department_id:e.department_id,app_role:e.app_role,active:e.active}));
   return send({accounts,availableEmployees,role:actor.app_role});
  }
  let body;
  try{body=await request.json()}catch(_){return fail('요청 형식이 올바르지 않습니다.')}
  const action=String(body?.action||'');
  const userId=String(body?.userId||'');
  if(!uuid(userId))return fail('회원가입 계정 ID를 확인하세요.');
  if(!['resend','unlink','link','delete'].includes(action))return fail('지원하지 않는 작업입니다.');
  if(action==='delete'&&actor.app_role!=='owner')return fail('회원가입 계정 삭제는 대표님만 가능합니다.',403);
  const {data:userResult,error:userError}=await db.auth.admin.getUserById(userId);
  if(userError||!userResult?.user)return fail('회원가입 계정을 찾을 수 없습니다.',404);
  const user=userResult.user;
  if(!user.email)return fail('이메일 회원가입 계정만 관리할 수 있습니다.');
  const linked=await lookupEmployee(db,userId);
  if(!targetAllowed(actor,linked))return fail('해당 계정은 수정할 권한이 없습니다.',403);
  if(action==='resend'){
   if(user.email_confirmed_at)return fail('이미 이메일 인증을 완료한 계정입니다.');
   const last=Date.parse(user.confirmation_sent_at||'');
   if(Number.isFinite(last)&&Date.now()-last<60000)return fail('인증 메일 재발송 간격이 짧습니다. 잠시 후 다시 시도하세요.',429);
   const pub=process.env.SUPABASE_PUBLISHABLE_KEY;
   if(!pub||!pub.startsWith('sb_publishable_'))return fail('SMTP 인증 재발송용 공개키 설정이 없습니다.',503);
   const client=createClient(process.env.SUPABASE_URL,pub,{auth:{persistSession:false,autoRefreshToken:false}});
   const redirect=new URL('/index.html',request.url).href;
   const {error}=await client.auth.resend({type:'signup',email:user.email,options:{emailRedirectTo:redirect}});
   if(error){console.error('JB admin resend error:',error.message);return fail('메일 전송 실패: '+error.message,502);}
   return send({message:'인증 메일 재발송 요청을 접수했습니다. 실제 수신은 받은편지함에서 확인해 주세요.'});
  }
  if(action==='unlink'){
   if(!linked)return fail('해당 계정은 이미 직원 기록과 연결되어 있지 않습니다.');
   const {data,error}=await db.from('jb_employees').update({auth_user_id:null})
    .eq('id',linked.id).eq('auth_user_id',userId).select('id');
   if(error)throw error;
   if(data?.length!==1)return fail('연결 정보가 변경됐습니다. 새로고침한 뒤 다시 확인하세요.',409);
   console.info('JB account unlink',actor.id,linked.id);
   return send({message:'로그인 계정 연결을 해제했습니다. 업무·근태·직원 기록은 보존됩니다.'});
  }
  if(action==='link'){
   if(!user.email_confirmed_at)return fail('이메일 인증을 완료한 뒤 연결할 수 있습니다.');
   if(linked)return fail('이미 다른 직원 기록에 연결된 계정입니다. 먼저 기존 연결을 확인하세요.');
   const employeeId=String(body?.employeeId||'');
   if(!uuid(employeeId))return fail('연결할 기존 직원 기록을 선택하세요.');
   const {data:target,error:targetError}=await db.from('jb_employees')
    .select('id,app_role,active,auth_user_id,department_id').eq('id',employeeId).maybeSingle();
   if(targetError)throw targetError;
   if(!target||!target.active||target.auth_user_id)return fail('활성 상태의 미연결 직원 기록만 선택할 수 있습니다.');
   if(!targetAllowed(actor,target))return fail('해당 직원 기록에 연결할 권한이 없습니다.',403);
   const {data,error}=await db.from('jb_employees').update({auth_user_id:userId})
    .eq('id',employeeId).eq('active',true).is('auth_user_id',null).select('id');
   if(error)throw error;
   if(data?.length!==1)return fail('직원 기록이 이미 변경됐습니다. 다시 조회하세요.',409);
   console.info('JB account link existing',actor.id,employeeId);
   return send({message:'기존 직원 기록에 로그인 계정을 연결했습니다. 업무·근태 이력은 유지됩니다.'});
  }
  if(linked)return fail('직원 기록에 연결된 계정입니다. 먼저 연결을 해제하고 다시 확인하세요.');
  if(String(body?.confirmEmail||'').trim().toLowerCase()!==String(user.email).trim().toLowerCase()){
   return fail('삭제 확인 이메일이 일치하지 않습니다.');
  }
  // Direct Auth-UID audit/history references: never delete accounts whose
  // authorship would be orphaned. Employee-based historical links are preserved.
  const audit=[
   ['jb_meal_employee_v14','updated_by'],
   ['jb_meal_guest_v14','created_by'],
   ['jb_meal_regular_orders_v15','updated_by'],
   ['jb_meal_regular_people_v15','created_by']
  ];
  for(const [table,col] of audit){
   const {count,error}=await db.from(table).select('*',{count:'exact',head:true}).eq(col,userId);
   if(error){console.error('JB account audit check:',table,error.message);return fail('기록 안전검사를 완료하지 못해 삭제를 중단했습니다.',503);}
   if(count>0)return fail('이 계정으로 작성한 식사 기록이 있습니다. 기록 보존을 위해 계정을 삭제할 수 없습니다.');
  }
  const {error:deleteError}=await db.auth.admin.deleteUser(userId);
  if(deleteError){console.error('JB account delete:',deleteError.message);return fail('계정 삭제가 거부됐습니다. 사진·스토리지 소유권 또는 다른 연결 기록을 확인해 주세요.',409);}
  console.info('JB account deleted',actor.id,userId);
  return send({message:'회원가입 계정만 삭제했습니다. 직원·업무·근태 기록은 보존됐습니다.'});
 }catch(error){
  console.error('JB account admin:',error?.message||String(error));
  return fail('계정 관리 처리 중 오류가 발생했습니다. 데이터를 변경하지 말고 다시 확인하세요.',503);
 }
};
export const config={rateLimit:{windowLimit:90,windowSize:60,aggregateBy:['ip','domain']}};
