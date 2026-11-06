-- ============================================================
-- এম.এস. পাবলিক স্কুল — ফেজ ২: ফি, ভাউচার, নম্বর ও অডিটর ভূমিকা
-- চালানোর ক্রম: supabase-setup.sql → supabase-phase2.sql → supabase-documents.sql → এই ফাইল
-- idempotent: একাধিকবার চালালেও সমস্যা হবে না। কোনো ডেটা মুছবে না।
-- ============================================================

-- ------------------------------------------------------------
-- 1. অডিটর ভূমিকা (শুধু দেখা, কিছু বদলানো যাবে না)
-- ------------------------------------------------------------
alter table user_roles add column if not exists expires_at timestamptz;
alter table user_roles drop constraint if exists user_roles_role_check;
alter table user_roles add constraint user_roles_role_check
  check (role in ('head','class_teacher','parent','auditor'));

create or replace function is_auditor()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from user_roles
    where user_id = auth.uid() and role = 'auditor' and status = 'active'
      and (expires_at is null or expires_at > now())
  );
$$;

-- ------------------------------------------------------------
-- 2. ফি আদায় (রসিদ)
-- ------------------------------------------------------------
create table if not exists fee_payments (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references students(id) on delete restrict,
  receipt_no    int,
  paid_on       date not null default current_date,
  amount        numeric(10,2) not null check (amount >= 0),
  items         jsonb not null default '[]'::jsonb,   -- যেমন [{"name":"মাসিক বেতন","amount":300}]
  collected_by  uuid default auth.uid(),
  created_at    timestamptz not null default now()
);
create index if not exists fee_payments_student_idx on fee_payments(student_id);
create index if not exists fee_payments_paid_idx on fee_payments(paid_on);

alter table fee_payments enable row level security;

drop policy if exists "fee read" on fee_payments;
create policy "fee read" on fee_payments for select to authenticated
  using (can_see_student(student_id) or is_auditor());

drop policy if exists "fee insert" on fee_payments;
create policy "fee insert" on fee_payments for insert to authenticated
  with check (can_see_student(student_id) and collected_by = auth.uid());

drop policy if exists "fee head update" on fee_payments;
create policy "fee head update" on fee_payments for update to authenticated
  using (is_head()) with check (is_head());
-- কোনো delete নীতি নেই: রসিদ মোছা যাবে না (শুধু প্রধান শিক্ষক সংশোধন করতে পারবেন)

-- ------------------------------------------------------------
-- 3. ভাউচার ও খরচ (শ্রেণির সঙ্গে যুক্ত নয়, জমাদানকারীর নিজস্ব)
-- ------------------------------------------------------------
create table if not exists vouchers (
  id            uuid primary key default gen_random_uuid(),
  voucher_no    int,
  submitted_by  uuid not null default auth.uid() references auth.users(id) on delete restrict,
  voucher_date  date not null default current_date,
  category      text not null,
  description   text not null,
  amount        numeric(10,2) not null check (amount > 0),
  status        text not null default 'pending' check (status in ('pending','approved','rejected')),
  teacher_id    uuid references teachers(id) on delete set null,   -- বেতন ভাউচারের জন্য
  salary_month  text,                                               -- 'YYYY-MM', বেতন ভাউচারে
  decided_by    uuid,
  decided_on    date,
  created_at    timestamptz not null default now()
);
create index if not exists vouchers_status_idx on vouchers(status);
create index if not exists vouchers_date_idx on vouchers(voucher_date);

alter table vouchers enable row level security;

drop policy if exists "voucher read" on vouchers;
create policy "voucher read" on vouchers for select to authenticated
  using (submitted_by = auth.uid() or is_head() or is_auditor());

drop policy if exists "voucher insert" on vouchers;
create policy "voucher insert" on vouchers for insert to authenticated
  with check (submitted_by = auth.uid() and is_staff() and status = 'pending');

drop policy if exists "voucher head update" on vouchers;
create policy "voucher head update" on vouchers for update to authenticated
  using (is_head()) with check (is_head());

-- ------------------------------------------------------------
-- 4. পরীক্ষার নম্বর (বিষয়ভিত্তিক)
-- ------------------------------------------------------------
create table if not exists exam_marks (
  student_id    uuid not null references students(id) on delete cascade,
  exam          text not null,          -- যেমন 'M1', 'T1', 'T2', 'T3' (app-এর exam কোড)
  subject_index int  not null,
  mark          numeric(6,2),           -- null = এন্ট্রি হয়নি
  absent        boolean not null default false,
  updated_at    timestamptz not null default now(),
  updated_by    uuid default auth.uid(),
  primary key (student_id, exam, subject_index)
);

alter table exam_marks enable row level security;

drop policy if exists "marks read" on exam_marks;
create policy "marks read" on exam_marks for select to authenticated
  using (can_see_student(student_id));

drop policy if exists "marks write" on exam_marks;
create policy "marks write" on exam_marks for all to authenticated
  using (can_see_student(student_id) and is_staff())
  with check (can_see_student(student_id) and is_staff());
-- অডিটর নম্বর সরাসরি দেখবেন না; পাসের হার সমষ্টি আকারে দেখবেন

-- টেবিল-স্তরের অনুমতি (সীমা RLS নীতিতে); টেবিল তৈরির পরে
grant select, insert, update on fee_payments, vouchers, exam_marks to authenticated;

-- ------------------------------------------------------------
-- 5. অডিটর দেখবে: শিক্ষার্থীর নিরাপদ তালিকা (ফোন, ঠিকানা, অভিভাবকের নাম নেই)
-- ------------------------------------------------------------
create or replace view audit_student_list as
  select s.id, s.name, c.name as class_name, s.roll, s.status
  from students s
  join classes c on c.id = s.class_id
  where is_head() or is_auditor();

revoke all on audit_student_list from anon;
grant select on audit_student_list to authenticated;

-- অডিটর অডিট লগ দেখতে পারবেন (শুধু পড়া)
drop policy if exists "auditor read audit" on audit_logs;
create policy "auditor read audit" on audit_logs for select to authenticated
  using (is_auditor());

-- ------------------------------------------------------------
-- 6. সমষ্টিগত অডিট হিসাব (প্রধান শিক্ষক ও অডিটর ছাড়া কেউ নয়)
-- ------------------------------------------------------------
create or replace function audit_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_head() or is_auditor()) then
    raise exception 'শুধু প্রধান শিক্ষক বা অডিটর এই তথ্য দেখতে পারবেন';
  end if;
  return jsonb_build_object(
    'income_by_month', coalesce((
      select jsonb_agg(jsonb_build_object('month', m, 'amount', amt) order by m) from (
        select to_char(paid_on, 'YYYY-MM') m, sum(amount) amt
        from fee_payments where paid_on between p_from and p_to group by 1) x), '[]'::jsonb),
    'expense_by_month', coalesce((
      select jsonb_agg(jsonb_build_object('month', m, 'amount', amt) order by m) from (
        select to_char(voucher_date, 'YYYY-MM') m, sum(amount) amt
        from vouchers where status = 'approved' and voucher_date between p_from and p_to group by 1) x), '[]'::jsonb),
    'expense_by_category', coalesce((
      select jsonb_agg(jsonb_build_object('category', category, 'amount', amt) order by amt desc) from (
        select category, sum(amount) amt
        from vouchers where status = 'approved' and voucher_date between p_from and p_to group by 1) x), '[]'::jsonb),
    'voucher_status', coalesce((
      select jsonb_agg(jsonb_build_object('status', status, 'count', n, 'amount', amt)) from (
        select status, count(*) n, sum(amount) amt
        from vouchers where voucher_date between p_from and p_to group by 1) x), '[]'::jsonb),
    'students_by_class', coalesce((
      select jsonb_agg(jsonb_build_object('class', c.name, 'count', n) order by c.sort_order) from (
        select class_id, count(*) n from students where status = 'active' group by 1) x
        join classes c on c.id = x.class_id), '[]'::jsonb)
  );
end;
$$;

revoke all on function audit_summary(date, date) from anon;
grant execute on function audit_summary(date, date) to authenticated;
