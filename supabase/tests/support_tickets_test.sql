begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(22);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
select
  '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  email, 'test-password', now(),
  jsonb_build_object('provider', 'email', 'providers', array['email']),
  jsonb_build_object('full_name', full_name), now(), now(), '', '', '', ''
from (
  values
    ('5a000000-0000-0000-0000-000000000001'::uuid, 'support-internal@example.test', 'Support Internal'),
    ('5a000000-0000-0000-0000-000000000002'::uuid, 'support-external@example.test', 'Support External'),
    ('5a000000-0000-0000-0000-000000000003'::uuid, 'support-renter@example.test', 'Support Renter'),
    ('5a000000-0000-0000-0000-000000000004'::uuid, 'support-other@example.test', 'Other Renter')
) as users(id, email, full_name)
on conflict (id) do nothing;

update public.profiles set role = 'internal_admin', account_status = 'active'
where id = '5a000000-0000-0000-0000-000000000001';
update public.profiles set role = 'external_admin', account_status = 'active'
where id = '5a000000-0000-0000-0000-000000000002';
update public.profiles set account_status = 'active'
where id in ('5a000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000004');

select has_table('public', 'support_tickets', 'support_tickets exists');
select has_table('public', 'support_ticket_replies', 'support_ticket_replies exists');
select ok(
  not has_table_privilege('authenticated', 'public.support_tickets', 'insert'),
  'clients cannot insert tickets directly'
);
select ok(
  'support_tickets' = any (public.system_backup_tables())
    and 'support_ticket_replies' = any (public.system_backup_tables()),
  'tickets and replies are backed up'
);

-- ---------------------------------------------------------------------
-- A renter files a ticket
-- ---------------------------------------------------------------------

select set_config('request.jwt.claim.sub', '5a000000-0000-0000-0000-000000000003', true);
set local role authenticated;

select throws_ok(
  $$select public.create_support_ticket('payment', 'Hi', 'too short')$$,
  '23514', null, 'subject and message lengths are enforced'
);
select throws_ok(
  $$select public.create_support_ticket('payment', 'GCash proof failed',
    'The upload spins forever on my phone.',
    '5a000000-0000-0000-0000-000000000004/shot.png')$$,
  '22023', null, 'a screenshot from someone else''s folder is refused'
);

create temp table ticket_ids (id uuid);
grant select, insert on ticket_ids to authenticated;
insert into ticket_ids
select (public.create_support_ticket('payment', 'GCash proof failed',
  'The upload spins forever on my phone.',
  '5a000000-0000-0000-0000-000000000003/shot.png')).id;

select is(
  (select status from public.support_tickets where id = (select id from ticket_ids)),
  'open', 'a new ticket is open'
);
reset role;

select ok(
  exists (select 1 from public.app_notifications
    where kind = 'support_ticket_new' and support_ticket_id = (select id from ticket_ids)
      and recipient_id = '5a000000-0000-0000-0000-000000000001')
  and not exists (select 1 from public.app_notifications n
    join public.profiles p on p.id = n.recipient_id
    where n.kind = 'support_ticket_new' and n.support_ticket_id = (select id from ticket_ids)
      and p.role <> 'internal_admin'),
  'Internal Admins, and only they, are told about the new ticket'
);

-- ---------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------

select set_config('request.jwt.claim.sub', '5a000000-0000-0000-0000-000000000004', true);
set local role authenticated;
select is(
  (select count(*) from public.support_tickets), 0::bigint,
  'another renter cannot see the ticket'
);
select throws_ok(
  format($$select public.reply_support_ticket(%L, 'Me too, same problem')$$,
    (select id from ticket_ids)),
  'P0002', null, 'another renter cannot reply'
);
reset role;

select set_config('request.jwt.claim.sub', '5a000000-0000-0000-0000-000000000002', true);
set local role authenticated;
select is(
  (select count(*) from public.support_tickets where id = (select id from ticket_ids)),
  1::bigint, 'an External Admin can see the queue'
);
reset role;

-- ---------------------------------------------------------------------
-- The conversation
-- ---------------------------------------------------------------------

select set_config('request.jwt.claim.sub', '5a000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select lives_ok(
  format($$select public.reply_support_ticket(%L, 'Please try again on Wi-Fi.')$$,
    (select id from ticket_ids)),
  'an admin replies'
);
reset role;

select is(
  (select status from public.support_tickets where id = (select id from ticket_ids)),
  'in_progress', 'an admin reply picks the ticket up'
);
select is(
  (select count(*) from public.app_notifications
   where kind = 'support_reply' and recipient_id = '5a000000-0000-0000-0000-000000000003'),
  1::bigint, 'the requester is told about the reply'
);

select set_config('request.jwt.claim.sub', '5a000000-0000-0000-0000-000000000003', true);
set local role authenticated;
select lives_ok(
  format($$select public.reply_support_ticket(%L, 'Still failing on Wi-Fi.')$$,
    (select id from ticket_ids)),
  'the requester answers'
);
select throws_ok(
  format($$select public.set_support_ticket_status(%L, 'resolved')$$,
    (select id from ticket_ids)),
  '42501', null, 'a requester cannot resolve their own ticket'
);
select is(
  (select count(*) from public.support_ticket_replies
   where ticket_id = (select id from ticket_ids)),
  2::bigint, 'the requester can read the whole thread'
);
reset role;

select is(
  (select count(*) from public.app_notifications
   where kind = 'support_reply' and recipient_id = '5a000000-0000-0000-0000-000000000001'),
  1::bigint, 'the admin who answered hears back'
);

select set_config('request.jwt.claim.sub', '5a000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select lives_ok(
  format($$select public.set_support_ticket_status(%L, 'resolved')$$,
    (select id from ticket_ids)),
  'an admin resolves the ticket'
);
reset role;

select is(
  (select count(*) from public.app_notifications
   where kind = 'support_status' and recipient_id = '5a000000-0000-0000-0000-000000000003'),
  1::bigint, 'the requester is told it was resolved'
);

select set_config('request.jwt.claim.sub', '5a000000-0000-0000-0000-000000000003', true);
set local role authenticated;
select public.reply_support_ticket((select id from ticket_ids), 'It broke again today.');
reset role;
select is(
  (select status from public.support_tickets where id = (select id from ticket_ids)),
  'open', 'a requester reply reopens a resolved ticket'
);

select set_config('request.jwt.claim.sub', '5a000000-0000-0000-0000-000000000003', true);
set local role authenticated;
select public.set_support_ticket_status((select id from ticket_ids), 'closed');
select throws_ok(
  format($$select public.reply_support_ticket(%L, 'One more thing')$$,
    (select id from ticket_ids)),
  '22023', null, 'a closed ticket takes no replies'
);
reset role;

select * from finish();
rollback;
