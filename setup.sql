-- شغّل هذا الملف مرة واحدة في Supabase > SQL Editor.
create table if not exists public.phone_numbers (
  id bigint generated always as identity primary key,
  phone text not null unique,
  created_at timestamptz not null default now(),
  copied_at timestamptz
);
create index if not exists phone_numbers_uncopied_idx on public.phone_numbers(created_at, id) where copied_at is null;
alter table public.phone_numbers enable row level security;
revoke all on public.phone_numbers from anon, authenticated;
grant select on public.phone_numbers to authenticated;
drop policy if exists team_read on public.phone_numbers;
create policy team_read on public.phone_numbers for select to authenticated using (true);

-- إضافة الأرقام والتحقق من أنها أرقام موبايل مصرية سليمة.
create or replace function public.add_phone_numbers(p_numbers text[], p_already_used boolean default false)
returns table(added integer, existing integer)
language plpgsql security definer set search_path = public, pg_temp
as $$
declare x text; n_added integer := 0; n_existing integer := 0; changed integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if coalesce(array_length(p_numbers, 1), 0) > 10000 then raise exception 'Maximum 10000 numbers per request'; end if;
  foreach x in array p_numbers loop
    if x !~ '^\+201[0125][0-9]{8}$' then continue; end if;
    insert into public.phone_numbers(phone, copied_at)
      values(x, case when p_already_used then now() else null end)
      on conflict (phone) do nothing;
    get diagnostics changed = row_count;
    if changed = 1 then n_added := n_added + 1;
    else
      n_existing := n_existing + 1;
      if p_already_used then
        update public.phone_numbers set copied_at = coalesce(copied_at, now()) where phone = x;
      end if;
    end if;
  end loop;
  return query select n_added, n_existing;
end $$;

-- حجز دفعة واحدة بشكل ذري، فلا يحصل مستخدمان على نفس الأرقام.
create or replace function public.claim_phone_batch(p_size integer default 25)
returns table(phone text)
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_size <> 25 then raise exception 'Batch size must be 25'; end if;
  return query
  with picked as (
    select id from public.phone_numbers
    where copied_at is null
    order by created_at, id limit p_size for update skip locked
  ), claimed as (
    update public.phone_numbers t set copied_at = now()
    from picked where t.id = picked.id
    returning t.id, t.phone
  )
  select c.phone from claimed c order by c.id;
end $$;

revoke all on function public.add_phone_numbers(text[], boolean) from public, anon;
revoke all on function public.claim_phone_batch(integer) from public, anon;
grant execute on function public.add_phone_numbers(text[], boolean) to authenticated;
grant execute on function public.claim_phone_batch(integer) to authenticated;
