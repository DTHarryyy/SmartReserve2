begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(3);

create temp table notification_inbox_fixture as
select
  (select id from public.profiles order by created_at limit 1) as owner_id,
  (select id from public.profiles order by created_at offset 1 limit 1) as other_id,
  gen_random_uuid() as unread_id,
  gen_random_uuid() as read_id,
  gen_random_uuid() as other_id_notification;

insert into public.app_notifications(id, recipient_id, kind, title, body, read_at)
select unread_id, owner_id, 'inbox_unread_test', 'Inbox unread test', 'Unread', null
from notification_inbox_fixture
union all
select read_id, owner_id, 'inbox_read_test', 'Inbox read test', 'Read', now()
from notification_inbox_fixture
union all
select other_id_notification, other_id, 'inbox_other_test', 'Inbox other test', 'Other', null
from notification_inbox_fixture;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  (select owner_id::text from notification_inbox_fixture),
  true
);

select is(
  (
    select count(*)::integer
    from jsonb_array_elements(
      public.assistant_my_announcements(10) -> 'notices'
    ) notice
    where notice ->> 'title' = 'Inbox unread test'
  ),
  1,
  'assistant announcements include an unread notification'
);

select is(
  (
    select count(*)::integer
    from jsonb_array_elements(
      public.assistant_my_announcements(10) -> 'notices'
    ) notice
    where notice ->> 'title' = 'Inbox read test'
  ),
  0,
  'assistant announcements exclude read notifications'
);

select public.mark_my_notification_read(
  (select other_id_notification from notification_inbox_fixture)
);

reset role;
select is(
  (
    select read_at
    from public.app_notifications
    where id = (select other_id_notification from notification_inbox_fixture)
  ),
  null::timestamptz,
  'a caller cannot mark another account notification as read'
);

select * from finish();
rollback;
