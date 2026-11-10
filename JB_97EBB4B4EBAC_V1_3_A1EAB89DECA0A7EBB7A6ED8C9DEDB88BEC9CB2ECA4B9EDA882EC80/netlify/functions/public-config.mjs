// JB V1.3: only public Supabase client configuration for new devices.
// Configure SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in Netlify Functions env.
// Never expose SUPABASE_SERVICE_ROLE_KEY or any VAPID private key.
export default async request=>{
 if(request.method!=='GET')return new Response(null,{status:405});
 const url=String(process.env.SUPABASE_URL||'').trim().replace(/\/+$/,'');
 const key=String(process.env.SUPABASE_PUBLISHABLE_KEY||'').trim();
 const ok=/^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(url)&&key.startsWith('sb_publishable_');
 if(!ok)return new Response(JSON.stringify({ready:false}),{
  status:503,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store'}
 });
 return new Response(JSON.stringify({url,key}),{
  status:200,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store'}
 });
};
export const config={method:'GET'};
