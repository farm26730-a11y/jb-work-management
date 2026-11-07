-- [수정용/함수 교체] JB 업무관리 V1.3 식사 신청 전 부서 허용
-- 기존 jb_meal_assert_edit_v14 함수의 부서 제한만 해제.
-- 정식 직원·고정 식사 인원·일시 외부 인원의 '일자별 신청'에 적용.
-- 직무·근태·보고 권한, 고정 인원 등록/비활성화 권한은 변경하지 않음.
-- 실행 전 운영 DB의 실제 함수 정의와 설정 테이블 구조를 반드시 대조.
-- 사용자의 요청 범위: 활성 owner/manager/staff 누구나 다른 부서 식사 신청/수정 가능.
BEGIN;
CREATE OR REPLACE FUNCTION public.jb_meal_assert_edit_v14(
  p_date date, p_meal text, p_department uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role text;
  v_today date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  v_cutoff time := '16:00';
BEGIN
  IF p_date IS NULL OR p_meal IS NULL
     OR p_meal NOT IN ('lunch','dinner')
     OR p_department IS NULL THEN
    RAISE EXCEPTION '날짜·식사 구분·부서를 확인하세요';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.jb_departments
    WHERE id = p_department
  ) THEN
    RAISE EXCEPTION '등록되지 않은 부서입니다';
  END IF;

  SELECT app_role INTO v_role
  FROM public.jb_employees
  WHERE auth_user_id = (SELECT auth.uid())
    AND active IS TRUE;

  IF NOT FOUND OR v_role NOT IN ('owner','manager','staff') THEN
    RAISE EXCEPTION '인증된 재직 직원만 식사를 수정할 수 있습니다'
      USING ERRCODE='42501';
  END IF;

  -- 변경: 호출자의 소속 부서와 p_department 일치 조건은 검사하지 않음.
  -- 단, 하위 저장 함수의 대상 직원-선택 부서 일치 검증은 유지.

  -- 이전 날짜 제한: 일반 직원 기존 규칙 유지.
  IF v_role = 'staff' AND p_date < v_today THEN
    RAISE EXCEPTION '지난 날짜의 식사는 관리자에게 변경을 요청하세요'
      USING ERRCODE='42501';
  END IF;

  -- 당일 저녁 마감: 일반 직원 기존 규칙 유지.
  IF v_role = 'staff' AND p_meal='dinner' AND p_date=v_today THEN
    SELECT dinner_deadline::time INTO v_cutoff
    FROM public.jb_meal_settings
    WHERE id=true;

    IF v_cutoff IS NULL THEN v_cutoff := '16:00'; END IF;

    IF (now() AT TIME ZONE 'Asia/Seoul')::time >= v_cutoff THEN
      RAISE EXCEPTION '저녁 신청 마감시간이 지났습니다'
        USING ERRCODE='42501';
    END IF;
  END IF;
END;
$$;
-- 보조 검증 함수는 일반 authenticated가 직접 실행할 필요가 없음.
REVOKE ALL ON FUNCTION public.jb_meal_assert_edit_v14(date,text,uuid)
  FROM PUBLIC, anon, authenticated;
COMMIT;

-- [조회용] 함수 정의의 검토(설치와 별개)
-- SELECT pg_get_functiondef('public.jb_meal_assert_edit_v14(date,text,uuid)'::regprocedure);
