# w165 — красный контроль зубов атомарной подмены + гейт TS + замер linux

Исполнитель: qwen3.8-flash, [dispatch-class:exec-test]. Дата: 2026-09-16.
Дом: /Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-tweakcc (HEAD 970fc30e03605d47cb873d0fd595a6623210d579).
Предмет НЕ правил постоянно: 19 прогонов мутаций, каждый с восстановлением снимком (не git) и сверкой sha256.

## sha256-базалис (снят ДО первой мутации)

- src/nativeInstallation.ts `87a86fe65f9c68b1c76a1c7b1e90c8cb4641251f4df4574ab8f960f4aa514294`
- src/utils.ts               `bd947f7d6a6bbc955c3e2a73be63fdd5e12ffaa35fa24aadeea78b57e66c952a`
- src/atomicPublish.test.ts  `e586dd6e9e4cd6e95b059608567a3cd5db78f227eade3d77d8208a1d18100e40`

Снимки: scratchpad/w165-snap/*.baseline. Логи: scratchpad/w165-logs/tooth-*.log (+ .json vitest-отчёты).

## Положительный контроль прибора (ловушка «ПУСТО ≠ НОЛЬ»)

- `t00-control` (утилита mutate.rb с IDENTICAL-заменой строки `utils.ts:364`): rc=0, `FAILED_COUNT=0` —
  сама транскрипция/загрузка файла мутацией не красит ничего.
- `RESTORED sha256=87a86…` ×10, `RESTORED sha256=bd947…` ×9 — ровно по числу прогонов на каждый файл,
  все хэши равны базалису; `RESTORE-MISMATCH` не встречался (`grep -l` по всем логам — пусто, rc=1).

## Таблица 12 зубов (мутация → покрасневший зуб → падение)

Номера строк `it` — по src/atomicPublish.test.ts. file:line мутаций — по базальной версии предмета.

| # | Зуб (строка it) | Мутация предмета | Покрасневший зуб | Срыв падения |
|---|---|---|---|---|
| 1 | :48 async concurrent | `utils.ts:364` temp → `` `${filePath}.tmp.` + process.pid + '.shared' `` (общий неуникальный temp) (t01) | :48 | `expected 'rejected' to be 'fulfilled'` @ atomicPublish.test.ts:73 |
| 2 | :83 native temp unique | `nativeInstallation.ts:1467` суффикс → `` `${outputPath}.tmp.${process.pid}.fixed` `` (нет per-call уникальности) (t02) | :83 | `expected 1 to be 3` @ :105 (множество temp-имён из 3 записи = 1) |
| 3 | :126 async hardlink | `utils.ts:371` rename → ветка `if (nlink>1) writeFile(цель) else rename` (публикация в саму цель при жёстких ссылках) (t126) | :126 | `expected false to be true` @ :137 (hardlink читает НОВОЕ содержимое — inode не сломан) |
| 4 | :140 native hardlink | `nativeInstallation.ts:1499-1500` (atomicWriteBuffer) → та же nlink-ветка in-place + unlink temp (t140) | :140 (+ collateral :83 из-за неперехваченного ENOENT при nlink=1 в третьем вызове) | `expected false to be true` @ :152 |
| 5 | :157 no missing window | `utils.ts:371` → `await fs.rm(filePath, { force: true });` перед rename (t157) | :157 (+ collateral :271: rm до отказа rename — цель не восстановлена) | `expected 1 to be +0` @ :202 (`missing=1` — наблюдатель видел ENOENT) |
| 6 | :210 async chmod-before-rename | удалить `utils.ts:370` `await fs.chmod(tempPath, originalMode);` (t05) | :210 | `expected 420 to be 492` @ :225 (mode temp в момент publish = 0o644, ожидался 0o754) |
| 7 | :229 native chmod-before-rename | удалить `nativeInstallation.ts:1427` `fs.chmodSync(tempPath, origStat.mode);` (t04) | :229 | `expected 420 to be 492` @ :243 |
| 8 | :249 async write-fail rethrow | a) `utils.ts:379` снять `throw error;` (t09; красит и :271 как rethrow-тот же дефект); б) изолированно: создание temp в отдельный `try { writeFile } catch { return }`, chmod/rename-отказы продолжают rethrow (t09b) | :249 | a) `expected undefined to be 'EACCES'` @ :265; б) то же, FAILED_COUNT=1 |
| 9 | :271 async rename-fail cleanup | удалить `utils.ts:375` `await fs.unlink(tempPath);` (t10) | :271 | `expected [ Array(1) ] to deeply equal []` @ :287 (temp-остаток) |
| 10 | :290 native write-fail cleanup | `nativeInstallation.ts:1498-1499` (atomicWriteBuffer) `fs.writeFileSync(tempPath, content)` ВЫНЕСТЬ из try — отказ записи больше не убирает temp (t11) | :290 | `expected [ Array(1) ] to deeply equal []` @ :332 |
| 11 | :335 native rename-fail cleanup | broad: снять слой чистки в `atomicReplaceFile:1435-1437` + оба wrapper-`fs.unlinkSync(tempPath)` (1483, 1504) (t12; красит :290/:335/:355); isolated: снять слой 1435-1437 + в wrapper atomicWriteBuffer чистка пропускается при `code==='EIO'` (t12b2) | :335 (t12b2 — только он) | `expected [ Array(1) ] to deeply equal []` @ :352 |
| 12 | :355 ETXTBSY mapping | `nativeInstallation.ts:1446` убрать `'ETXTBSY' ||` из ветки маппинга (t13) | :355 | `expected [Function] to throw error including 'Cannot update the Claude executable w…' but got 'rename refused: simulated ETXTBSY'` @ :370 |

Дополнительно бродовой мутацией t03 (`nativeInstallation.ts:1431` rename → `fs.unlinkSync(outputPath)`, «удалить цель + запись на её место» в atomicReplaceFile) покраснели сразу 5 зубов: :83 (ENOENT @ :100), :140 (`expected false to be true` @ :152), :229 (`expected undefined to be 492` @ :243 — temp удалён до chmod-замера), :335 и :355 (`expected [Function] to throw an error` — mock renameSync не вызывается, отказа нет).

## Особое внимание :48 и :126 (зелёны на СТАРОЙ реализации)

Пробел НЕ объявляется: оба покрываются мутациями НЫНЕШНЕГО предмета по своей причине —
- :48 → t01 (общий temp): при общей temp-дорожке второй писатель своим unlink-при-отказе (или своим write)
  уничтожает temp первого, `rename` первого падает с ENOENT → `Promise.allSettled` даёт 'rejected'.
  Это ровно тот сценарий, ради которого введён уникальный temp; на старой реализации он красился
  сравнением с базой, здесь — мутацией.
- :126 → t126 (in-place запись при nlink>1): зуб мерит СЛОМ ЖЁСТКИХ ССЫЛОК публикацией-в-цель;
  зелёный на старой реализации результат потому, что та тоже ломала inode (unlink+write), а не
  потому, что зуб пустой.

## Отрицательный контроль (честный пробы)

- t12b (первая версия изоляции :335) — MUTATION-APPLY-FAILED: `FIND appears twice`
  (`fs.unlinkSync(tempPath);` встречается в обоих wrapper'ах). Сработала защита mutate.rb от
  неоднозначной замены; файл восстановлен; заменено на уникальный блок (t12b2 — успех).
- t157b «rm → rename → best-effort восстановление цели при отказе» — ЗЕЛЁН (rc=0, FAILED_COUNT=0):
  окно ENOENT существует, но наблюдатель (await-цикл) его не словил. Не сообщается как покрытие;
  :157 закрыт мутацией t157.

## ЗАДАЧА B — гейт синтаксиса TS (bun, без tsc, коды без пайпа)

Команды в /Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-tweakcc:

1. `bun build --no-bundle --outfile=/dev/null src/nativeInstallation.ts`
   вывод: `Transpiled file in 14ms` / `null  44.34 KB  (chunk)` — `rc_nativeInstallation=0`
2. `bun build --no-bundle --outfile=/dev/null src/utils.ts`
   вывод: `Transpiled file in 15ms` / `null  9.93 KB  (chunk)` — `rc_utils=0`
3. `bun build --no-bundle --outfile=/dev/null src/atomicPublish.test.ts`
   вывод: `Transpiled file in 1ms` / `null  11.77 KB  (chunk)` — `rc_atomicPublish_test=0`

## ЗАДАЧА C — замер на LINUX (usbox)

- Хост: `usbox` (ssh config: Host usbox → 162.248.226.17, User maratkarimov, id_ed25519_mac).
- Машина названа `uname -a`: `Linux ds7992137 6.12.0-211.51.1.el10_2.x86_64 #1 SMP PREEMPT_DYNAMIC Mon Sep  7 15:43:02 EDT 2026 x86_64 GNU/Linux`
- `date` машины (UTC): `Wed Sep 16 10:22:56 AM UTC 2026`. node v22.23.2, bun 1.4.2.
- Доставка: `git -C <дом> archive --format=tar 970fc30e… | ssh usbox 'tar -xf - -C ~/ccpatch/w165-red'` (локальный
  экспорт дерева коммита, без сети) + `scp` трёх файлов рабочего дерева. sha256 всех трёх НА usbox
  совпали с базалисом (87a86…/bd947…/e586d…).
- Пакеты НЕ ставились: использован готовый `~/.cache/catalyst-tweakcc/970fc30e03605d47cb873d0fd595a6623210d579/node_modules`
  (pnpm-layout, ровно этот SHA форка), скопирован `cp -a` в ~/ccpatch/w165-red/node_modules — боевой кэш не тронут.
- Замер фильтра (точная команда `./node_modules/.bin/vitest run src/atomicPublish.test.ts`, rc в строке арма, без пайпа):
  `Test Files 1 passed (1)` / `Tests 12 passed (12)` / `linux_vitest_rc=0`.
- Полный прогон (отцепленный фон, rc в ~/ccpatch/w165-red/full-suite.rc): `linux_full_rc=0`,
  `Test Files 57 passed (57)`, `Tests 657 passed | 5 skipped (662)` — совпало с darwin-опорой брифа.
- Зубья ETXTBSY на linux: падение :355 симулированного кода (mock) — платформонезависимо; реальный
  ETXTBSY-файл не воспроизводился (бриф этого не требовал); мутации-красные на linux не прогонялись —
  бриф просил «прогони тесты там» (зелёный полный + фильтр), что и сделано.

## ГЕЙТ 4 — финальная сверка дерева форка (mac)

`git -C <дом> status --porcelain`:
```
M src/nativeInstallation.ts
 M src/utils.ts
?? src/atomicPublish.test.ts
```
sha256 ПОСЛЕ всех мутаций:
- nativeInstallation.ts `87a86fe65f9c68b1c76a1c7b1e90c8cb4641251f4df4574ab8f960f4aa514294` (= базалис)
- utils.ts `bd947f7d6a6bbc955c3e2a73be63fdd5e12ffaa35fa24aadeea78b57e66c952a` (= базалис)
- atomicPublish.test.ts `e586dd6e9e4cd6e95b059608567a3cd5db78f227eade3d77d8208a1d18100e40` (= базалис, не мутировался)

## Вне скоупа — флаги (не правки)

- `~/.ssh/config` usbox-алиасы — прочитаны только для C, не тронуты.
- На usbox в `~/` найдены чужие прогонные артефакты (arsenal-overlay-probe-* и пр.) — не трогал.
- Сам тестовый файл и предмет не изменялись НИКОГДА вне временных мутаций; коммитов нет.
