-- JB 업무관리 V1.3 / 입사일 기준 연차(개발시험용)
-- 2026-11-14: 운영 Supabase에 연차 관리 전용 구조를 추가하는 설치 SQL. GitHub main/운영 UI 수정 없음.
-- 기존 직원 입사일은 모름(NULL)으로 두며 임의 추정하지 않음.
-- 월 개근/연 80% 출근율은 관리자가 별도 확인 후 발생 확정.
-- 반차는 0.5일, 다일 연차는 소정근로일 확인 후 사용일수 확정.
-- 기존 jb_owner_reset_operations_v11 초기화 함수는 변경하지 않음. 연차 장부는 별도 스키마에 보존.
-- 입사일은 신규 컬럼에 NULL 기본값. 기존 업무/직원/연차 신청 데이터를 삭제·변경하지 않음.

-- 별도 스키마의 연차 장부는 운영 기록 초기화 대상에서 제외. 
-- 새 장부가 기존 jb_* 테이블 초기화에 FK 차단을 일으키지 않도록
-- usage는 삭제 가능한 신청 테이블에 직접 FK를 두지 않고 신청 당시 정보를 보존함.
CREATE SCHEMA IF NOT EXISTS jb_hr;
REVOKE ALL ON SCHEMA jb_hr FROM PUBLIC, anon, authenticated;

ALTER TABLE public.jb_employees
  ADD COLUMN IF NOT EXISTS hire_date date;

CREATE TABLE IF NOT EXISTS jb_hr.annual_leave_grants_v13 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  grant_kind text NOT NULL CHECK (grant_kind IN ('monthly','yearly')),
  period_index integer NOT NULL CHECK (period_index BETWEEN 1 AND 50),
  period_start date NOT NULL,
  period_end date NOT NULL,
  grant_date date NOT NULL,
  expires_on date NOT NULL,
  days numeric(6,2) NOT NULL CHECK (days > 0 AND days <= 25),
  verification_note text NOT NULL CHECK (length(btrim(verification_note)) >= 4),
  verified_by uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT jb_annual_grant_unique_v13 UNIQUE(employee_id,grant_kind,period_index),
  CONSTRAINT jb_annual_grant_dates_v13 CHECK(period_start<=period_end AND period_end<grant_date AND grant_date<=expires_on)
);

CREATE TABLE IF NOT EXISTS jb_hr.annual_leave_adjustments_v13 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  effective_date date NOT NULL DEFAULT current_date,
  days numeric(6,2) NOT NULL CHECK (days BETWEEN -25 AND 25 AND days <> 0),
  reason text NOT NULL CHECK (length(btrim(reason)) >= 4),
  recorded_by uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS jb_hr.annual_leave_usage_v13 (
  request_id uuid PRIMARY KEY,
  employee_id uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  start_date date NOT NULL,
  end_date date NOT NULL,
  days numeric(6,2) NOT NULL CHECK (days > 0 AND days <= 31),
  note text NOT NULL CHECK (length(btrim(note)) >= 4),
  confirmed_by uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS jb_annual_grants_employee_date_idx_v13
 ON jb_hr.annual_leave_grants_v13(employee_id,grant_date);
CREATE INDEX IF NOT EXISTS jb_annual_adjustments_employee_date_idx_v13
 ON jb_hr.annual_leave_adjustments_v13(employee_id,effective_date);

ALTER TABLE jb_hr.annual_leave_grants_v13 ENABLE ROW LEVEL SECURITY;
ALTER TABLE jb_hr.annual_leave_adjustments_v13 ENABLE ROW LEVEL SECURITY;
ALTER TABLE jb_hr.annual_leave_usage_v13 ENABLE ROW LEVEL SECURITY;
-- 데이터 접근은 반드시 권한 검증이 있는 RPC 경유. 기본 직접 접근 금지.
REVOKE ALL ON TABLE jb_hr.annual_leave_grants_v13, jb_hr.annual_leave_adjustments_v13,
  jb_hr.annual_leave_usage_v13 FROM PUBLIC, anon, authenticated;

-- 관리자/대표만 입사일 수정. 실제 연차 발생 기록 후에는 입사일 변경 금지.
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
 IF v_target.app_role='owner' OR p_hire_date IS NULL OR p_hire_date>current_date OR p_hire_date<DATE '1950-01-01' THEN
   RAISE EXCEPTION '유효한 입사일을 입력하세요';
 END IF;
 IF v_target.hire_date IS DISTINCT FROM p_hire_date AND
   (EXISTS(SELECT 1 FROM jb_hr.annual_leave_grants_v13 WHERE employee_id=p_employee_id)
    OR EXISTS(SELECT 1 FROM jb_hr.annual_leave_adjustments_v13 WHERE employee_id=p_employee_id)) THEN
   RAISE EXCEPTION '연차 기록이 존재합니다. 입사일 변경 전 기록 정정 절차를 확인해야 합니다';
 END IF;
 UPDATE public.jb_employees SET hire_date=p_hire_date WHERE id=p_employee_id;
END;$f$;

-- 월 개근/연 출근율을 사람이 확인한 뒤 법정 발생량 확정.
-- p_period_index: 월별 1~11, 연차별 1=첫 1년 완료/2=둘째 1년 완료...
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
 IF v_grant>current_date THEN RAISE EXCEPTION '아직 발생일이 도래하지 않았습니다'; END IF;
 IF v_expire<current_date THEN RAISE EXCEPTION '기존 발생분의 사용기한이 지났습니다. 과거 기록 정정 절차로 처리하세요'; END IF;
 INSERT INTO jb_hr.annual_leave_grants_v13
 (employee_id,grant_kind,period_index,period_start,period_end,grant_date,expires_on,days,verification_note,verified_by)
 VALUES (p_employee_id,p_grant_kind,p_period_index,v_start,v_grant-1,v_grant,v_expire,v_days,btrim(p_verification_note),v_me.id)
 ON CONFLICT(employee_id,grant_kind,period_index) DO NOTHING RETURNING id INTO v_id;
 IF v_id IS NULL THEN RAISE EXCEPTION '이미 확정된 발생 회차입니다. 중복 적립할 수 없습니다'; END IF;
 RETURN v_id;
END;$f$;

-- 이전 사용분/이월분 등의 입력. 기존 조정 기록을 덮어쓰지 않고 감사 내역으로 추가.
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
 INSERT INTO jb_hr.annual_leave_adjustments_v13(employee_id,days,reason,recorded_by)
 VALUES (p_employee_id,p_days,btrim(p_reason),v_me.id) RETURNING id INTO v_id;
 RETURN v_id;
END;$f$;

-- 연속 날짜의 실제 연차 차감일수 확정 (휴무일 자동 제외 불가).
CREATE OR REPLACE FUNCTION public.jb_annual_leave_confirm_usage_v13(
 p_request_id uuid,p_days numeric,p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_employee public.jb_employees%ROWTYPE; v_request public.jb_leave_requests%ROWTYPE;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 SELECT * INTO v_request FROM public.jb_leave_requests WHERE id=p_request_id FOR UPDATE;
 SELECT * INTO v_employee FROM public.jb_employees WHERE id=v_request.employee_id;
 IF v_me.id IS NULL OR v_request.id IS NULL OR NOT (
   v_me.app_role='owner' OR
   (v_me.app_role='manager' AND v_employee.app_role='staff' AND v_me.department_id IS NOT NULL AND v_me.department_id=v_employee.department_id)) THEN
   RAISE EXCEPTION '차감일수를 확인할 권한이 없습니다' USING ERRCODE='42501';
 END IF;
 IF v_request.request_type<>'leave' OR v_request.approval_status<>'approved'
 OR v_request.leave_category NOT IN ('annual','half_am','half_pm') THEN
   RAISE EXCEPTION '승인된 연차/반차에만 적용할 수 있습니다';
 END IF;
 IF v_request.start_date=v_request.end_date THEN
   RAISE EXCEPTION '하루 연차 및 반차는 자동 집계됩니다';
 END IF;
 IF v_request.leave_category<>'annual' THEN
   RAISE EXCEPTION '연속 날짜 반차는 별도 검토가 필요합니다';
 END IF;
 IF p_days IS NULL OR p_days<=0 OR p_days>(v_request.end_date-v_request.start_date+1)
 OR length(btrim(coalesce(p_note,'')))<4 THEN
   RAISE EXCEPTION '소정근로일을 확인해 올바른 차감일수와 사유를 입력하세요';
 END IF;
 INSERT INTO jb_hr.annual_leave_usage_v13(request_id,employee_id,start_date,end_date,days,note,confirmed_by)
 VALUES(p_request_id,v_request.employee_id,v_request.start_date,v_request.end_date,p_days,btrim(p_note),v_me.id)
 ON CONFLICT(request_id) DO UPDATE
 SET employee_id=EXCLUDED.employee_id,start_date=EXCLUDED.start_date,end_date=EXCLUDED.end_date,
     days=EXCLUDED.days,note=EXCLUDED.note,
     confirmed_by=EXCLUDED.confirmed_by,updated_at=now();
END;$f$;

-- 실시간 연차 현황. 본인은 본인만; 관리자는 본인+같은 부서 직원; 대표는 직원 전원.
-- 등록되지 않은 입사일/확인되지 않은 연속 휴가는 정확한 잔액을 숨기고 확인 필요로 표시.
CREATE OR REPLACE FUNCTION public.jb_annual_leave_overview_v13()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_e public.jb_employees%ROWTYPE;
 v_years integer; v_from date; v_until date; v_grants numeric; v_adjust numeric;
 v_used numeric; v_unverified integer; v_next date; v_future_unverified jsonb;
 v_result jsonb:='[]'::jsonb; v_i integer; v_due date;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '직원 권한 확인 실패' USING ERRCODE='42501'; END IF;
 FOR v_e IN SELECT e.* FROM public.jb_employees e
   WHERE e.active IS TRUE AND e.app_role <> 'owner' AND
      (v_me.app_role='owner' OR e.id=v_me.id OR
       (v_me.app_role='manager' AND e.app_role='staff' AND
        v_me.department_id IS NOT NULL AND v_me.department_id=e.department_id))
   ORDER BY e.name, e.id
 LOOP
   IF v_e.hire_date IS NULL THEN
     v_result=v_result||jsonb_build_array(jsonb_build_object('employee_id',v_e.id,
       'name',v_e.name,'department_id',v_e.department_id,'role',v_e.app_role,
       'hire_date',NULL,'status','hire_date_missing','available_days',NULL));
     CONTINUE;
   END IF;
   v_years=GREATEST(0,extract(year from age(current_date,v_e.hire_date))::integer);
   v_from=(v_e.hire_date+make_interval(years=>v_years))::date;
   v_until=(v_e.hire_date+make_interval(years=>v_years+1))::date;
   SELECT COALESCE(sum(g.days),0) INTO v_grants FROM jb_hr.annual_leave_grants_v13 g
    WHERE g.employee_id=v_e.id AND g.grant_date>=v_from AND g.grant_date<v_until
      AND g.grant_date<=current_date AND g.expires_on>=current_date;
   SELECT COALESCE(sum(a.days),0) INTO v_adjust FROM jb_hr.annual_leave_adjustments_v13 a
    WHERE a.employee_id=v_e.id AND a.effective_date>=v_from AND a.effective_date<v_until;
   SELECT COALESCE(sum(CASE
      WHEN l.start_date<v_from OR l.end_date>=v_until THEN 0
      WHEN u.request_id IS NOT NULL THEN u.days
      WHEN l.start_date=l.end_date THEN CASE WHEN l.leave_category='annual' THEN 1 ELSE 0.5 END
      ELSE 0 END),0),
      COUNT(*) FILTER (WHERE l.start_date<v_from OR l.end_date>=v_until
                    OR (u.request_id IS NULL AND l.start_date<>l.end_date))
   INTO v_used,v_unverified
   FROM public.jb_leave_requests l
    LEFT JOIN jb_hr.annual_leave_usage_v13 u ON u.request_id=l.id
   WHERE l.employee_id=v_e.id AND l.request_type='leave' AND l.approval_status='approved'
    AND l.leave_category IN ('annual','half_am','half_pm')
    AND l.start_date<v_until AND l.end_date>=v_from;
   SELECT coalesce(jsonb_agg(jsonb_build_object('request_id',x.id,'start_date',x.start_date,
     'end_date',x.end_date,'category',x.leave_category,'cross_cycle',x.cross_cycle)),'[]'::jsonb)
     INTO v_future_unverified
   FROM (
    SELECT l.id,l.start_date,l.end_date,l.leave_category,
      (l.start_date<v_from OR l.end_date>=v_until) AS cross_cycle
    FROM public.jb_leave_requests l
      LEFT JOIN jb_hr.annual_leave_usage_v13 u ON u.request_id=l.id
    WHERE l.employee_id=v_e.id AND l.request_type='leave' AND l.approval_status='approved'
      AND l.leave_category IN ('annual','half_am','half_pm')
      AND l.start_date<v_until AND l.end_date>=v_from
      AND ((l.start_date<v_from OR l.end_date>=v_until) OR
           (u.request_id IS NULL AND l.start_date<>l.end_date))
    ORDER BY l.start_date DESC LIMIT 15
   ) x;
   v_next=NULL;
   IF v_years=0 THEN
      FOR v_i IN 1..11 LOOP
        v_due=(v_e.hire_date+make_interval(months=>v_i))::date;
        IF NOT EXISTS(SELECT 1 FROM jb_hr.annual_leave_grants_v13 g
           WHERE g.employee_id=v_e.id AND g.grant_kind='monthly' AND g.period_index=v_i) THEN
           v_next=v_due; EXIT;
        END IF;
      END LOOP;
   ELSE
      -- 이번 연도 발생분이 미확정이면 해당 발생일, 이미 확정되면 다음 기념일을 표시.
      v_next=v_from;
      IF EXISTS(SELECT 1 FROM jb_hr.annual_leave_grants_v13 g
                 WHERE g.employee_id=v_e.id AND g.grant_kind='yearly' AND g.period_index=v_years) THEN
         v_next=v_until;
      END IF;
   END IF;
   v_result=v_result||jsonb_build_array(jsonb_build_object(
      'employee_id',v_e.id,'name',v_e.name,'department_id',v_e.department_id,'role',v_e.app_role,
      'hire_date',v_e.hire_date,'status',CASE WHEN v_unverified>0 THEN 'needs_usage_review' ELSE 'ok' END,
      'cycle_start',v_from,'cycle_end',v_until-1,'years_completed',v_years,
      'granted_days',v_grants,'adjustment_days',v_adjust,'used_or_reserved_days',v_used,
      'unverified_count',v_unverified,'unverified_requests',v_future_unverified,
      'available_days',CASE WHEN v_unverified>0 THEN NULL ELSE v_grants+v_adjust-v_used END,
      'next_grant_due',v_next,'next_year_legal_days',LEAST(25,15+floor(v_years::numeric/2))
   ));
 END LOOP;
 RETURN jsonb_build_object('as_of',current_date,'items',v_result);
END;$f$;

-- 함수별 권한: 직접 테이블 조회 없음, 로그인된 직원만 RPC 호출.
REVOKE ALL ON FUNCTION public.jb_annual_leave_set_hire_date_v13(uuid,date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.jb_annual_leave_confirm_grant_v13(uuid,text,integer,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.jb_annual_leave_adjust_v13(uuid,numeric,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.jb_annual_leave_confirm_usage_v13(uuid,numeric,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.jb_annual_leave_overview_v13() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_set_hire_date_v13(uuid,date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_confirm_grant_v13(uuid,text,integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_adjust_v13(uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_confirm_usage_v13(uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_overview_v13() TO authenticated;


-- 새 RPC가 바로 API에서 인식되도록 PostgREST 스키마 캐시 갱신을 알립니다.
NOTIFY pgrst, 'reload schema';
