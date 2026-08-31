-- Тестовая база и таблица для клиентского секундомера.
-- Выполняется на лидере, на фолловеры приезжает физической репликацией.
select 'password_encryption = '||current_setting('password_encryption');
