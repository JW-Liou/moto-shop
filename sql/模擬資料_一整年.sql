-- =====================================================================
-- 模擬資料：一整年（2025-11-13 ～ 2026-11-12）壓力測試
-- 接在原本那一週（11/13 ～ 11/19）的前面
-- 如果之前跑過「加一個月」，會先把那個月的模擬資料刪掉，避免重複
-- 內容：新客 320 位（陸續在這一年加入）、約 3,000 張工單、約 280 筆預約
-- 執行前先到「匯入／備份」按一鍵備份
-- =====================================================================

-- 0. 先清掉之前「加一個月」產生的模擬資料（沒跑過也沒關係）
delete from service_records where date between '2025-11-13' and '2026-11-12';
delete from appointments   where date between '2025-11-13' and '2026-11-12';
delete from customers where note = '模擬資料';      -- 車和工單會跟著刪除

do $$
declare
  surnames text[] := array['陳','林','黃','張','李','王','吳','劉','蔡','楊','許','鄭','謝','郭','洪','曾','邱','廖','賴','周'];
  givens   text[] := array['志明','雅婷','家豪','怡君','冠宇','淑芬','俊傑','美玲','建宏','佩珊','宗翰','欣怡','承恩','柏翰','思妤','子晴','宇軒','品妍'];
  models   text[] := array['勁戰六代','JET SL','DRG','MMBCU','Many 110','Gogoro VIVA','BWS','KRV','FORCE 2.0','迪爵 125','JETS','新名流'];
  item_names  text[] := array['機油','齒輪油','空濾','火星塞','煞車皮','煞車油','輪胎','皮帶','普利珠','電瓶'];
  item_prices int[]  := array[ 350,   150,    300,   250,     500,    300,    1600,  900,   400,    1300];
  item_odds   numeric[] := array[0.85, 0.55,  0.25,  0.15,    0.12,   0.06,   0.08,  0.05,  0.05,   0.05];

  first_day date := '2025-11-13';
  last_day  date := '2026-11-12';
  week_end  date := '2026-11-13';

  d date; n int; i int; k int; cnt int;
  cid bigint; bid bigint; new_plate text;
  b record;
  its text[]; total int; km int; opened timestamp; hrs numeric; r numeric; busy numeric;
begin
  perform setseed(0.2025);

  -- 每台車「從哪一天開始會來店」：原本的車一開始就在，新客陸續加入
  create temp table sim_pool (bike_id bigint, from_date date, mileage int) on commit drop;
  insert into sim_pool select id, first_day, mileage from bikes;

  -- 1. 新客 320 位，各一台車，加入日期平均分散在這一年
  for i in 1..320 loop
    insert into customers (name, phone, note)
    values (surnames[1 + floor(random() * 20)::int] || givens[1 + floor(random() * 18)::int],
            '0900-' || lpad((100 + floor(random() * 900))::text, 3, '0') || '-' || lpad(floor(random() * 1000)::text, 3, '0'),
            '模擬資料')
    returning id into cid;

    loop
      new_plate := chr(65 + floor(random() * 26)::int) || chr(65 + floor(random() * 26)::int) || chr(65 + floor(random() * 26)::int)
                   || (1000 + floor(random() * 9000))::int;
      exit when not exists (select 1 from bikes where plate = new_plate);
    end loop;

    insert into bikes (customer_id, plate, model, year, mileage)
    values (cid, new_plate, models[1 + floor(random() * 12)::int],
            case when random() < 0.08 then null else 2010 + floor(random() * 16)::int end,
            5000 + floor(random() * 30000)::int)
    returning id into bid;

    insert into sim_pool select bid, first_day + floor(random() * 360)::int, mileage from bikes where id = bid;
  end loop;

  -- 2. 每天的工單
  for d in select generate_series(first_day, last_day, interval '1 day')::date loop
    -- 淡旺季：過年前一週最忙、過年休息、夏天稍忙
    busy := case
              when d between '2026-02-16' and '2026-02-20' then 0               -- 春節休息
              when d between '2026-02-07' and '2026-02-15' then 1.6             -- 過年前
              when extract(month from d) in (7, 8) then 1.2
              when extract(month from d) in (1, 12) then 0.9
              else 1
            end;
    n := round(busy * case extract(dow from d)
           when 0 then floor(random() * 3)                -- 週日 0～2 台
           when 6 then 11 + floor(random() * 6)           -- 週六 11～16 台
           when 5 then 8 + floor(random() * 5)            -- 週五 8～12 台
           else 6 + floor(random() * 5)                   -- 平日 6～10 台
         end)::int;

    select count(*) into cnt from sim_pool where from_date <= d;

    for i in 1..n loop
      -- 熟客比較常來：排序後偏向前面的車
      select p.bike_id, p.mileage, p.from_date into b
      from sim_pool p where p.from_date <= d
      order by p.bike_id offset floor(power(random(), 1.5) * cnt)::int limit 1;

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
      total := total + (floor(random() * 5) * 50)::int;

      -- 里程：每天約 12 公里，越早越少
      km := greatest(300, coalesce(b.mileage, 12000) - (week_end - d) * 12 - 100);

      opened := d + make_interval(hours => 9 + floor(random() * 11)::int, mins => floor(random() * 60)::int);
      hrs := 0.5 + random() * 3.5;

      insert into service_records (bike_id, date, mileage, items, parts, total, status, next_service_km, created_at, completed_at)
      values (b.bike_id, d, km, array_to_string(its, '、'),
              case when '機油' = any(its) then '機油 0.8L' else '' end,
              total, '已完成',
              case when '機油' = any(its) then km + 1000 end,
              opened at time zone 'Asia/Taipei',
              (opened + make_interval(secs => hrs * 3600)) at time zone 'Asia/Taipei');
    end loop;

    -- 3. 預約：營業日約八成有一筆
    if busy > 0 and extract(dow from d) <> 0 and random() < 0.8 then
      r := random();
      select bk.plate, c.name, c.phone into b
      from sim_pool p join bikes bk on bk.id = p.bike_id left join customers c on c.id = bk.customer_id
      where p.from_date <= d
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

-- 4. 看看加了多少、資料庫多大
select '客戶' as 資料, count(*)::text as 數量 from customers
union all select '車輛', count(*)::text from bikes
union all select '工單（全部）', count(*)::text from service_records
union all select '預約（全部）', count(*)::text from appointments
union all select '這一年的營收', to_char(sum(total), 'FM999,999,999') from service_records where date between '2025-11-13' and '2026-11-12'
union all select '資料庫大小', pg_size_pretty(pg_database_size(current_database()));


-- =====================================================================
-- 想刪掉這一年的模擬資料時，把下面的 -- 拿掉再執行
-- （會回到原本那一週的資料）
-- =====================================================================
-- delete from service_records where date between '2025-11-13' and '2026-11-12';
-- delete from appointments   where date between '2025-11-13' and '2026-11-12';
-- delete from customers where note = '模擬資料';
