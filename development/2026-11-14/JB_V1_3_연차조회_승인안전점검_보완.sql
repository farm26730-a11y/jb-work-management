-- JB V1.3: 연차 조회 미확정 상태·한국 시간·기존 휴무 승인 안전 연동.
-- 운영 Supabase: 2026-11-14; 기존 업무/휴무/인원배치 함수와 운영 main 변경 금지.
-- 신규 감사 테이블 하나와 연차 RPC 2개, 기존 연차 조회 RPC 1개만 변경.
-- 운영 기록 초기화 대상(public jb_* 21개)은 변경하지 않습니다.

CREATE OR REPLACE FUNCTION public.jb_annual_leave_overview_v13()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE v_me public.jb_employees%ROWTYPE; v_e public.jb_employees%ROWTYPE;
 v_years integer; v_from date; v_until date; v_grants numeric; v_adjust numeric;
 v_used numeric; v_unverified integer; v_next date; v_future_unverified jsonb;
 v_result jsonb:='[]'::jsonb; v_i integer; v_due date;
 v_today date:=(now() AT TIME ZONE 'Asia/Seoul')::date;
 v_due_count integer; v_due_grants jsonb; v_prior_count integer; v_history jsonb;
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
   v_years=GREATEST(0,extract(year from age(v_today,v_e.hire_date))::integer);
   v_from=(v_e.hire_date+make_interval(years=>v_years))::date;
   v_until=(v_e.hire_date+make_interval(years=>v_years+1))::date;
   SELECT COALESCE(sum(g.days),0) INTO v_grants FROM jb_hr.annual_leave_grants_v13 g
    WHERE g.employee_id=v_e.id AND g.grant_date>=v_from AND g.grant_date<v_until
      AND g.grant_date<=v_today AND g.expires_on>=v_today;
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
   -- 사용기간 안에 남은 과거 발생 회차는 단순 합산하지 않고 수기 확인으로 구분.
   SELECT count(*) INTO v_prior_count
     FROM jb_hr.annual_leave_grants_v13 g
    WHERE g.employee_id=v_e.id AND g.grant_date<v_from AND g.expires_on>=v_today;
   v_due_count=0; v_due_grants='[]'::jsonb;
   IF v_years=0 THEN
     FOR v_i IN 1..11 LOOP
       v_due=(v_e.hire_date+make_interval(months=>v_i))::date;
       IF v_due<=v_today AND NOT EXISTS(
         SELECT 1 FROM jb_hr.annual_leave_grants_v13 g
          WHERE g.employee_id=v_e.id AND g.grant_kind='monthly' AND g.period_index=v_i
       ) THEN
         v_due_count=v_due_count+1;
         v_due_grants=v_due_grants||jsonb_build_array(
            jsonb_build_object('kind','monthly','index',v_i,'due',v_due,'days',1));
       END IF;
     END LOOP;
   ELSE
     IF v_from<=v_today AND NOT EXISTS(
       SELECT 1 FROM jb_hr.annual_leave_grants_v13 g
        WHERE g.employee_id=v_e.id AND g.grant_kind='yearly' AND g.period_index=v_years
     ) THEN
       v_due_count=1;
       v_due_grants=v_due_grants||jsonb_build_array(
         jsonb_build_object('kind','yearly','index',v_years,'due',v_from,
           'days',LEAST(25,15+floor((v_years-1)::numeric/2))));
     END IF;
   END IF;
   SELECT coalesce(jsonb_agg(jsonb_build_object(
        'grant_date',g.grant_date,'expires_on',g.expires_on,'days',g.days,
        'kind',g.grant_kind,'index',g.period_index) ORDER BY g.grant_date DESC),'[]'::jsonb)
     INTO v_history
     FROM jb_hr.annual_leave_grants_v13 g
    WHERE g.employee_id=v_e.id;
   v_result=v_result||jsonb_build_array(jsonb_build_object(
      'employee_id',v_e.id,'name',v_e.name,'department_id',v_e.department_id,'role',v_e.app_role,
      'hire_date',v_e.hire_date,'status',CASE WHEN v_unverified>0 THEN 'needs_usage_review' WHEN v_prior_count>0 THEN 'needs_carryover_review' WHEN v_due_count>0 THEN 'needs_attendance_review' ELSE 'ok' END,
      'cycle_start',v_from,'cycle_end',v_until-1,'years_completed',v_years,
      'granted_days',v_grants,'adjustment_days',v_adjust,'used_or_reserved_days',v_used,
      'unverified_count',v_unverified,'unverified_requests',v_future_unverified,
      'missing_due_count',v_due_count,'due_grants',v_due_grants,
      'prior_carry_count',v_prior_count,'grant_history',v_history,
      'available_days',CASE WHEN v_unverified>0 OR v_due_count>0 OR v_prior_count>0 THEN NULL ELSE v_grants+v_adjust-v_used END,
      'next_grant_due',v_next,'next_year_legal_days',LEAST(25,15+floor(GREATEST(0,v_years)::numeric/2))
   ));
 END LOOP;
 RETURN jsonb_build_object('as_of',v_today,'items',v_result);
END;$f$;



-- 연차 조회/검토 상태를 승인 이전에 확인하는 읽기 전용 RPC.
CREATE OR REPLACE FUNCTION public.jb_annual_leave_check_request_v13(p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE
 v_me public.jb_employees%ROWTYPE;
 v_emp public.jb_employees%ROWTYPE;
 v_req public.jb_leave_requests%ROWTYPE;
 v_overview jsonb; v_item jsonb;
 v_as_of date:=(now() AT TIME ZONE 'Asia/Seoul')::date;
 v_days numeric(6,2); v_balance numeric(6,2); v_state text;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 SELECT * INTO v_req FROM public.jb_leave_requests WHERE id=p_request_id;
 IF v_req.id IS NULL OR v_me.id IS NULL THEN
   RAISE EXCEPTION '신청 또는 직원 인증 정보가 없습니다' USING ERRCODE='42501';
 END IF;
 SELECT * INTO v_emp FROM public.jb_employees WHERE id=v_req.employee_id AND active IS TRUE;
 IF v_emp.id IS NULL OR NOT(
   v_me.id=v_emp.id
   OR (v_me.app_role='owner' AND v_emp.app_role='manager')
   OR (v_me.app_role='manager' AND v_emp.app_role='staff' AND v_me.department_id IS NOT NULL
    AND v_me.department_id=v_emp.department_id)
 ) THEN
  RAISE EXCEPTION '신청자의 연차를 조회할 권한이 없습니다' USING ERRCODE='42501';
 END IF;
 IF v_req.request_type<>'leave' OR v_req.leave_category NOT IN ('annual','half_am','half_pm') THEN
  RETURN jsonb_build_object('status','not_annual','required_days',0,'employee_id',v_emp.id);
 END IF;
 IF v_req.start_date=v_req.end_date THEN
  v_days=CASE WHEN v_req.leave_category='annual' THEN 1 ELSE 0.5 END;
 ELSE
  v_days=NULL;
 END IF;
 SELECT x.value INTO v_item FROM jsonb_array_elements((public.jb_annual_leave_overview_v13())->'items') x(value)
  WHERE x.value->>'employee_id'=v_emp.id::text LIMIT 1;
 IF v_item IS NULL OR v_item->>'status'='hire_date_missing' THEN
  v_state='hire_date_missing';
 ELSIF v_days IS NULL THEN
  v_state='multi_day_review';
 ELSIF v_item->>'status'<>'ok' OR v_item->>'available_days' IS NULL THEN
  v_state='balance_unconfirmed';
 ELSIF v_req.start_date<(v_item->>'cycle_start')::date THEN
  v_state='outside_cycle';
 ELSIF v_req.start_date>(v_item->>'cycle_end')::date THEN
  v_state='outside_cycle';
 ELSIF v_req.start_date>v_as_of THEN
  v_state='future_request_review';
 ELSE
  v_balance=(v_item->>'available_days')::numeric;
  v_state=CASE WHEN v_balance>=v_days THEN 'ready' ELSE 'insufficient' END;
 END IF;
 RETURN jsonb_build_object('status',v_state,'employee_id',v_emp.id,
  'start_date',v_req.start_date,'end_date',v_req.end_date,'category',v_req.leave_category,
  'required_days',v_days,'available_days',v_item->'available_days',
  'overview_status',coalesce(v_item->>'status','not_loaded'),'as_of',v_as_of);
END;$f$;

-- 승인 예외를 남기되 기존 신청 테이블 FK와 기존 초기화 함수는 변경하지 않음.
CREATE TABLE IF NOT EXISTS jb_hr.annual_leave_approval_reviews_v13(
 request_id uuid PRIMARY KEY,
 employee_id uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
 review_state text NOT NULL,
 required_days numeric(6,2),
 available_days numeric(6,2),
 review_note text NOT NULL,
 reviewed_by uuid NOT NULL REFERENCES public.jb_employees(id) ON DELETE RESTRICT,
 reviewed_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE jb_hr.annual_leave_approval_reviews_v13 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE jb_hr.annual_leave_approval_reviews_v13 FROM PUBLIC,anon,authenticated;

-- 신규 개발본만 이 RPC를 사용: 기존 운영 승인 RPC는 그대로 유지.
CREATE OR REPLACE FUNCTION public.jb_annual_leave_review_request_v13(
  p_request_id uuid,p_decision text,p_approval_days numeric DEFAULT NULL,p_review_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE
 v_req public.jb_leave_requests%ROWTYPE; v_me public.jb_employees%ROWTYPE;
 v_state jsonb; v_status text; v_required numeric; v_note text;
 v_result jsonb; v_annual boolean;
BEGIN
 IF p_decision NOT IN ('approved','rejected') OR p_decision IS NULL THEN
   RAISE EXCEPTION '올바르지 않은 승인 상태입니다';
 END IF;
 SELECT * INTO v_me FROM public.jb_employees WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '활성 계정만 승인할 수 있습니다' USING ERRCODE='42501'; END IF;
 SELECT * INTO v_req FROM public.jb_leave_requests WHERE id=p_request_id FOR UPDATE;
 IF v_req.id IS NULL OR v_req.approval_status <> 'pending' THEN
  RAISE EXCEPTION '승인 가능한 대기 신청이 없습니다';
 END IF;
 -- 직급/부서/승인 가능 여부는 호출되는 기존 검증 함수에서도 재검사한다.
 IF p_decision='rejected' THEN
  RETURN public.jb_review_leave_companywide(p_request_id,p_decision);
 END IF;
 v_annual=v_req.request_type='leave' AND v_req.leave_category IN ('annual','half_am','half_pm');
 IF NOT v_annual THEN
  RETURN public.jb_review_leave_companywide(p_request_id,p_decision);
 END IF;
 PERFORM pg_advisory_xact_lock(52113,hashtext(v_req.employee_id::text));
 v_state=public.jb_annual_leave_check_request_v13(p_request_id);
 v_status=v_state->>'status';
 v_required=(v_state->>'required_days')::numeric;
 v_note=btrim(coalesce(p_review_note,''));
 IF v_status='multi_day_review' THEN
   IF v_req.leave_category<>'annual' OR p_approval_days IS NULL OR p_approval_days<=0
      OR p_approval_days>(v_req.end_date-v_req.start_date+1) OR p_approval_days>31
      OR p_approval_days*2<>trunc(p_approval_days*2)
   THEN RAISE EXCEPTION '여러 날 연차는 실제 소정근로일수(0.5일 단위)를 확인하세요'; END IF;
   v_required=p_approval_days;
 ELSIF p_approval_days IS NOT NULL AND p_approval_days<>v_required THEN
   RAISE EXCEPTION '하루 연차/반차 차감일수는 자동 산정값을 사용하세요';
 END IF;
 IF v_status<>'ready' AND length(v_note)<8 THEN
   RAISE EXCEPTION '잔액 미확정·초과·연속 휴가 등의 승인은 확인 사유를 8자 이상 입력하세요';
 END IF;
 v_result=public.jb_review_leave_companywide(p_request_id,p_decision);
 IF v_status='multi_day_review' THEN
   PERFORM public.jb_annual_leave_confirm_usage_v13(p_request_id,v_required,v_note);
 END IF;
 INSERT INTO jb_hr.annual_leave_approval_reviews_v13
 (request_id,employee_id,review_state,required_days,available_days,review_note,reviewed_by)
 VALUES(p_request_id,v_req.employee_id,v_status,v_required,
  NULLIF(v_state->>'available_days','')::numeric,
  CASE WHEN v_status='ready' THEN '잔여 연차 확인 후 승인' ELSE v_note END,v_me.id)
 ON CONFLICT(request_id) DO UPDATE SET
  review_state=EXCLUDED.review_state,required_days=EXCLUDED.required_days,
  available_days=EXCLUDED.available_days,review_note=EXCLUDED.review_note,
  reviewed_by=EXCLUDED.reviewed_by,reviewed_at=now();
 RETURN jsonb_build_object('success',true,'review_state',v_status,'request_id',p_request_id,
  'approved_days',v_required,'result',v_result);
END;$f$;

REVOKE ALL ON FUNCTION public.jb_annual_leave_check_request_v13(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.jb_annual_leave_review_request_v13(uuid,text,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_check_request_v13(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jb_annual_leave_review_request_v13(uuid,text,numeric,text) TO authenticated;
NOTIFY pgrst,'reload schema';
