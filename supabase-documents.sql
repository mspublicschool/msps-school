-- ============================================================
-- ডাউনলোড (PDF/ছবি), নোটিশের সংযুক্তি ও গ্যালারির ধরন
-- এটি supabase-phase2.sql চালানোর পরে চালাতে হবে (is_head() ফাংশন লাগে)।
-- পুনরায় চালালেও সমস্যা হবে না।
-- ============================================================

create table if not exists documents (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  category    text not null default 'other'
              check (category in ('routine','syllabus','prospectus','question','other')),
  file_url    text not null,
  file_name   text,
  status      text not null default 'active' check (status in ('active','inactive')),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid()
);

alter table documents enable row level security;

drop policy if exists "public read active documents" on documents;
create policy "public read active documents" on documents
  for select using (status = 'active');

drop policy if exists "head write documents" on documents;
create policy "head write documents" on documents
  for all to authenticated using (is_head()) with check (is_head());

-- ধরনের তালিকায় "বুকলিস্ট" যোগ (আগের ফাইল চালানো থাকলেও এটি আবার চালাতে হবে)
alter table documents drop constraint if exists documents_category_check;
alter table documents add constraint documents_category_check
  check (category in ('routine','syllabus','prospectus','question','booklist','other'));

-- নোটিশে PDF বা ছবি সংযুক্তি
alter table notices add column if not exists attachment_url text;
alter table notices add column if not exists attachment_name text;

-- গ্যালারির ছবির ধরন
alter table gallery add column if not exists category text;
