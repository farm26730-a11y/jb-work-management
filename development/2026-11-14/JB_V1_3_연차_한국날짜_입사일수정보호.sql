-- JB V1.3 연차관리 서버 한국 시간 기준 통일 및 입사일 정정 보호.
-- 기존 업무 승인/초기화 함수와 운영 main 변경 없음.

CREATE OR REPLACE FUNCTION public.jb_annual_leave_set_hire_date_v13(p_employee_id uuid,p_hire_date date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_target public.jb_employees%ROWTYPE;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 SELECT * INTO v_target FROM public.jb_employees WHERE id=p_employee_id FOR UPDATE;
 IF v_me.id IS NULL OR v_target.id IS NULL OR
    NOT (v_me.app_role='owner' OR
         (v_me.app_role='manager' AND v_target.app_role='staff' AND
          v_me.department_id IS NOT NULL AND v_me.department_id=v_target.department_id)) THEN
   RAISE EXCEPTION '입사일을 수정할 권한이 없습니다' USING ERRCODE='42501';
 END IF;
 IF v_target.app_role='owner' OR p_hire_date IS NULL OR p_hire_date>(now() AT TIME ZONE 'Asia/Seoul')::date OR p_hire_date<DATE '1950-01-01' THEN
   RAISE EXCEPTION '유효한 입사일을 입력하세요';
 END IF;
 IF v_target.hire_date IS NOT NULL AND v_target.hire_date IS DISTINCT FROM p_hire_date AND
   (EXISTS(SELECT 1 FROM jb_hr.annual_leave_grants_v13 WHERE employee_id=p_employee_id)
    OR EXISTS(SELECT 1 FROM jb_hr.annual_leave_adjustments_v13 WHERE employee_id=p_employee_id)) THEN
   RAISE EXCEPTION '연차 기록이 존재합니다. 입사일 변경 전 기록 정정 절차를 확인해야 합니다';
 END IF;
 IF v_target.hire_date IS NOT NULL AND v_target.hire_date IS DISTINCT FROM p_hire_date AND
   (EXISTS(SELECT 1 FROM jb_hr.annual_leave_usage_v13 WHERE employee_id=p_employee_id)
    OR EXISTS(SELECT 1 FROM jb_hr.annual_leave_approval_reviews_v13 WHERE employee_id=p_employee_id)
    OR EXISTS(SELECT 1 FROM public.jb_leave_requests WHERE employee_id=p_employee_id
                  AND request_type='leave' AND approval_status='approved'
                  AND leave_category IN ('annual','half_am','half_pm'))) THEN
   RAISE EXCEPTION '승인된 연차·반차 기록이 있어 입사일 변경 전에 정정 절차가 필요합니다';
 END IF;
 UPDATE public.jb_employees SET hire_date=p_hire_date WHERE id=p_employee_id;
END;$f$;

CREATE OR REPLACE FUNCTION public.jb_annual_leave_confirm_grant_v13(
 p_employee_id uuid,p_grant_kind text,p_period_index integer,p_verification_note text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_target public.jb_employees%ROWTYPE;
 v_start date; v_grant date; v_expire date; v_days numeric(6,2); v_id uuid;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 SELECT * INTO v_target FROM public.jb_employees WHERE id=p_employee_id AND active IS TRUE FOR UPDATE;
 IF v_me.id IS NULL OR v_target.id IS NULL OR NOT (
     v_me.app_role='owner' OR
     (v_me.app_role='manager' AND v_target.app_role='staff' AND v_me.department_id IS NOT NULL AND v_me.department_id=v_target.department_id)) THEN
   RAISE EXCEPTION '연차 발생을 확정할 권한이 없습니다' USING ERRCODE='42501';
 END IF;
 IF v_target.app_role='owner' OR v_target.hire_date IS NULL THEN RAISE EXCEPTION '직원의 입사일 등록이 먼저 필요합니다'; END IF;
 IF length(btrim(coalesce(p_verification_note,'')))<4 THEN RAISE EXCEPTION '개근 또는 출근율 확인 근거를 4자 이상 입력하세요'; END IF;
 IF p_grant_kind='monthly' AND p_period_index BETWEEN 1 AND 11 THEN
   v_start=(v_target.hire_date+make_interval(months=>p_period_index-1))::date;
   v_grant=(v_target.hire_date+make_interval(months=>p_period_index))::date;
   v_expire=(v_target.hire_date+make_interval(years=>1))::date-1;
   v_days=1;
 ELSIF p_grant_kind='yearly' AND p_period_index BETWEEN 1 AND 50 THEN
   v_start=(v_target.hire_date+make_interval(years=>p_period_index-1))::date;
   v_grant=(v_target.hire_date+make_interval(years=>p_period_index))::date;
   v_expire=(v_target.hire_date+make_interval(years=>p_period_index+1))::date-1;
   v_days=LEAST(25,15+floor((p_period_index-1)::numeric/2));
 ELSE RAISE EXCEPTION '잘못된 연차 발생 구분 또는 회차입니다'; END IF;
 IF v_grant>(now() AT TIME ZONE 'Asia/Seoul')::date THEN RAISE EXCEPTION '아직 발생일이 도래하지 않았습니다'; END IF;
 IF v_expire<(now() AT TIME ZONE 'Asia/Seoul')::date THEN RAISE EXCEPTION '기존 발생분의 사용기한이 지났습니다. 과거 기록 정정 절차로 처리하세요'; END IF;
 INSERT INTO jb_hr.annual_leave_grants_v13
 (employee_id,grant_kind,period_index,period_start,period_end,grant_date,expires_on,days,verification_note,verified_by)
 VALUES (p_employee_id,p_grant_kind,p_period_index,v_start,v_grant-1,v_grant,v_expire,v_days,btrim(p_verification_note),v_me.id)
 ON CONFLICT(employee_id,grant_kind,period_index) DO NOTHING RETURNING id INTO v_id;
 IF v_id IS NULL THEN RAISE EXCEPTION '이미 확정된 발생 회차입니다. 중복 적립할 수 없습니다'; END IF;
 RETURN v_id;
END;$f$;

CREATE OR REPLACE FUNCTION public.jb_annual_leave_adjust_v13(
 p_employee_id uuid,p_days numeric,p_reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_target public.jb_employees%ROWTYPE; v_id uuid;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 SELECT * INTO v_target FROM public.jb_employees WHERE id=p_employee_id AND active IS TRUE;
 IF v_me.id IS NULL OR v_target.id IS NULL OR NOT (v_me.app_role='owner' OR
  (v_me.app_role='manager' AND v_target.app_role='staff' AND v_me.department_id IS NOT NULL AND v_me.department_id=v_target.department_id)) THEN
   RAISE EXCEPTION '연차 조정 권한이 없습니다' USING ERRCODE='42501';
 END IF;
 IF v_target.app_role='owner' OR v_target.hire_date IS NULL THEN RAISE EXCEPTION '유효한 직원 입사일부터 등록하세요'; END IF;
 IF p_days IS NULL OR p_days=0 OR abs(p_days)>25 OR length(btrim(coalesce(p_reason,'')))<4 THEN
   RAISE EXCEPTION '조정일수(±25일 이내)와 4자 이상의 사유가 필요합니다';
 END IF;
 INSERT INTO jb_hr.annual_leave_adjustments_v13(employee_id,effective_date,days,reason,recorded_by)
 VALUES (p_employee_id,(now() AT TIME ZONE 'Asia/Seoul')::date,p_days,btrim(p_reason),v_me.id) RETURNING id INTO v_id;
 RETURN v_id;
END;$f$;

NOTIFY pgrst,'reload schema';
