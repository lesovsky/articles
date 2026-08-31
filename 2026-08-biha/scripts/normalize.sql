-- Одинаковое логирование на всех узлах кластера.
-- Фазы failover снимаются по меткам времени из логов: формат должен совпадать,
-- время быть в UTC (сводим с клиентским секундомером), файл не должен
-- ротироваться посреди серии.
alter system set logging_collector = on;
alter system set log_directory = 'log';
alter system set log_filename = 'postgresql-%Y-%m-%d.log';
alter system set log_line_prefix = '%m [%p] %q%u@%d ';
alter system set log_rotation_age = 0;
alter system set log_rotation_size = 0;
alter system set log_timezone = 'UTC';
select pg_reload_conf();
