-- =====================================================================
-- 操作紀錄與垃圾桶
-- 1. activity_log：每次新增、修改、刪除客戶／車輛／工單／預約，都自動記一筆
-- 2. 刪除的資料會留在紀錄裡 180 天，可以在「匯入／備份」頁的垃圾桶救回
-- 3. restore_deleted()：救回一筆刪除的資料
-- 可以重複執行，不會出錯
-- =====================================================================

-- 1. 紀錄表
create table if not exists public.activity_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),   -- 什麼時候
  table_name  text not null,                        -- 哪一張表
  action      text not null,                        -- INSERT 新增／UPDATE 修改／DELETE 刪除／RESTORE 救回
  row_id      bigint,                               -- 那筆資料的 id
  old_data    jsonb,                                -- 改之前（刪除時就是被刪掉的內容）
  new_data    jsonb,                                -- 改之後
  device      text,                                 -- 用哪一種裝置操作的
  restored_at timestamptz                           -- 救回的時間（還沒救回是空的）
);
create index if not exists activity_log_at_idx on public.activity_log (at desc);

-- 只有員工能看紀錄、標記「已救回」；不開放直接新增或刪除紀錄（只能由下面的觸發器寫入）
alter table public.activity_log enable row level security;
drop policy if exists "staff read log" on public.activity_log;
create policy "staff read log" on public.activity_log
  for select to authenticated using ((select public.is_staff()));
drop policy if exists "staff mark restored" on public.activity_log;
create policy "staff mark restored" on public.activity_log
  for update to authenticated using ((select public.is_staff())) with check ((select public.is_staff()));

-- 2. 觸發器：資料一有變動就自動記下來
create or replace function public.log_change()
returns trigger
language plpgsql
security definer          -- 用建立者的權限寫紀錄，使用者沒辦法自己偽造紀錄
set search_path = ''
as $$
declare
  ua  text := coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'user-agent', '');
  dev text;
begin
  -- 修改但內容沒有變，就不記
  if tg_op = 'UPDATE' and to_jsonb(old) = to_jsonb(new) then
    return new;
  end if;

  dev := case
    when ua = ''                then '資料庫後台'
    when ua ~* 'iphone'         then 'iPhone'
    when ua ~* 'ipad'           then 'iPad'
    when ua ~* 'android'        then 'Android 手機'
    when ua ~* 'windows'        then 'Windows 電腦'
    when ua ~* 'macintosh'      then 'Mac 電腦'
    else '其他裝置'
  end;

  insert into public.activity_log (table_name, action, row_id, old_data, new_data, device)
  values (
    tg_table_name,
    tg_op,
    case when tg_op = 'DELETE' then old.id else new.id end,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    case when tg_op <> 'DELETE' then to_jsonb(new) end,
    dev
  );

  -- 偶爾清掉 180 天以前的紀錄，避免越來越大
  if random() < 0.01 then
    delete from public.activity_log where at < now() - interval '180 days';
  end if;

  return coalesce(new, old);
end $$;

revoke execute on function public.log_change() from public, anon, authenticated;

drop trigger if exists log_changes on public.customers;
create trigger log_changes after insert or update or delete on public.customers
  for each row execute function public.log_change();

drop trigger if exists log_changes on public.bikes;
create trigger log_changes after insert or update or delete on public.bikes
  for each row execute function public.log_change();

drop trigger if exists log_changes on public.service_records;
create trigger log_changes after insert or update or delete on public.service_records
  for each row execute function public.log_change();

drop trigger if exists log_changes on public.appointments;
create trigger log_changes after insert or update or delete on public.appointments
  for each row execute function public.log_change();

-- 3. 救回刪除的資料（用使用者自己的權限執行，一樣受 RLS 保護）
create or replace function public.restore_deleted(log_id bigint)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  l    public.activity_log%rowtype;
  cols text;
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;

  select * into l from public.activity_log where id = log_id and action = 'DELETE';
  if not found then
    raise exception '找不到這筆刪除紀錄';
  end if;
  if l.restored_at is not null then
    raise exception '這筆已經救回過了';
  end if;
  if l.table_name not in ('customers', 'bikes', 'service_records', 'appointments') then
    raise exception '這種資料不能救回';
  end if;

  -- 欄位清單（跳過 phone_digits 這種資料庫自動算的欄位）
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
  from information_schema.columns
  where table_schema = 'public' and table_name = l.table_name and is_generated = 'NEVER';

  begin
    -- 用原本的 id 放回去，這樣它的工單、預約都會接得上
    execute format(
      'insert into public.%I (%s) overriding system value select %s from jsonb_populate_record(null::public.%I, $1)',
      l.table_name, cols, cols, l.table_name
    ) using l.old_data;
  exception
    when foreign_key_violation then
      raise exception '它所屬的車輛或客戶也被刪掉了，請先救回那一筆';
    when unique_violation then
      raise exception '已經有一樣的資料（例如同一個車牌）存在，不能救回';
  end;

  update public.activity_log set restored_at = now() where id = log_id;
  -- 放回去的那一筆，紀錄上寫「救回」，不要寫成「新增」
  update public.activity_log set action = 'RESTORE'
  where id = (select max(id) from public.activity_log
              where table_name = l.table_name and row_id = l.row_id and action = 'INSERT');
  return 'ok';
end $$;

revoke execute on function public.restore_deleted(bigint) from public, anon;
grant execute on function public.restore_deleted(bigint) to authenticated;

-- 4. 確認：應該看到 4 張表各有一個 log_changes 觸發器
select event_object_table as 資料表, count(*) / 3 as 觸發器數
from information_schema.triggers
where trigger_name = 'log_changes'
group by 1 order by 1;
