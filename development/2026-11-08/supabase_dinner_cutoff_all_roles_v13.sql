-- [설치 SQL: Supabase 운영 업무관리앱에 이미 적용된 수정 내용 보존]
-- 2026-11-08 저녁 주문 마감: 모든 재직 직원 역할, 한국시간 기준
-- 재실행할 필요 없음. 기존 주문 기록 삭제하지 않음.
CREATE OR REPLACE FUNCTION public.jb_meal_assert_edit_v14(p_date date, p_meal text, p_department uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_today date :=
    (now() AT TIME ZONE 'Asia/Seoul')::date;
  v_cutoff time := '16:00';
BEGIN

  IF p_date IS NULL
     OR p_meal IS NULL
     OR p_meal NOT IN ('lunch','dinner')
     OR p_department IS NULL THEN
    RAISE EXCEPTION '날짜·식사 구분·부서를 확인하세요';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.jb_departments
    WHERE id=p_department
  ) THEN
    RAISE EXCEPTION '등록되지 않은 부서입니다';
  END IF;

  SELECT app_role INTO v_role
  FROM public.jb_employees
  WHERE auth_user_id=(SELECT auth.uid())
    AND active IS TRUE;

  IF NOT FOUND
     OR v_role NOT IN ('owner','manager','staff') THEN
    RAISE EXCEPTION
      '인증된 재직 직원만 식사를 수정할 수 있습니다'
      USING ERRCODE='42501';
  END IF;

  -- 소속 부서 제한 없음
  -- 어느 부서의 식사든 신청·수정 가능

  IF v_role='staff'
     AND p_date<v_today THEN
    RAISE EXCEPTION
      '지난 날짜의 식사는 관리자에게 변경을 요청하세요'
      USING ERRCODE='42501';
  END IF;

  -- 모든 역할에 동일한 저녁 주문 마감 적용. 과거 날짜의 저녁 수정도 금지.
  IF p_meal='dinner' AND p_date<=v_today THEN

    SELECT dinner_deadline::time
    INTO v_cutoff
    FROM public.jb_meal_settings
    WHERE id=true;

    IF v_cutoff IS NULL THEN
      v_cutoff:='16:00';
    END IF;

    IF p_date < v_today OR (now() AT TIME ZONE 'Asia/Seoul')::time >= v_cutoff THEN
      RAISE EXCEPTION '저녁 신청 마감시간이 지났습니다'
        USING ERRCODE='42501';
    END IF;
  END IF;

END;
$function$
;
