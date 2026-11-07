-- [설치용] JB 업무관리 V1.3 저녁 신청 공통 마감시간 변경
-- 전제: public.jb_meal_settings(id boolean PRIMARY KEY, dinner_deadline time 또는 호환되는 형식)
--       public.jb_employees(auth_user_id, active, app_role) 기존 운영 구조
-- 기존 마감시간을 바꾸지 않고, 관리 함수만 추가합니다.
BEGIN;

CREATE OR REPLACE FUNCTION public.jb_meal_set_deadline_v15(
  p_deadline text
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_role text;
  v_cutoff time without time zone;
  v_stored text;
BEGIN
  SELECT e.app_role
    INTO v_role
  FROM public.jb_employees e
  WHERE e.auth_user_id = (SELECT auth.uid())
    AND e.active IS TRUE;

  IF NOT FOUND OR v_role NOT IN ('owner','manager') THEN
    RAISE EXCEPTION '저녁 마감시간은 대표 또는 부서장만 수정할 수 있습니다.'
      USING ERRCODE = '42501';
  END IF;

  IF p_deadline IS NULL
     OR p_deadline !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
    RAISE EXCEPTION '마감시간은 HH:MM 형식으로 입력하세요.';
  END IF;

  v_cutoff := p_deadline::time;

  -- 기존 전사 공통 설정 한 행을 업데이트합니다.
  UPDATE public.jb_meal_settings
     SET dinner_deadline = v_cutoff
   WHERE id = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION '공통 식사 마감시간 설정 행이 없습니다. 현재 테이블 상태를 확인하세요.';
  END IF;

  SELECT left(s.dinner_deadline::text,5)
    INTO v_stored
  FROM public.jb_meal_settings s
  WHERE s.id = true;

  IF v_stored IS DISTINCT FROM p_deadline THEN
    RAISE EXCEPTION '저장 후 조회된 마감시간이 입력값과 일치하지 않습니다.';
  END IF;

  RETURN v_stored;
END;
$function$;

REVOKE ALL ON FUNCTION public.jb_meal_set_deadline_v15(text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_meal_set_deadline_v15(text)
  TO authenticated;

COMMIT;
