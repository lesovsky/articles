---
created: 2026-11-22
status: draft
type: article
target_reader: DBA и администраторы PostgreSQL, использующие встроенные представления статистики
---

# PostgreSQL 19: что нового во встроенном мониторинге

В release notes PostgreSQL 19 в контексте инструментов мониторинга есть несколько привлекательных записей: появились `pg_stat_lock`, `pg_stat_autovacuum_scores`, `pg_stat_recovery`, новые счётчики WAL и replication slots, а у старых progress-представлений появился признак, кто запустил операцию. Но, увы, сходу по списку новых объектов трудно ответить на главный вопрос: что именно они меняют в ежедневной работе DBA.

Я, как всегда, решил зайти с практической стороны — обновил локальный кластер до версии 19.0 и проверил основные новинки на небольших сценариях: очередь из конкурирующих UPDATE, таблицы с разными паттернами изменений, full-page writes, вытеснение логического декодирования на диск и пауза replay на реплике. Дальше в этой статье — те инструменты, которые уже стоит добавить в диагностические запросы и инструменты.

## Короткая карта нововведений
Перед тем как приступить к обзору инструментов и сценариев, приведу табличку с тем, что появилось и для каких задач это применимо:


| Задача | Новый инструмент |
|---|---|
| Накопительная статистика ожиданий блокировок | `pg_stat_lock` |
| Определить приоритет и причину autovacuum | `pg_stat_autovacuum_scores` |
| Отличить ручное обслуживание от автоматического | `started_by` в `pg_stat_progress_vacuum` и `pg_stat_progress_analyze` |
| Наблюдать за recovery-процессом | `pg_stat_recovery` |
| Измерить точный вклад full-page images в WAL | `wal_fpi_bytes` в `pg_stat_wal` и per-backend статистике |
| Увидеть превышение лимита памяти логического декодирования | `mem_exceeded_count` в `pg_stat_replication_slots` |
| Знать момент сброса счётчиков | `stats_reset` в табличной, индексной и другой статистике |
| Посмотреть использование multixact | `pg_get_multixact_stats()` |

Отдельно появились `pg_stat_progress_repack` и `EXPLAIN (IO)`, но их я рассматривать не буду, поскольку уже упоминал в других статьях: [REPACK](https://habr.com/ru/articles/1072388/) и [асинхронный I/O](https://habr.com/ru/articles/1071134/).

## Блокировки: накопительные счётчики, наконец-то!

Привычная связка `pg_stat_activity` и `pg_locks` показывает снимок в моменте и текущую очередь: кто ждёт, какой объект и какой backend удерживает блокировку. При продвинутом знании SQL можно выстроить и дерево блокировок. Но снимок актуален в моменте, а, например, после завершения инцидента очередь исчезает — ответить на вопрос «что накапливало ожидания последние сутки» по такому снимку нельзя. Приходится делать снимки с интервалом, но опять же — что было между снимками, покрыто тайной.

Новое представление [`pg_stat_lock`](https://www.postgresql.org/docs/19/monitoring-stats.html#MONITORING-PG-STAT-LOCK-VIEW) хранит накопительные счётчики по типам блокировок:

```sql
SELECT locktype,
       waits,
       round(wait_time::numeric, 1) AS wait_ms,
       fastpath_exceeded,
       stats_reset
FROM pg_stat_lock
ORDER BY wait_time DESC;
```

Первые две строки вывода после эксперимента:

```text
     locktype     | waits | wait_ms | fastpath_exceeded |         stats_reset
------------------+-------+---------+-------------------+------------------------------
 tuple            |     2 |  6061.7 |                 0 | 2026-11-22 16:51:13.12722+05
 transactionid    |     1 |  3036.1 |                 0 | 2026-11-22 16:51:13.12722+05
```

Это статистика инстанса (кластера), а не список текущих блокировок. Замечу, что в представлении нет PID, объекта или текста запроса. То есть статистика копится с момента сброса (`stats_reset`), который является точкой отсчёта.

Наверняка тут есть пользователи Prometheus/VictoriaMetrics — вам ведь наверняка пришла на ум rate-функция, которая элегантно встанет сюда и даст хороший график "почти" без потерь, характерных для связки `pg_stat_activity` и `pg_locks`. Почему "почти"? Потому что есть важное ограничение: `waits` и `wait_time` учитывают только ожидания дольше `deadlock_timeout`, завершившиеся успешным получением блокировки. Короткие ожидания, отмена и неуспешное завершение в эти счётчики не попадают.

В моём эксперименте одна транзакция удерживала обновление строки четыре секунды, а ещё три сессии пытались обновить ту же строку. `pg_stat_activity` в момент очереди показал:

| Ожидающие сессии | wait_event_type | wait_event |
|---|---|---|
| первая | Lock | transactionid |
| вторая и третья | Lock | tuple |

Дельта `pg_stat_lock` за эксперимент:

| locktype | waits | wait_time |
|---|---:|---:|
| transactionid | +1 | +3036.145 мс |
| tuple | +2 | +6061.728 мс |

Получилось три ожидания и около 9,1 секунды суммарного времени. Это хорошо согласуется с четырёхсекундным удержанием: часть времени первой сессии прошла до постановки остальных в очередь.

Практический сценарий — регулярно сохранять значения и считать дельту (ну, promql'вский rate, жэ). Рост `waits` покажет частоту таких длительных успешных ожиданий, `wait_time` — их накопленную цену (ущерб от ожидания), а деление одного на другое — среднюю длительность в этой выборке. Впрочем, когда метрика начала расти, конкретных виновников всё равно ищем через текущие `pg_stat_activity` и `pg_locks`: новое представление дополняет эту пару и никак не заменяет.

## Autovacuum: теперь приоритет смотреть легче лёгкого

До PostgreSQL 19 вопрос «почему autovacuum взялся за эту таблицу, а не за другую» обычно требовал ручного расчёта порогов с использованием сложных запросов вокруг `pg_stat_user_tables`, настроек СУБД или, не дай бог, настроек таблицы (storage parameters) и возраста транзакций. Новое [`pg_stat_autovacuum_scores`](https://www.postgresql.org/docs/19/monitoring-stats.html#MONITORING-PG-STAT-AUTOVACUUM-SCORES-VIEW) показывает уже вычисленные сервером составляющие:

```sql
SELECT schemaname, relname,
       round(score::numeric, 3) AS score,
       round(xid_score::numeric, 3) AS xid_score,
       round(mxid_score::numeric, 3) AS mxid_score,
       round(vacuum_score::numeric, 3) AS vacuum_score,
       round(vacuum_insert_score::numeric, 3) AS insert_score,
       round(analyze_score::numeric, 3) AS analyze_score,
       do_vacuum, do_analyze, for_wraparound
FROM pg_stat_autovacuum_scores
WHERE do_vacuum OR do_analyze
ORDER BY score DESC;
```

Сокращённый вывод для трёх таблиц стенда (без `schemaname`, `xid_score`, `mxid_score` и `for_wraparound`):

```text
   relname   | score  | vacuum_score | insert_score | analyze_score | do_vacuum | do_analyze
-------------+--------+--------------+--------------+---------------+-----------+------------
 vacuum_hot  | 27.317 |        8.889 |        4.000 |        27.317 | t         | t
 insert_only | 19.512 |        0.000 |        8.000 |        19.512 | t         | t
 vacuum_cold | 10.244 |        0.247 |        4.000 |        10.244 | t         | t
```

Чем выше `score`, тем выше приоритет таблицы в новой системе планирования autovacuum. Что важно, это не процент заполнения или число мёртвых строк (хотя и эти показатели тоже важны). Отдельные составляющие позволяют увидеть причину: обычные dead tuples, insert-only нагрузка, необходимость ANALYZE или приближение wraparound.

В эксперименте я взял три таблицы по 20 000 строк: в первой дважды обновил 90% строк, во второй — 5%, в третью просто добавил ещё 20 000 строк. В результате `n_dead_tup` составил 36 000 у `vacuum_hot`, 1 000 у `vacuum_cold` и 0 у `insert_only`.

У всех трёх `do_vacuum` и `do_analyze` были истинны, но причины и веса разные. Особенно полезен insert-only сценарий: отсутствие `n_dead_tup` ещё не означает, что таблице не нужен vacuum.

Для оценки текущего приоритета новое представление удобно объединить с `last_autovacuum`, `last_autoanalyze` и `n_dead_tup` из `pg_stat_user_tables`. Но опять же, есть нюанс — снимок не гарантирует порядок в очереди: когда запустится autovacuum worker, он начнёт свою калькуляцию и будет использовать актуальную информацию, которая может отличаться от текущего снимка, поэтому фактический выбор воркера и порядок таблиц могут отличаться. В контексте алертов имеет смысл смотреть на количество таблиц в очереди и рассматривать их как кандидатов для тюнинга storage parameters.

## Кто запустил VACUUM и ANALYZE

Идём дальше. В progress-представлении `pg_stat_progress_vacuum` появились `started_by` и `mode`, а в `pg_stat_progress_analyze` — `started_by`:

```sql
SELECT pid, relid::regclass, phase,
       started_by, mode,
       heap_blks_total, heap_blks_scanned
FROM pg_stat_progress_vacuum
WHERE relid = 'lab.progress_lab'::regclass;
```

Вывод двух прогонов — сначала ручного, затем автоматического VACUUM:

```text
   pid   |       relid       |     phase     | started_by |  mode  | heap_blks_total | heap_blks_scanned
---------+-------------------+---------------+------------+--------+-----------------+-------------------
 1990627 | lab.progress_lab  | scanning heap | manual     | normal |            1294 |                 0
 1994011 | lab.progress_lab  | scanning heap | autovacuum | normal |            1294 |                 0
```

Ручные запуски VACUUM и ANALYZE получили `started_by = manual`, автоматический VACUUM — `autovacuum`. Оба VACUUM выполнялись с `mode = normal`. Теперь не нужно угадывать происхождение операции по пользователю или тексту запроса из `pg_stat_activity`.

Поле `mode` отдельно показывает агрессивность vacuum. Ещё для логирования добавлен `log_autoanalyze_min_duration`: раньше длительность автоматического ANALYZE контролировалась вместе с autovacuum, а теперь `log_autovacuum_min_duration` отвечает только за vacuum, у autoanalyze собственный порог.

## WAL: теперь и количество full-page images, и их объём

В `pg_stat_wal` уже были `wal_fpi` и `wal_bytes`: количество записанных full-page images и общий объём WAL. Но оценить вклад FPI в общий объём было нельзя (обычно грубо округляют 1 FPI до размера страницы). В PostgreSQL 19 добавлен `wal_fpi_bytes`:

```sql
SELECT wal_records, wal_fpi,
       wal_bytes, wal_fpi_bytes,
       round(100 * wal_fpi_bytes / NULLIF(wal_bytes, 0), 2) AS fpi_pct,
       stats_reset
FROM pg_stat_wal;
```

Пример вывода:

```text
 wal_records | wal_fpi | wal_bytes | wal_fpi_bytes | fpi_pct |         stats_reset
-------------+---------+-----------+---------------+---------+------------------------------
     1813789 |   16371 | 296084740 |      61722584 |   20.85 | 2026-11-22 16:51:13.12722+05
```

Тот же показатель доступен через `pg_stat_get_backend_wal(pid)`, поэтому WAL-нагрузку можно разложить по активным backend:

```sql
SELECT a.pid, a.application_name,
       w.wal_records, w.wal_fpi,
       w.wal_bytes, w.wal_fpi_bytes
FROM pg_stat_activity AS a
CROSS JOIN LATERAL pg_stat_get_backend_wal(a.pid) AS w
ORDER BY w.wal_bytes DESC;
```

Эксперимент — повторное изменение одной строки. Дельта per-backend счётчиков:

```text
               phase               | wal_records | wal_fpi | wal_bytes | wal_fpi_bytes
-----------------------------------+-------------+---------+-----------+---------------
 первый update после checkpoint    |           3 |       1 |      4641 |          4508
 второй update (без checkpoint)    |           4 |       0 |       370 |             0
```

Во втором случае записей даже больше, но WAL почти на порядок меньше, так как нет FPI. Выше я писал про грубое округление (`wal_fpi * 8192`), так вот, не стоит так делать — новый счётчик показывает фактически записанный объём, который, если присмотреться, на стенде оказался меньше размера страницы (а грубое округление вообще бы превысило величину `wal_bytes`).

На практике это может быть полезно при разборе роста WAL после контрольных точек, интенсивного обновления или изменения настроек. Если `wal_fpi_bytes / wal_bytes` занимает заметную долю, следующий шаг — проверять паттерн записи (ворклоад) и интервал контрольных точек, а не просто медитировать на суммарный `wal_bytes`.

## Логическое декодирование: память кончилась, и это видно

У `pg_stat_replication_slots` уже были счётчики spill и stream. В PostgreSQL 19 добавлен `mem_exceeded_count` — сколько раз логическое декодирование превысило `logical_decoding_work_mem`.

```sql
SELECT slot_name, mem_exceeded_count,
       spill_txns, spill_count, spill_bytes,
       stream_txns, stream_count, stream_bytes
FROM pg_stat_replication_slots
ORDER BY spill_bytes DESC;
```

Сокращённый вывод (без stream-показателей):

```text
 slot_name  | mem_exceeded_count | spill_txns | spill_count | spill_bytes
------------+--------------------+------------+-------------+-------------
 lab_decode |                 10 |          1 |          11 |    10880000
```

В эксперименте `logical_decoding_work_mem` ограничен одним мегабайтом, затем выполняется обновление 20 000 строк одной транзакцией и чтение изменений через слот `test_decoding`. В выводе выше видно, что одна транзакция десять раз превысила лимит памяти и создала одиннадцать spill-частей общим объёмом 10 880 000 байт.

Счётчики не дублируют друг друга: превышение памяти и запись очередной части на диск — это разные события. Рост новой метрики помогает объяснить нагрузку на диск и задержку логической репликации, после чего уже можно проверять размер транзакций и настройку `logical_decoding_work_mem`.

Кстати, в 19-й появился `effective_wal_level`. При `wal_level = replica` создание логического слота на стенде перевело эффективный уровень в `logical`, а после удаления слота и контрольной точки вернулось значение `replica`. Вот и наблюдаемая часть механизма динамического включения логического декодирования.

## Recovery: полученный WAL и применённый WAL

Новое [`pg_stat_recovery`](https://www.postgresql.org/docs/19/monitoring-stats.html#MONITORING-PG-STAT-RECOVERY-VIEW) возвращает на реплике одну строку с replay LSN, timeline, временем последней применённой транзакции и состоянием паузы. Это исключительно для реплик — на primary представление ничего не покажет.

Для streaming-реплики полезен такой запрос:

```sql
SELECT r.pause_state,
       r.last_replayed_end_lsn,
       w.flushed_lsn AS received_lsn,
       pg_size_pretty(pg_wal_lsn_diff(
           w.flushed_lsn, r.last_replayed_end_lsn
       )) AS received_not_replayed
FROM pg_stat_recovery AS r
CROSS JOIN LATERAL (
    SELECT flushed_lsn FROM pg_stat_wal_receiver
) AS w;
```

Вывод во время паузы и после resume:

```text
 pause_state | last_replayed_end_lsn | received_lsn | received_not_replayed
-------------+-----------------------+--------------+-----------------------
 paused      | A4/36000000           | A4/37000050  | 16 MB
 not paused  | A4/37000050           | A4/37000050  | 0 bytes
```

Я поставил replay на паузу и сделал новую запись на primary. `last_replayed_end_lsn` остался `A4/36000000`, `pause_state` стал `paused`, а WAL receiver уже сообщил `flushed_lsn = A4/37000050`. То есть WAL получен и записан на реплике, но ещё не применён. После resume replay догнал это значение.

Какая тут практическая развилка:

- `received_lsn` не растёт — разбираться с соединением и получением WAL или с накоплением WAL на primary;
- `received_lsn` растёт, а replay стоит — смотреть `pause_state`, конфликты recovery и само применение;
- оба растут и приложение видит старые данные — совсем дела плохи, проверять задержку в применении конкретных транзакций, клиентские ожидания и производительность реплики (CPU, IO).

Само по себе наличие streaming в `pg_stat_wal_receiver` ещё не означает, что данные доступны для чтения на реплике.

## Полезные добавления без отдельных экспериментов

**`stats_reset` в привычных представлениях.** Теперь время сброса есть не только у общей статистики, но ещё и у таблиц, индексов, последовательностей, функций и database conflicts. После апгрейда у проверенной таблицы поле было NULL, а после `pg_stat_reset_single_table_counters()` появилось точное время. По сути, это простой способ отличать счётчики после сброса от показателей за весь срок жизни инстанса.

**`pg_get_multixact_stats()`.** Функция возвращает число мультитранзакций (multixact), количество участников, их размер и старейший multixact. Два параллельных `SELECT ... FOR SHARE` одной строки изменили показания с нуля до `num_mxids = 1`, `num_members = 2`, `members_size = 10`. Это дополнительный источник наблюдения за объектами, которые участвуют в ограничениях multixact wraparound.

**`pg_dsm_registry_allocations`.** Представление показывает зарегистрированные области динамической разделяемой памяти (dynamic shared memory). На стенде у меня такого нет, и без таких объектов вывод пустой. Причём обычная роль получила permission denied, а для `pg_get_multixact_stats()` — NULL во всех полях. С ролью `pg_monitor` ошибки нет, так что это стоит учесть (хотя мониторинговым ролям `pg_monitor` накидывают практически сразу).

**Логи и события ожиданий.** `log_lock_waits` теперь включён по умолчанию. `log_min_messages` поддерживает уровни по типам процессов. Для COPY появились события `CopyFromRead` и `CopyToWrite`, для commit delay и ожиданий WAL — новые события. Этих изменений немного, но они расширяют доступные объяснения текущих ожиданий.

## Что проверить в существующем мониторинге после апгрейда
Есть ещё несколько вещей, которые ломают обратную совместимость (ну как без этого, ага).

Во-первых, переименован `sync_error_count` из `pg_stat_subscription_stats`: теперь это `sync_table_error_count`, а ошибки синхронизации последовательностей учитываются в `sync_seq_error_count`.

Во-вторых, изменились имена buffer wait events:

- тип `BufferPin` стал `Buffer`;
- событие `BufferPin` стало `BufferCleanup`;
- вместо `BufferContent` появились `BufferShared`, `BufferShareExclusive` и `BufferExclusive`.

Если есть дашборды с группировкой ожиданий по старой строке, то после апгрейда часть графиков может стать пустой даже при наличии самих ожиданий (дико бесит, когда постгресисты в каждом мажоре такое исполняют).

В-третьих, проверьте пользователя мониторинга: чтение `pg_stat_lock` и `pg_stat_autovacuum_scores` доступно без `pg_monitor`, а для DSM и содержательного результата multixact-функции эта роль уже потребовалась на стенде.

## Что в итоге

PostgreSQL 19 расширяет внутренние инструменты мониторинга, которые неплохо бы подхватить во внешних системах мониторинга: новые представления всё так же нужно периодически читать и сохранять, потому что в инцидентах важна история. Встроенных сигналов стало заметно больше. Теперь из коробки можно связать текущий инцидент с накопленной статистикой блокировок, увидеть причину и приоритет autovacuum, отделить получение WAL от replay и измерить реальный вклад full-page images.

Что я рекомендовал бы сделать после апгрейда? Первое — добавить в регулярный сбор `pg_stat_lock` и `pg_stat_autovacuum_scores`. Вторым заходом — `wal_fpi_bytes` и, возможно, `stats_reset`; третье — при использовании логического декодирования — `mem_exceeded_count`. При диагностике autovacuum и реплики использовать новые представления вместо ручных оценок.

На этом всё, спасибо за внимание! [Полный реестр изменений](https://github.com/lesovsky/articles/blob/master/2026-11-pg19-monitoring/data/inventory/monitoring-changes.csv) включает и те, что не вошли в статью.

Как и в прошлых статьях, [все скрипты](https://github.com/lesovsky/articles/tree/master/2026-11-pg19-monitoring/scripts), [сырые выводы](https://github.com/lesovsky/articles/tree/master/2026-11-pg19-monitoring/data/results) и [подробная методика](https://github.com/lesovsky/articles/blob/master/2026-11-pg19-monitoring/RESULTS.md) лежат в [репозитории](https://github.com/lesovsky/articles/tree/master/2026-11-pg19-monitoring).
