-- ══════════════════════════════════════════
-- VOC 대시보드 — 업체 매핑 공유 저장소 (Supabase)
-- Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 [Run] 한 번 실행하면 끝.
-- 다시 실행해도 안전합니다(이미 있는 데이터는 유지).
-- ══════════════════════════════════════════

-- 매핑 표: 대표명 1행 = 같은 업체로 묶을 이름들 (Table Editor 에서 직접 수정 가능)
create table if not exists public.partner_mapping (
  id         bigint generated always as identity primary key,
  canonical  text not null,
  aliases    text[] not null default '{}',
  updated_at timestamptz not null default now()
);
create unique index if not exists partner_mapping_canonical_uq on public.partner_mapping (lower(canonical));

-- 변경 기록 (언제 무엇이 바뀌었는지)
create table if not exists public.partner_mapping_log (
  id     bigint generated always as identity primary key,
  at     timestamptz not null default now(),
  op     text not null,
  detail text
);

-- 보안: 대시보드(anon 키)는 읽기만 직접 가능, 쓰기는 아래 함수로만
alter table public.partner_mapping enable row level security;
alter table public.partner_mapping_log enable row level security;
drop policy if exists "dashboard read" on public.partner_mapping;
create policy "dashboard read" on public.partner_mapping for select to anon, authenticated using (true);
drop policy if exists "dashboard read log" on public.partner_mapping_log;
create policy "dashboard read log" on public.partner_mapping_log for select to anon, authenticated using (true);
grant select on public.partner_mapping, public.partner_mapping_log to anon, authenticated;

-- 전체 매핑 + 마지막 수정 시각
create or replace function public.mapping_get()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ok', true,
    'mapping', coalesce((select jsonb_agg(jsonb_build_object('c', canonical, 'a', to_jsonb(aliases)) order by id) from partner_mapping), '[]'::jsonb),
    'updatedAt', greatest((select max(at) from partner_mapping_log), (select max(updated_at) from partner_mapping))
  );
$$;

-- 추가: 같은 대표명(대소문자 무시)이 있으면 이름만 합침(중복 제외) — 동시에 눌러도 안전
create or replace function public.mapping_add(p_c text, p_a text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare clean text[];
begin
  p_c := trim(coalesce(p_c, ''));
  select coalesce(array_agg(x order by o), '{}') into clean
    from (select distinct on (lower(trim(x))) trim(x) as x, o
            from unnest(coalesce(p_a, '{}')) with ordinality as t(x, o)
           where trim(x) <> '' order by lower(trim(x)), o) s;
  if p_c = '' or cardinality(clean) = 0 then raise exception '대표명과 이름이 필요합니다'; end if;
  insert into partner_mapping (canonical, aliases) values (p_c, clean)
  on conflict ((lower(canonical))) do update
    set aliases = partner_mapping.aliases || array(
          select x from unnest(excluded.aliases) as x
           where not exists (select 1 from unnest(partner_mapping.aliases) as y where lower(y) = lower(x))),
        updated_at = now();
  insert into partner_mapping_log (op, detail) values ('add', p_c || ' ← ' || array_to_string(clean, ', '));
  return mapping_get();
end $$;

-- 삭제
create or replace function public.mapping_delete(p_c text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  delete from partner_mapping where lower(canonical) = lower(trim(p_c));
  insert into partner_mapping_log (op, detail) values ('delete', p_c);
  return mapping_get();
end $$;

-- 통째로 교체 (가져오기 / 기본값으로 되돌리기)
create or replace function public.mapping_replace(p_m jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(p_m) <> 'array' then raise exception '매핑 형식 오류'; end if;
  lock table partner_mapping in exclusive mode;
  delete from partner_mapping where id is not null;
  insert into partner_mapping (canonical, aliases)
    select trim(e->>'c'), array(select trim(v) from jsonb_array_elements_text(coalesce(e->'a', '[]')) as v where trim(v) <> '')
      from jsonb_array_elements(p_m) with ordinality as t(e, o)
     where trim(coalesce(e->>'c', '')) <> ''
     order by o
  on conflict ((lower(canonical))) do nothing;
  insert into partner_mapping_log (op, detail) values ('replace', jsonb_array_length(p_m) || '개 그룹');
  return mapping_get();
end $$;

-- 처음 연결 시: 비어 있을 때만 대시보드의 기본 매핑으로 채움
create or replace function public.mapping_init(p_m jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  lock table partner_mapping in exclusive mode;
  if not exists (select 1 from partner_mapping) then
    perform mapping_replace(p_m);
  end if;
  return mapping_get();
end $$;

revoke all on function public.mapping_get(), public.mapping_add(text, text[]), public.mapping_delete(text),
  public.mapping_replace(jsonb), public.mapping_init(jsonb) from public;
grant execute on function public.mapping_get(), public.mapping_add(text, text[]), public.mapping_delete(text),
  public.mapping_replace(jsonb), public.mapping_init(jsonb) to anon, authenticated;

-- 대시보드가 새 함수를 바로 인식하도록
notify pgrst, 'reload schema';
