-- [조회용] 인원배치 저장 RPC 구조 확인
-- 기존 업무 데이터 및 함수 변경 없음
-- 결과를 검토한 후 직원 권한만 확장하는 수정 SQL 작성
SELECT
 p.proname AS function_name,
 pg_get_function_identity_arguments(p.oid) AS arguments,
 p.prosecdef AS security_definer,
 has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute,
 pg_get_functiondef(p.oid) AS function_definition
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname='jb_save_attendance_batch'
ORDER BY arguments;

-- [조회용] 인원배치 관련 트리거 확인
SELECT event_object_table AS table_name,
       trigger_name, action_timing, event_manipulation,
       action_statement
FROM information_schema.triggers
WHERE trigger_schema='public'
  AND event_object_table IN ('jb_attendance','jb_attendance_notes')
ORDER BY event_object_table,trigger_name,event_manipulation;
