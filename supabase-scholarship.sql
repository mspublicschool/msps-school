-- ============================================================
-- বৃত্তিপ্রাপ্ত শিক্ষার্থী (পাবলিক স্লাইডশো)
-- শুধু সক্রিয় ও অভিভাবকের লিখিত সম্মতি থাকা সারি পাবলিকে দেখাবে।
-- ফোন, ঠিকানা, আয় বা দারিদ্র্যের তথ্য এখানে রাখা হয় না।
-- idempotent: একাধিকবার চালালেও সমস্যা হবে না।
-- ============================================================

create table if not exists scholarship_recipients (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  class_name       text,
  scholarship_name text not null,
  provider         text not null default 'সরকারি' check (provider in ('সরকারি','বেসরকারি')),
  year             int,
  photo_url        text,
  consent          boolean not null default false,   -- অভিভাবকের লিখিত সম্মতি
  status           text not null default 'active' check (status in ('active','inactive')),
  created_at       timestamptz not null default now()
);

alter table scholarship_recipients enable row level security;

drop policy if exists "public read consented scholars" on scholarship_recipients;
create policy "public read consented scholars" on scholarship_recipients
  for select using (status = 'active' and consent = true);

drop policy if exists "head manage scholars" on scholarship_recipients;
create policy "head manage scholars" on scholarship_recipients
  for all to authenticated using (is_head()) with check (is_head());

grant select on scholarship_recipients to anon;
grant select, insert, update, delete on scholarship_recipients to authenticated;
