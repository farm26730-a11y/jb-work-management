-- JB 업무관리 V1.4 / 반차 출근 배치 충돌 해결
-- 1단계: 기존 서버 함수의 승인 휴무 검사에 전일 휴무 조건만 추가
BEGIN;
DO $patch$
DECLARE
  v_sql text;
  v_old text := 'AND approval_status=''approved'' AND start_date <= p_work_date AND end_date >= p_work_date';
  v_new text := 'AND approval_status=''approved'' AND COALESCE(leave_category,''general'') NOT IN (''half_am'',''half_pm'') AND start_date <= p_work_date AND end_date >= p_work_date';
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO v_sql
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='jb_save_attendance_batch'
    AND pg_get_function_identity_arguments(p.oid)='p_work_date date, p_operations jsonb, p_note_changed boolean, p_note_id uuid, p_note text';

  IF v_sql IS NULL THEN
    RAISE EXCEPTION '대상 함수 정의를 찾지 못했습니다. 변경하지 않습니다.';
  END IF;
  IF (length(v_sql)-length(replace(v_sql,v_old,'')))/length(v_old) <> 1 THEN
    RAISE EXCEPTION '기존 휴무 검사 조건이 예상과 다릅니다. 변경하지 않습니다.';
  END IF;
  EXECUTE replace(v_sql,v_old,v_new);
END;
$patch$;
COMMIT;

-- 수정 검증
SELECT p.proname,
       position('COALESCE(leave_category' IN pg_get_functiondef(p.oid))>0 AS half_day_exclusion_installed
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='jb_save_attendance_batch';

-- 2단계: 2026-11-03 송민제(manager)의 오후 반차 배치만 정정
-- 송민제 staff 동명이인 계정과 혼동 방지, 승인 반차 존재 및 전일 휴무 부재 검사
BEGIN;
DO $repair$
DECLARE
 v_employee uuid;
 v_row uuid;
BEGIN
 SELECT id INTO STRICT v_employee
 FROM public.jb_employees
 WHERE name='송민제' AND app_role='manager' AND active IS TRUE;

 IF NOT EXISTS (
  SELECT 1 FROM public.jb_leave_requests
  WHERE employee_id=v_employee AND request_type='leave'
    AND approval_status='approved' AND leave_category='half_pm'
    AND start_date<=DATE '2026-11-03' AND end_date>=DATE '2026-11-03'
 ) THEN
  RAISE EXCEPTION '승인된 오후 반차가 없어 변경하지 않습니다.';
 END IF;

 IF EXISTS (
  SELECT 1 FROM public.jb_leave_requests
  WHERE employee_id=v_employee AND request_type='leave'
    AND approval_status='approved'
    AND COALESCE(leave_category,'general') NOT IN ('half_am','half_pm')
    AND start_date<=DATE '2026-11-03' AND end_date>=DATE '2026-11-03'
 ) THEN
  RAISE EXCEPTION '전일 휴무도 등록되어 있어 변경하지 않습니다.';
 END IF;

 SELECT id INTO STRICT v_row
 FROM public.jb_attendance
 WHERE employee_id=v_employee
   AND work_date=DATE '2026-11-03'
   AND status='off'
 FOR UPDATE;

 UPDATE public.jb_attendance
 SET status='working',
     work_location=COALESCE(NULLIF(btrim(work_location),''),'사무실'),
     updated_at=now()
 WHERE id=v_row;
END;
$repair$;
COMMIT;

-- 최종 확인
SELECT e.name,e.app_role,l.leave_category,l.approval_status,
       a.work_date,a.status,a.work_location
FROM public.jb_employees e
JOIN public.jb_attendance a ON a.employee_id=e.id
LEFT JOIN public.jb_leave_requests l ON l.employee_id=e.id
  AND l.start_date<=a.work_date AND l.end_date>=a.work_date
WHERE e.name='송민제' AND e.app_role='manager'
  AND a.work_date=DATE '2026-11-03';
