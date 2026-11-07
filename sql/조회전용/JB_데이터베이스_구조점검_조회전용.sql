-- [조회용] JB 업무관리 DB 구조·권한 점검
-- 앱·업무 데이터 변경 없음 / 설치·수정·삭제 함수 호출 없음
-- 검사 대상은 설치 여부·메타데이터입니다. 실제 동작 검증은 별도입니다.

-- 1. 주요 테이블 존재 확인
SELECT name, to_regclass('public.' || name) AS installed_table
FROM (VALUES
 ('jb_employees'),('jb_departments'),('jb_meal_settings'),
 ('jb_meal_rosters'),('jb_meal_employee_v14'),('jb_meal_guest_v14'),
 ('jb_meal_regular_people_v15'),('jb_meal_regular_orders_v15'),
 ('jb_push_outbox')
) AS t(name)
ORDER BY name;

-- 2. 주요 RPC 설치 및 SECURITY DEFINER/권한 확인
SELECT
 p.proname AS function_name,
 pg_get_function_identity_arguments(p.oid) AS arguments,
 p.prosecdef AS security_definer,
 has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN (
   'jb_meal_assert_edit_v14',
   'jb_meal_save_staff_v14',
   'jb_meal_add_guest_v14',
   'jb_meal_remove_guest_v14',
   'jb_meal_regular_manage_v15',
   'jb_meal_regular_save_v15',
   'jb_meal_set_deadline_v15'
  )
ORDER BY p.proname, arguments;

-- 3. 주요 테이블 RLS와 읽기 정책 이름 확인
SELECT
 c.relname AS table_name,
 c.relrowsecurity AS rls_enabled,
 c.relforcerowsecurity AS force_rls
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public'
  AND c.relkind IN ('r','p')
  AND c.relname IN (
   'jb_meal_employee_v14','jb_meal_guest_v14',
   'jb_meal_regular_people_v15','jb_meal_regular_orders_v15',
   'jb_meal_settings','jb_push_outbox'
  )
ORDER BY c.relname;

SELECT tablename, policyname, permissive, roles, cmd
FROM pg_policies
WHERE schemaname='public'
  AND tablename IN (
   'jb_meal_employee_v14','jb_meal_guest_v14',
   'jb_meal_regular_people_v15','jb_meal_regular_orders_v15',
   'jb_meal_settings','jb_push_outbox'
  )
ORDER BY tablename, policyname;

-- 4. 트리거 메타데이터. 이름 중복은 테이블별로 확인
SELECT event_object_table AS table_name, trigger_name,
       string_agg(DISTINCT event_manipulation, ', ' ORDER BY event_manipulation) AS events
FROM information_schema.triggers
WHERE trigger_schema='public' AND trigger_name LIKE 'jb_%'
GROUP BY event_object_table, trigger_name
ORDER BY event_object_table, trigger_name;

-- 5. 식사 마감시간 현재 값 (SELECT only)
SELECT id, dinner_deadline
FROM public.jb_meal_settings;

-- 6. 같은 이름의 public 함수가 여러 시그니처로 등록된 경우 찾기
SELECT p.proname AS function_name,
       count(*) AS overloaded_signatures
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname LIKE 'jb_%'
GROUP BY p.proname
HAVING count(*) > 1
ORDER BY overloaded_signatures DESC, function_name;
