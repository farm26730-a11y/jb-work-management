-- [설치용] V1.3 댓글 알림: 담당자에게만 푸시 + 홈 확인 요청
-- 기존 댓글/업무/알림 대기열은 변경·삭제하지 않음. 과거 댓글 소급 알림 없음.
BEGIN;
CREATE TABLE IF NOT EXISTS public.jb_task_comment_attention_v13 (
 comment_id uuid PRIMARY KEY REFERENCES public.jb_task_comments(id) ON DELETE CASCADE,
 task_id uuid NOT NULL REFERENCES public.jb_tasks(id) ON DELETE CASCADE,
 employee_id uuid NOT NULL REFERENCES public.jb_employees(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 acknowledged_at timestamptz
);
CREATE INDEX IF NOT EXISTS jb_task_comment_attention_v13_pending_idx
 ON public.jb_task_comment_attention_v13(employee_id,created_at DESC)
 WHERE acknowledged_at IS NULL;
ALTER TABLE public.jb_task_comment_attention_v13 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS jb_comment_attention_own_select_v13 ON public.jb_task_comment_attention_v13;
CREATE POLICY jb_comment_attention_own_select_v13
 ON public.jb_task_comment_attention_v13
 FOR SELECT TO authenticated
 USING (
   employee_id IN (SELECT id FROM public.jb_employees
                   WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE)
 );
REVOKE ALL ON TABLE public.jb_task_comment_attention_v13 FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.jb_task_comment_attention_v13 TO authenticated;

CREATE OR REPLACE FUNCTION public.jb_task_comment_notify_v13()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_assignee uuid;
BEGIN
 SELECT t.assignee_id INTO v_assignee
 FROM public.jb_tasks t
 JOIN public.jb_employees e ON e.id=t.assignee_id AND e.active IS TRUE
 WHERE t.id=NEW.task_id;
 IF v_assignee IS NULL OR v_assignee IS NOT DISTINCT FROM NEW.author_id THEN
  RETURN NEW;
 END IF;
 INSERT INTO public.jb_task_comment_attention_v13(comment_id,task_id,employee_id,created_at)
 VALUES(NEW.id,NEW.task_id,v_assignee,NEW.created_at)
 ON CONFLICT (comment_id) DO NOTHING;
 -- 기존 큐 함수가 'comment'를 허용: 서비스 워커 푸시 파이프라인 그대로 사용.
 PERFORM public.jb_queue_push_event('comment:'||NEW.id::text,v_assignee,'comment');
 RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS jb_task_comment_notify_insert_v13 ON public.jb_task_comments;
CREATE TRIGGER jb_task_comment_notify_insert_v13
 AFTER INSERT ON public.jb_task_comments
 FOR EACH ROW EXECUTE FUNCTION public.jb_task_comment_notify_v13();

CREATE OR REPLACE FUNCTION public.jb_acknowledge_task_comment_v13(p_comment_id uuid)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_me uuid; v_ack timestamptz;
BEGIN
 SELECT id INTO v_me FROM public.jb_employees
  WHERE auth_user_id=(SELECT auth.uid()) AND active IS TRUE;
 IF v_me IS NULL THEN
  RAISE EXCEPTION '활성 직원만 댓글을 확인할 수 있습니다' USING ERRCODE='42501';
 END IF;
 UPDATE public.jb_task_comment_attention_v13 a
 SET acknowledged_at=now()
 WHERE a.comment_id=p_comment_id
   AND a.employee_id=v_me
   AND a.acknowledged_at IS NULL
   AND EXISTS(SELECT 1 FROM public.jb_tasks t
              WHERE t.id=a.task_id AND t.assignee_id=v_me)
 RETURNING a.acknowledged_at INTO v_ack;
 IF v_ack IS NULL THEN
  RAISE EXCEPTION '본인에게 온 미확인 댓글이 없습니다' USING ERRCODE='42501';
 END IF;
 RETURN v_ack;
END;
$fn$;

REVOKE ALL ON FUNCTION public.jb_task_comment_notify_v13() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jb_acknowledge_task_comment_v13(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.jb_acknowledge_task_comment_v13(uuid) TO authenticated;
COMMIT;

-- [조회용/설치 검증] 별도 실행:
-- SELECT count(*) FROM public.jb_task_comment_attention_v13;
-- SELECT tgname,tgenabled FROM pg_trigger WHERE tgrelid='public.jb_task_comments'::regclass AND tgname='jb_task_comment_notify_insert_v13';
-- [삭제용/롤백] 필요할 때만 별도 실행:
-- DROP TRIGGER IF EXISTS jb_task_comment_notify_insert_v13 ON public.jb_task_comments;
-- DROP FUNCTION IF EXISTS public.jb_task_comment_notify_v13();
-- DROP FUNCTION IF EXISTS public.jb_acknowledge_task_comment_v13(uuid);
-- DROP TABLE IF EXISTS public.jb_task_comment_attention_v13;
