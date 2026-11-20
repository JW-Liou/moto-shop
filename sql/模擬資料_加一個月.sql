-- =====================================================================
-- 模擬資料：再加一個月（2026-10-13 ～ 2026-11-12）
-- 接在原本那一週（11/13 ～ 11/19）的前面，不會刪掉任何現有資料
-- 內容：新客 15 位（各一台車）、約 130 張已完成工單、約 25 筆預約
-- 執行前先到「匯入／備份」按一鍵備份
-- =====================================================================

do $$
declare
  surnames text[] := array['陳','林','黃','張','李','王','吳','劉','蔡','楊','許','鄭','謝','郭','洪'];
  givens   text[] := array['志明','雅婷','家豪','怡君','冠宇','淑芬','俊傑','美玲','建宏','佩珊','宗翰','欣怡','承恩','柏翰','思妤'];
  models   text[] := array['勁戰六代','JET SL','DRG','MMBCU','Many 110','Gogoro VIVA','BWS','KRV','FORCE 2.0','迪爵 125'];
  -- 項目與價格（含工資，元）
  item_names  text[] := array['機油','齒輪油','空濾','火星塞','煞車皮','煞車油','輪胎','皮帶','普利珠','電瓶'];
  item_prices int[]  := array[ 350,   150,    300,   250,     500,    300,    1600,  900,   400,    1300];
  item_odds   numeric[] := array[0.85, 0.55,  0.25,  0.15,    0.12,   0.06,   0.08,  0.05,  0.05,   0.05];

  first_day date := '2026-10-13';
  last_day  date := '2026-11-12';
  week_end  date := '2026-11-13';          -- 原本那一週的第一天，里程以這天往回推

  d date; n int; i int; k int;
  cid bigint; new_plate text;
  b record;
  its text[]; total int; km int; opened timestamp; hrs numeric; r numeric;
begin
  perform setseed(0.2026);

  -- 1. 新客 15 位，各有一台車（備註標記「模擬資料」，方便以後刪除）
  for i in 1..15 loop
    insert into customers (name, phone, note)
    values (surnames[1 + floor(random() * 15)::int] || givens[1 + floor(random() * 15)::int],
            '0900-' || lpad((100 + floor(random() * 900))::text, 3, '0') || '-' || lpad(floor(random() * 1000)::text, 3, '0'),
            '模擬資料')
    returning id into cid;

    loop  -- 產生不重複的車牌，例如 KTR5821
      new_plate := chr(65 + floor(random() * 26)::int) || chr(65 + floor(random() * 26)::int) || chr(65 + floor(random() * 26)::int)
                   || (1000 + floor(random() * 9000))::int;
      exit when not exists (select 1 from bikes where plate = new_plate);
    end loop;

    insert into bikes (customer_id, plate, model, year, mileage)
    values (cid, new_plate, models[1 + floor(random() * 10)::int], 2012 + floor(random() * 14)::int, 6000 + floor(random() * 25000)::int);
  end loop;

  -- 2. 每天的工單：週六最多、週日最少
  for d in select generate_series(first_day, last_day, interval '1 day')::date loop
    n := case extract(dow from d)
           when 0 then floor(random() * 2)::int        -- 週日 0～1 台
           when 6 then 6 + floor(random() * 3)::int    -- 週六 6～8 台
           when 5 then 4 + floor(random() * 3)::int    -- 週五 4～6 台
           else 3 + floor(random() * 3)::int           -- 平日 3～5 台
         end;

    for i in 1..n loop
      select * into b from bikes order by random() limit 1;

      -- 選項目：每個項目有自己的機率，至少要有一項
      its := '{}';
      total := 0;
      for k in 1..10 loop
        if random() < item_odds[k] then
          its := its || item_names[k];
          total := total + item_prices[k];
        end if;
      end loop;
      if cardinality(its) = 0 then
        its := array['機油'];
        total := 350;
      end if;
      total := total + (floor(random() * 5) * 50)::int;   -- 加一點工資差異

      -- 里程：比這台車目前的里程少，越早的日期少越多（每天約 25 公里）
      km := greatest(300, coalesce(b.mileage, 12000) - (week_end - d) * 25 - 200);

      -- 開單時間 9:00～19:59，修 0.5～4 小時（台灣時間）
      opened := d + make_interval(hours => 9 + floor(random() * 11)::int, mins => floor(random() * 60)::int);
      hrs := 0.5 + random() * 3.5;

      insert into service_records (bike_id, date, mileage, items, parts, total, status, next_service_km, created_at, completed_at)
      values (b.id, d, km, array_to_string(its, '、'),
              case when '機油' = any(its) then '機油 0.8L' else '' end,
              total, '已完成',
              case when '機油' = any(its) then km + 1000 end,
              opened at time zone 'Asia/Taipei',
              (opened + make_interval(secs => hrs * 3600)) at time zone 'Asia/Taipei');
    end loop;

    -- 3. 預約：約八成的日子有一筆
    if random() < 0.8 and extract(dow from d) <> 0 then
      r := random();   -- 決定這筆預約的結果：七成五到店、一成三取消、其他沒來
      select bk.plate, c.name, c.phone into b
      from bikes bk left join customers c on c.id = bk.customer_id
      order by random() limit 1;

      insert into appointments (date, time, plate, name, phone, items, status, source, created_at)
      values (d, make_time(10 + floor(random() * 8)::int, (floor(random() * 2) * 30)::int, 0),
              b.plate, coalesce(b.name, ''), coalesce(b.phone, ''), '機油、齒輪油',
              case when r < 0.75 then '已到店' when r < 0.88 then '取消' else '預約中' end,
              '店內',
              (d - 2)::timestamp at time zone 'Asia/Taipei');
    end if;
  end loop;
end $$;

-- 4. 看看加了多少
select '客戶' as 資料, count(*) as 筆數 from customers
union all select '車輛', count(*) from bikes
union all select '工單（10/13～11/12）', count(*) from service_records where date between '2026-10-13' and '2026-11-12'
union all select '工單（全部）', count(*) from service_records
union all select '預約（10/13～11/12）', count(*) from appointments where date between '2026-10-13' and '2026-11-12';


-- =====================================================================
-- 想刪掉這個月的模擬資料時，把下面的 -- 拿掉再執行
-- =====================================================================
-- delete from service_records where date between '2026-10-13' and '2026-11-12';
-- delete from appointments   where date between '2026-10-13' and '2026-11-12';
-- delete from customers where note = '模擬資料';   -- 車和車的工單會跟著刪除
