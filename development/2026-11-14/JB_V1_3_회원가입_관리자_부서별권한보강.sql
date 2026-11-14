-- JB 업무관리 V1.3: manager staff signup link only own department.
-- 기존 직원 데이터 변경 없음, 기존 권한 구조(owner/manager/staff) 유지.
CREATE OR REPLACE FUNCTION public.jb_link_staff_by_email_v24(p_email text, p_name text, p_position text, p_department_id uuid, p_app_role text DEFAULT 'staff'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid;
  v_new_id uuid;
BEGIN
  -- 대표님 또는 재직 중인 관리자만 허용
  IF NOT EXISTS (
    SELECT 1
    FROM public.jb_employees me
    WHERE me.auth_user_id = auth.uid()
      AND me.active IS TRUE
      AND me.app_role IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION
      '관리자 또는 대표님만 직원을 연결할 수 있습니다.'
      USING ERRCODE = '42501';
  END IF;

  -- 신규 연결은 일반 직원 계정만 허용
  IF p_app_role IS DISTINCT FROM 'staff' THEN
    RAISE EXCEPTION
      '이 화면에서는 일반 직원 계정만 연결할 수 있습니다.'
      USING ERRCODE = '42501';
  END IF;

  IF length(btrim(coalesce(p_name, ''))) = 0
     OR length(btrim(coalesce(p_email, ''))) = 0 THEN
    RAISE EXCEPTION '이름과 이메일을 입력하세요.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.jb_departments d
    WHERE d.id = p_department_id
  ) THEN
    RAISE EXCEPTION '존재하지 않는 부서입니다.';
  END IF;

  -- 관리자 신규 직원 등록은 소속 부서로 제한 (대표는 전체 부서 가능)
  IF EXISTS (
    SELECT 1 FROM public.jb_employees me
    WHERE me.auth_user_id = auth.uid()
      AND me.active IS TRUE
      AND me.app_role = 'manager'
      AND (me.department_id IS NULL OR me.department_id IS DISTINCT FROM p_department_id)
  ) THEN
    RAISE EXCEPTION '관리자는 소속 부서의 일반 직원만 등록할 수 있습니다.' USING ERRCODE = '42501';
  END IF;

  -- 이메일 인증을 마친 회원가입 계정만 조회
  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = lower(btrim(p_email))
    AND u.email_confirmed_at IS NOT NULL
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION
      '이메일 인증을 완료한 회원가입 계정을 찾을 수 없습니다.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.jb_employees e
    WHERE e.auth_user_id = v_user_id
  ) THEN
    RAISE EXCEPTION '이미 등록된 직원 계정입니다.';
  END IF;

  INSERT INTO public.jb_employees (
    id,
    auth_user_id,
    name,
    "position",
    department_id,
    app_role,
    active
  )
  VALUES (
    gen_random_uuid(),
    v_user_id,
    btrim(p_name),
    btrim(coalesce(p_position, '')),
    p_department_id,
    'staff',
    true
  )
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$function$;

NOTIFY pgrst, 'reload schema';
