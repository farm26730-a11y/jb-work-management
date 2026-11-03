// JB 업무관리 V1.3 — 직원 이름 로그인 전용 Edge Function (시험용)
// 배포 전: SQL rate-limit 설치, JB_ALLOWED_ORIGINS 설정, Supabase Auth 설정 검증 필수.
// 절대로 프런트엔드에 SUPABASE_SERVICE_ROLE_KEY를 입력하지 마세요.
import { createClient } from 'npm:@supabase/supabase-js@2.105.0'

const projectUrl = Deno.env.get('SUPABASE_URL') ?? ''
const publicKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const defaultOrigin = 'https://wonderful-malabi-db5450.netlify.app'
const allowed = new Set((Deno.env.get('JB_ALLOWED_ORIGINS') ?? defaultOrigin).split(',').map(x => x.trim()).filter(Boolean))

function response(origin: string | null, payload: object, status = 200) {
  const headers = new Headers({ 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'vary': 'Origin' })
  if (origin && allowed.has(origin)) {
    headers.set('access-control-allow-origin', origin)
    headers.set('access-control-allow-methods', 'POST, OPTIONS')
    headers.set('access-control-allow-headers', 'authorization, apikey, content-type, x-client-info')
  }
  return new Response(JSON.stringify(payload), { status, headers })
}
const fail = (origin: string | null, status = 401) =>
  response(origin, { error: '직원 이름 또는 비밀번호를 확인하세요.' }, status)

async function sha256(s: string) {
  const bytes = new TextEncoder().encode(s)
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))).map(x => x.toString(16).padStart(2, '0')).join('')
}

Deno.serve(async req => {
  const origin = req.headers.get('origin')
  if (!origin || !allowed.has(origin)) return response(null, { error: '요청 출처가 허용되지 않았습니다.' }, 403)
  if (req.method === 'OPTIONS') return response(origin, {}, 204)
  if (req.method !== 'POST') return response(origin, { error: 'POST만 허용됩니다.' }, 405)
  if (!projectUrl || !publicKey || !serviceKey) return response(origin, { error: '서버 인증 설정이 누락되었습니다.' }, 503)
  let name = '', password = ''
  try {
    const body = await req.json()
    name = String(body.name ?? '').trim()
    password = String(body.password ?? '')
  } catch {
    return fail(origin, 400)
  }
  if (!name || name.length > 50 || !password || password.length > 256) return fail(origin, 400)
  const admin = createClient(projectUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  try {
    // 서비스 역할만 호출 가능한 DB-원자적 로그인 시도 제한 (IP + 직원 이름).
    const ip = (req.headers.get('x-forwarded-for') ?? '').split(',')[0].trim() || 'unknown'
    const [ipHash, pairHash] = await Promise.all([sha256('ip:' + ip), sha256('pair:' + ip + ':' + name)])
    for (const [key, limit] of [[ipHash, 30], [pairHash, 6]] as const) {
      const { data, error } = await admin.rpc('jb_name_login_attempt_allow', { p_key: key, p_limit: limit })
      if (error) return response(origin, { error: '로그인 시도 제한 설정을 확인하세요.' }, 503)
      if (data !== true) return response(origin, { error: '로그인 시도가 많습니다. 15분 후 다시 시도하세요.' }, 429)
    }
    const { data: employees, error: lookupError } = await admin.from('jb_employees')
      .select('id,auth_user_id').eq('name', name).eq('active', true).limit(2)
    if (lookupError || !employees || employees.length !== 1 || !employees[0].auth_user_id) return fail(origin)
    const { data: userResult, error: userError } = await admin.auth.admin.getUserById(employees[0].auth_user_id)
    if (userError || !userResult.user?.email) return fail(origin)
    const authResult = await fetch(projectUrl + '/auth/v1/token?grant_type=password', {
      method: 'POST',
      headers: { 'apikey': publicKey, 'content-type': 'application/json' },
      body: JSON.stringify({ email: userResult.user.email, password }),
    })
    if (!authResult.ok) return fail(origin)
    const session = await authResult.json()
    if (!session.access_token || !session.refresh_token || session.user?.id !== employees[0].auth_user_id) return fail(origin)
    return response(origin, { access_token: session.access_token, refresh_token: session.refresh_token })
  } catch {
    return response(origin, { error: '일시적으로 이름 로그인을 사용할 수 없습니다.' }, 503)
  }
})
