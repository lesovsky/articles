create table if not exists hb (
  seq  bigint primary key,
  node text,
  ts   timestamptz not null default clock_timestamp()
);
alter table hb owner to bihatest;
