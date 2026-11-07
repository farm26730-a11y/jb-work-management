-- [수정용] JB 업무관리 V1.3 인원배치 전체 재직 직원 수정 허용
-- 변경 내용: jb_save_attendance_batch 내부 role 검사에 'staff'만 추가.
-- 기존 동시 저장 잠금, 500건 제한, 임시 인원 검증, 휴무 충돌 방지, 메모 검증 유지.
-- 제공받은 Supabase 실DB 함수 정의를 근거로 작성한 전체 함수 교체 스크립트입니다.
-- 운영 앱은 별도 배포하지 않음.

BEGIN;
CREATE OR REPLACE FUNCTION public.jb_save_attendance_batch(
 p_work_date date,
 p_operations jsonb,
 p_note_changed boolean DEFAULT false,
 p_note_id uuid DEFAULT NULL::uuid,
 p_note text DEFAULT NULL::text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
 v_me public.jb_employees%ROWTYPE;
 v_op jsonb;
 v_type text;
 v_id uuid;
 v_employee_id uuid;
 v_temporary_name text;
 v_status text;
 v_location text;
 v_memo text;
 v_count integer := 0;
 v_existing public.jb_attendance%ROWTYPE;
BEGIN
 SELECT * INTO v_me FROM public.jb_employees
 WHERE auth_user_id = (SELECT auth.uid()) AND active = true;
 -- 기존 owner/manager에 staff 추가. 기타 검증은 변경하지 않음.
 IF v_me.id IS NULL OR v_me.app_role NOT IN ('owner','manager','staff') THEN
  RAISE EXCEPTION '인원배치 변경 권한이 없습니다';
 END IF;
 IF p_work_date IS NULL OR p_operations IS NULL OR jsonb_typeof(p_operations) <> 'array'
    OR jsonb_array_length(p_operations) > 500 THEN
  RAISE EXCEPTION '잘못된 인원배치 요청입니다';
 END IF;
 -- 같은 날짜의 동시 저장이 뒤섞이는 것을 방지
 PERFORM pg_catalog.pg_advisory_xact_lock(752016, (p_work_date - DATE '2000-01-01')::integer);
 FOR v_op IN SELECT value FROM jsonb_array_elements(p_operations) AS x(value) LOOP
  v_type := v_op->>'type';
  IF v_type NOT IN ('insert','update','delete') THEN RAISE EXCEPTION '지원하지 않는 작업'; END IF;
  v_id := NULLIF(v_op->>'id','')::uuid;
  IF v_type <> 'insert' AND v_id IS NULL THEN RAISE EXCEPTION '대상 기록 ID가 없습니다'; END IF;
  IF v_type = 'delete' THEN
   DELETE FROM public.jb_attendance WHERE id = v_id AND work_date = p_work_date;
   IF NOT FOUND THEN RAISE EXCEPTION '삭제할 기록이 없거나 변경되었습니다'; END IF;
  ELSE
   v_employee_id := NULLIF(v_op->>'employee_id','')::uuid;
   v_temporary_name := NULLIF(pg_catalog.btrim(COALESCE(v_op->>'temporary_name','')),'');
   v_status := v_op->>'status';
   v_location := NULLIF(pg_catalog.btrim(COALESCE(v_op->>'work_location','')),'');
   v_memo := NULLIF(v_op->>'memo','');
   IF v_status NOT IN ('working','trip','off') THEN RAISE EXCEPTION '근무 상태가 잘못됐습니다'; END IF;
   IF v_status = 'working' AND v_location IS NULL THEN RAISE EXCEPTION '출근 장소가 누락되었습니다'; END IF;
   IF (v_employee_id IS NULL) = (v_temporary_name IS NULL) THEN
     RAISE EXCEPTION '직원 ID 또는 임시 인원 이름 하나만 입력해야 합니다';
   END IF;
   IF v_employee_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.jb_employees WHERE id=v_employee_id AND active=true) THEN
      RAISE EXCEPTION '활성 직원이 아닙니다';
    END IF;
    IF v_status <> 'off' AND EXISTS (
     SELECT 1 FROM public.jb_leave_requests
     WHERE employee_id=v_employee_id AND request_type='leave'
      AND approval_status='approved' AND COALESCE(leave_category,'general') NOT IN ('half_am','half_pm') AND start_date <= p_work_date AND end_date >= p_work_date
    ) THEN RAISE EXCEPTION '승인된 휴무와 출근 배치가 충돌합니다'; END IF;
   END IF;
   IF v_type = 'insert' THEN
    INSERT INTO public.jb_attendance(work_date,employee_id,temporary_name,status,work_location,memo)
    VALUES(p_work_date,v_employee_id,v_temporary_name,v_status,v_location,v_memo);
   ELSE
    SELECT * INTO v_existing FROM public.jb_attendance WHERE id=v_id AND work_date=p_work_date FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION '수정할 기록이 없거나 변경되었습니다'; END IF;
    IF v_existing.employee_id IS DISTINCT FROM v_employee_id THEN
      RAISE EXCEPTION '직원 연결은 수정할 수 없습니다';
    END IF;
    UPDATE public.jb_attendance
    SET temporary_name=v_temporary_name,status=v_status,work_location=v_location,memo=v_memo,updated_at=pg_catalog.now()
    WHERE id=v_id AND work_date=p_work_date;
   END IF;
  END IF;
  v_count := v_count + 1;
 END LOOP;
 IF p_note_changed THEN
  IF p_note_id IS NOT NULL THEN
   IF NULLIF(pg_catalog.btrim(COALESCE(p_note,'')),'') IS NULL THEN
    DELETE FROM public.jb_attendance_notes WHERE id=p_note_id AND work_date=p_work_date;
   ELSE
    UPDATE public.jb_attendance_notes SET note=pg_catalog.btrim(p_note)
    WHERE id=p_note_id AND work_date=p_work_date;
   END IF;
   IF NOT FOUND THEN RAISE EXCEPTION '추가 안내 기록이 변경되었습니다'; END IF;
  ELSIF NULLIF(pg_catalog.btrim(COALESCE(p_note,'')),'') IS NOT NULL THEN
   INSERT INTO public.jb_attendance_notes(work_date,note,created_by)
   VALUES(p_work_date,pg_catalog.btrim(p_note),v_me.id);
  END IF;
 END IF;
 RETURN v_count;
END;
$function$;
COMMIT;
