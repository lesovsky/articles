-- Автовозврат бывшего лидера. По умолчанию выключен; без него узел после
-- failover встаёт в NODE_ERROR и требует ручной пересборки.
-- На тайминги failover не влияет: касается только возвращения старого узла.
alter system set biha.autorewind = on;
select pg_reload_conf();
