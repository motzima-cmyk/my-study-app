-- =============================================================================
-- AI 태블릿 스터디 노트 (iPad 4:3 & Android Tablet 16:10)
-- Supabase PostgreSQL + Realtime CRDT 동기화 데이터베이스 초기화 스크립트
-- =============================================================================

-- 1. 확장 모듈 활성화
create extension if not exists "pgcrypto";

-- 2. AI 자동 분류 폴더 테이블 (folders)
create table if not exists public.folders (
  id text primary key,
  user_id uuid default auth.uid(),
  subject_name text not null,
  sub_topic_summary text not null default '',
  doc_type_badge text not null default '강의교안',
  keywords jsonb not null default '[]'::jsonb,
  doc_count integer not null default 1,
  updated_at timestamptz not null default now()
);

-- 3. PDF 문서 및 시험 D-Day 메타데이터 테이블 (documents)
create table if not exists public.documents (
  id text primary key,
  user_id uuid default auth.uid(),
  folder_id text references public.folders(id) on delete cascade,
  file_name text not null,
  sub_topic text not null default '',
  doc_type text not null default '강의교안',
  ai_summary text not null default '',
  extracted_exam_date date,
  read_count integer not null default 1,
  target_read_count integer not null default 3,
  storage_path text,
  updated_at timestamptz not null default now()
);

-- 4. 페이지별 정규화 필기(NormalizedStroke) + 암기 가림막(NormalizedMaskRect + SM-2 복습 스케줄) 테이블
create table if not exists public.page_annotations (
  doc_id text not null references public.documents(id) on delete cascade,
  page_number integer not null,
  user_id uuid default auth.uid(),
  strokes_json jsonb not null default '[]'::jsonb,
  masks_json jsonb not null default '[]'::jsonb,
  deleted_ids jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (doc_id, page_number)
);

-- 5. AI 올가미 오답 및 유사 변형 문제 카드 테이블 (study_cards)
create table if not exists public.study_cards (
  card_id text primary key,
  user_id uuid default auth.uid(),
  doc_id text not null references public.documents(id) on delete cascade,
  page_number integer not null default 1,
  crop_rect jsonb not null default '{"x":0.1,"y":0.1,"w":0.5,"h":0.2}'::jsonb,
  recognized_question text not null default '',
  step_by_step_solution text not null default '',
  twin_question text not null default '',
  twin_answer text not null default '',
  is_twin_revealed boolean not null default false,
  updated_at timestamptz not null default now()
);

-- 6. 강의 음성 녹음 세션 및 Gemini 시간대별 전사 세그먼트 테이블 (audio_sessions)
create table if not exists public.audio_sessions (
  session_id text primary key,
  user_id uuid default auth.uid(),
  doc_id text not null references public.documents(id) on delete cascade,
  title text not null default '강의 녹음',
  total_duration_ms integer not null default 60000,
  ai_lecture_summary text not null default '',
  exam_highlight_points jsonb not null default '[]'::jsonb,
  segments_json jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

-- 7. 조회 성능 최적화 인덱스
create index if not exists idx_documents_folder_id on public.documents(folder_id);
create index if not exists idx_documents_exam_date on public.documents(extracted_exam_date);
create index if not exists idx_page_annotations_doc_id on public.page_annotations(doc_id);
create index if not exists idx_study_cards_doc_id on public.study_cards(doc_id);
create index if not exists idx_audio_sessions_doc_id on public.audio_sessions(doc_id);

-- 8. Row Level Security (RLS) 정책 활성화 (개발/데모 환경 및 로그인 사용자 양쪽 호환)
alter table public.folders enable row level security;
alter table public.documents enable row level security;
alter table public.page_annotations enable row level security;
alter table public.study_cards enable row level security;
alter table public.audio_sessions enable row level security;

create policy "Allow tablet sync access to folders"
  on public.folders for all
  using (user_id is null or auth.uid() = user_id)
  with check (user_id is null or auth.uid() = user_id);

create policy "Allow tablet sync access to documents"
  on public.documents for all
  using (user_id is null or auth.uid() = user_id)
  with check (user_id is null or auth.uid() = user_id);

create policy "Allow tablet sync access to page_annotations"
  on public.page_annotations for all
  using (user_id is null or auth.uid() = user_id)
  with check (user_id is null or auth.uid() = user_id);

create policy "Allow tablet sync access to study_cards"
  on public.study_cards for all
  using (user_id is null or auth.uid() = user_id)
  with check (user_id is null or auth.uid() = user_id);

create policy "Allow tablet sync access to audio_sessions"
  on public.audio_sessions for all
  using (user_id is null or auth.uid() = user_id)
  with check (user_id is null or auth.uid() = user_id);

-- 9. Supabase Realtime 퍼블리케이션 등록 (아이패드 <-> 안드로이드 태블릿 실시간 동기화)
alter publication supabase_realtime add table public.page_annotations;
alter publication supabase_realtime add table public.folders;
alter publication supabase_realtime add table public.documents;
alter publication supabase_realtime add table public.study_cards;
alter publication supabase_realtime add table public.audio_sessions;
