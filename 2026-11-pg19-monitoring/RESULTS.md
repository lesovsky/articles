# Результаты исследования встроенного мониторинга PostgreSQL 19

## Методика

Эксперименты выполнены 22 ноября 2026 года на Ubuntu 24.04 с пакетом PGDG `19.0-2.pgdg24.04+1`. Локальный кластер обновлён с PostgreSQL 17.11 до 19.0; основной кластер слушал порт 5432. Для recovery использовалась временная локальная реплика на порту 55432, созданная `pg_basebackup`; после эксперимента она остановлена и удалена.

Все рабочие таблицы находились в базе `pg19_monitoring`, схема `lab`. Производительность не измерялась: цель экспериментов — проверить смысл и наблюдаемое поведение новых средств мониторинга.

Снимки каталога до и после обновления находятся в `data/inventory/pg17/` и `data/inventory/pg19/`. Их diff нельзя использовать как список нововведений именно PostgreSQL 19: в него также попали изменения PostgreSQL 18. Для темы статьи использовался `data/inventory/monitoring-changes.csv`, составленный по [release notes 19.0](https://www.postgresql.org/docs/release/19.0/) и сверенный с каталогом 19.0.

В экспериментах с накопительной статистикой применялись `pg_stat_force_next_flush()` и `pg_stat_clear_snapshot()`. Без этого часть показаний могла быть ещё не передана или закэширована в сессии. Для production-запросов эти функции в каждом измерении не требуются; здесь они нужны для детерминированного стенда.

## 1. Блокировки

Файлы: `lock-before.csv`, `lock-activity.csv`, `lock-after.csv` в `data/results/`.

Одна сессия удерживала обновление строки четыре секунды, ещё три сессии одновременно обновляли ту же строку. Снимок `pg_stat_activity` показал:

- первый ожидающий backend — `Lock / transactionid`;
- два следующих — `Lock / tuple`.

Дельта `pg_stat_lock`:

| locktype | waits | wait_time, мс |
|---|---:|---:|
| transactionid | +1 | +3036.145 |
| tuple | +2 | +6061.728 |

`wait_time` измеряется в миллисекундах. Счётчики кластерные и накопительные; PID, таблицы и запросов в `pg_stat_lock` нет. Учитываются только ожидания дольше `deadlock_timeout`, завершившиеся успешным получением блокировки. Текущий инцидент по-прежнему разбирается через `pg_stat_activity` и `pg_locks`.

## 2. Autovacuum и ANALYZE

Файл: `data/results/autovacuum-scores.log`.

Три таблицы начали с 20 000 строк. В `vacuum_hot` дважды обновили 90% строк, в `vacuum_cold` обновили 5%, в `insert_only` добавили ещё 20 000 строк. Перед измерением статистика была принудительно передана.

| Таблица | n_dead_tup | vacuum_score | vacuum_insert_score | analyze_score | score |
|---|---:|---:|---:|---:|---:|
| vacuum_hot | 36 000 | 8.889 | 4.000 | 27.317 | 27.317 |
| vacuum_cold | 1 000 | 0.247 | 4.000 | 10.244 | 10.244 |
| insert_only | 0 | 0.000 | 8.000 | 19.512 | 19.512 |

У всех трёх таблиц `do_vacuum = t` и `do_analyze = t`. Значения score не являются процентами или количеством строк.

Файлы `progress-manual-vacuum.csv`, `progress-auto-vacuum.csv`, `progress-manual-analyze.csv`:

- ручной VACUUM: `started_by = manual`, `mode = normal`;
- автоматический VACUUM: `started_by = autovacuum`, `mode = normal`;
- ручной ANALYZE: `started_by = manual`, фаза `acquiring sample rows`.

`log_lock_waits` в 19.0 по умолчанию включён. `log_autoanalyze_min_duration = 600000` существует отдельно от `log_autovacuum_min_duration = 600000`.

## 3. Сброс статистики

В `data/results/autovacuum-scores.log` новый `pg_stat_user_tables.stats_reset` до сброса был NULL. После `pg_stat_reset_single_table_counters('lab.vacuum_hot')` появилось время `2026-11-22 17:10:14.013554+05`.

Это позволяет отличить счётчики, собранные с апгрейда, от счётчиков после явного сброса. Само значение не заменяет дельту между двумя измерениями.

## 4. WAL и логическое декодирование

Файл: `data/results/wal-decoding.log`.

Per-backend WAL-статистика снималась через `pg_stat_get_backend_wal(pg_backend_pid())`. Временные таблицы были созданы и их WAL-активность сброшена в статистику до точки отсчёта, чтобы не попасть в дельту эксперимента.

| Сценарий | wal_records | wal_fpi | wal_bytes | wal_fpi_bytes |
|---|---:|---:|---:|---:|
| UPDATE одной строки после CHECKPOINT | 3 | 1 | 4 641 | 4 508 |
| Повторный UPDATE той же строки без CHECKPOINT | 4 | 0 | 370 | 0 |

На стенде `full_page_writes = on`, `wal_compression = off`, `wal_block_size = 8192`. Из этих данных не делается вывод, что байты FPI всегда равны размеру страницы: измеренный счётчик отражает фактически записанный объём.

Логический слот `lab_decode` с `test_decoding` при `wal_level = replica` изменил `effective_wal_level` на `logical`. После удаления слота и checkpoint вернулось значение `replica`.

При `logical_decoding_work_mem = 1MB` выполнено обновление 20 000 строк и прочитано 20 002 изменения:

| spill_txns | spill_count | spill_bytes | mem_exceeded_count | total_txns | total_bytes |
|---:|---:|---:|---:|---:|---:|
| 1 | 11 | 10 880 000 | 10 | 1 | 10 880 000 |

Таким образом, превышение work_mem и запись отдельных spill-файлов — связанные, но не одинаковые события.

## 5. Recovery

Файлы: `recovery-before.csv`, `recovery-paused.csv`, `recovery-after.csv`, `recovery-wal-receiver.csv`.

До паузы:

- `last_replayed_end_lsn = A4/36000000`;
- `pause_state = not paused`.

После `pg_wal_replay_pause()` и новой записи на primary:

- `last_replayed_end_lsn` не изменился;
- `pause_state = paused`;
- WAL receiver уже имел `flushed_lsn = A4/37000050`.

После resume `last_replayed_end_lsn` достиг `A4/37000050`, `pause_state` снова стал `not paused`.

`replay_end_lsn` в снимке на паузе не заменил показание WAL receiver. Для разделения «WAL не получен» и «WAL получен, но не применён» нужно смотреть оба представления.

На primary `pg_stat_recovery` возвращает ноль строк; на реплике в recovery — одну строку.

## 6. Multixact, DSM и права

Файлы: `multixact-before.csv`, `multixact-after.csv`, `privileges.log`, `dsm-registry.csv`.

Два параллельных `SELECT ... FOR SHARE` одной строки изменили результат `pg_get_multixact_stats()`:

| Показатель | До | После |
|---|---:|---:|
| num_mxids | 0 | 1 |
| num_members | 0 | 2 |
| members_size | 0 | 10 |
| oldest_multixact | 1 | 1 |

`pg_dsm_registry_allocations` на стенде без зарегистрированных DSM-объектов вернул ноль строк.

Роль без дополнительных прав могла читать `pg_stat_lock`, `pg_stat_recovery` и `pg_stat_autovacuum_scores`. Для `pg_dsm_registry_allocations` она получила permission denied, а `pg_get_multixact_stats()` вернула NULL во всех полях. Роль с `pg_monitor` прошла обе проверки.

## Ограничения

- Стенд один, большинство сценариев выполнены по одному разу; это функциональные проверки, а не бенчмарки.
- Не оценивались накладные расходы новых счётчиков и оптимальные пороги алертов.
- Подробные эксперименты по `pg_stat_progress_repack` и `EXPLAIN (IO)` не повторялись: они есть в соседних исследованиях.
- Синхронизация слотов, конфликты подписчика и отдельные wait events вынесены в реестр, но не разбираются отдельными экспериментами.
