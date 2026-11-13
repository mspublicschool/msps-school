-- ============================================================
-- প্রধান শিক্ষক (head01) এর ভূমিকা যোগ করা
-- আগে supabase-setup.sql ও supabase-phase2.sql এই প্রজেক্টে চালাতে হবে।
-- UID অবশ্যই এই প্রজেক্টের Authentication → Users থেকে নিতে হবে।
-- ============================================================

insert into user_roles (user_id, role, login_id)
select u.id, 'head', 'head01'
from auth.users u
where u.id = 'ed8232dc-9cf6-4db9-b52e-7d14f9094cef'::uuid
on conflict (user_id) do update
  set role = 'head', login_id = 'head01', status = 'active', updated_at = now();

-- ফলাফল যাচাই: এই সারিটি দেখালে সফল
select user_id, role, login_id, status
from user_roles
where login_id = 'head01';
