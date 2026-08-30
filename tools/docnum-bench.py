#!/usr/bin/env python3
"""Зубы гейта чисел (шаг 0d конвейера).

Гейт сам по себе умеет молчать: он молчал трижды, и каждую дыру находили
руками, а не им. Внутри гейта живёт положительный контроль грамматики
(синтетические тексты с известным ответом), но он ничего не говорит о
СВЯЗКЕ гейта с настоящим деревом -- с README, с константами стендов, с
выбором владельца по ближайшему имени. Это она.

Порядок такой: сперва контроль без мутации (пристинный кит обязан быть
зелёным -- иначе краснеет что угодно и стенд ничего не доказывает), затем
каждая записанная мутация по очереди, каждая обязана покраснить гейт СВОЕЙ
причиной.

Гейт вырезается из конвейера по якорю. Якорь пропал -- отказ, а не тихий
пропуск: молча пропущенный стенд это ровно та тишина, ради которой он писан.

Коды выхода (подмножество общей таблицы кита -- см. шапку claude-patch-all.sh):
  0  каждая записанная мутация покраснела своей причиной
  1  зубы не держатся: мутация прошла молча или покраснела ЧУЖОЙ причиной
  2  прибор не может мерить: нет таблицы, строка не о пяти полях, якорь гейта
     пропал или встречается не один раз, ВЫРЕЗАННЫЙ ГЕЙТ НЕ РАЗБИРАЕТСЯ
     (py_compile перед прогоном; круг 25, E-2), ПРИСТИННЫЙ кит уже красный
     (контроль провален, и мутация ничего не докажет), либо выведенный из
     пути корень не несёт подписи кита (круг 24)
  4  длина таблицы не равна объявленной в EXPECTED_MUTATIONS
Один код на два ответа уже стоил кита: вызывающий печатал «мутация не
покраснела» на КАЖДЫЙ ненулевой, включая пропавший якорь (раунд 18, F-9).
Код разбора ДОМИНИРУЕТ над счётом покраснений: пока гейт не разбирается,
ни одному числу этого прогона веры нет.
"""
import io
import os
import py_compile
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(HERE)

# Круг 24: кит выводится из пути ЭТОГО файла, а ниже копируется ЦЕЛИКОМ
# (shutil.copytree(KIT, ...)). Позванный из копии вне кита, стенд принимает за
# кит произвольный каталог и копирует его: у соседнего стенда это замерено --
# KIT стал корнем файловой системы и 3.8 ГБ уехали в tmp до ручной остановки.
# Ошибка вывода корня ОБЪЯВЛЯЕТСЯ кодом 2 («прибор не может мерить»), а не
# исполняется. Подпись кита -- три его файла; проверка стоит ДО первой копии.
KIT_SIGNATURE = ('claude-patch-all.sh', 'tools/sweep.sh', 'tools/corpus-versions.txt')


def require_kit_root():
    """Страж стоит В ТОЧКЕ КОПИРОВАНИЯ, а не в шапке модуля.

    Причина та же, что у соседнего стенда: точка самой опасности одна, и новый
    вызывающий не сможет обойти проверку, а двери, которые НИЧЕГО не копируют,
    обязаны работать откуда угодно -- ставить страж в шапку значит запрещать и
    их. Отсутствие подписи -- код 2 «прибор не может мерить».
    """
    missing = [n for n in KIT_SIGNATURE if not os.path.isfile(os.path.join(KIT, n))]
    if missing:
        sys.stderr.write(
            'docnum-bench: КОРЕНЬ НЕ КИТ -- в «%s» нет %s.\n'
            '  Стенд копирует кит целиком; запускать только как\n'
            '  tools/docnum-bench.py внутри кита.\n'
            % (KIT, ', '.join(missing)))
        sys.exit(2)

TABLE = os.path.join(HERE, 'docnum-mutations.tsv')
PIPELINE = 'claude-patch-all.sh'
ANCHOR = 'python3 - "$0" <<\'PYDOCS\'\n'
END = '\nPYDOCS\n'
# Круг 28, F-12(б): +1 -- мутация D40 на элидированную форму «все N».
EXPECTED_MUTATIONS = 40


def read(path):
    return io.open(path, encoding='utf-8').read()


def say(message):
    print('docnum-bench: ' + message, flush=True)


def load():
    if not os.path.exists(TABLE):
        say('ОТКАЗ -- нет таблицы мутаций %s' % TABLE)
        sys.exit(2)
    rows = []
    for line in read(TABLE).splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) != 5:
            say('ОТКАЗ -- строка таблицы не о пяти полях: %r' % line)
            sys.exit(2)
        rows.append(parts)
    return rows


def carve(kit):
    """Гейт как отдельный исполняемый файл, вырезанный из конвейера."""
    source = read(os.path.join(kit, PIPELINE))
    if ANCHOR not in source:
        say('ОТКАЗ -- якорь гейта чисел пропал из %s' % PIPELINE)
        sys.exit(2)
    if source.count(ANCHOR) != 1:
        say('ОТКАЗ -- якорь гейта чисел встречается %d раз в %s: неизвестно, '
            'какое тело проверяется' % (source.count(ANCHOR), PIPELINE))
        sys.exit(2)
    start = source.index(ANCHOR) + len(ANCHOR)
    if END not in source[start:]:
        say('ОТКАЗ -- конец гейта чисел не найден в %s' % PIPELINE)
        sys.exit(2)
    body = source[start:source.index(END, start)]
    path = os.path.join(kit, '.docnum-gate.py')
    io.open(path, 'w', encoding='utf-8').write(body)
    # Круг 25, E-2: след ищется подстрокой в ВЫВОДЕ гейта, а питоновский
    # SyntaxError печатает СТРОКУ ИСХОДНИКА, на которой сломался разбор. У
    # большинства записей таблицы ждём-след лежит дословно в теле гейта
    # (описания синтетических случаев), поэтому мутация, ломающая ТОЛЬКО
    # разбор на строке со своим же следом, читалась как зуб: гейт «краснел
    # своей причиной», доказывая лишь то, что файл можно испортить. Аудитор
    # доказал это на записи D9 -- замена из одних скобок до кортежа держала
    # механизм нетронутым, гейт оставался зелёным по счёту и EXIT=0.
    # Проверка стоит В ТОЧКЕ вырезания: carve() зовут и контролем, и каждой
    # мутацией (мутация может править сам гейт), поэтому провал разбора
    # останавливает прогон ДО любого счёта -- код «прибор не может мерить»
    # доминирует над кодом «зубы не держатся». Паллиатив «след не должен
    # совпадать с правимой строкой» отвергнут контроллером: чинится механизм,
    # а не симптом.
    try:
        py_compile.compile(path, doraise=True)
    except py_compile.PyCompileError as error:
        say('ОТКАЗ -- вырезанный гейт не разбирается: %s' % error)
        sys.exit(2)
    return path


def run_gate(kit, gate):
    done = subprocess.run([sys.executable, gate, os.path.join(kit, PIPELINE)],
                          capture_output=True, text=True)
    return done.returncode, (done.stdout or '') + (done.stderr or '')


def main():
    rows = load()
    work = tempfile.mkdtemp(prefix='docnum-bench.')
    try:
        kit = os.path.join(work, 'kit')
        require_kit_root()
        shutil.copytree(KIT, kit, ignore=shutil.ignore_patterns('.git'))
        gate = carve(kit)

        code, out = run_gate(kit, gate)
        if code != 0:
            say('КОНТРОЛЬ ПРОВАЛЕН -- пристинный кит уже красный, мутации ничего')
            say('не докажут. Вывод гейта:')
            for line in out.splitlines():
                print('    ' + line)
            # Класс 2: измерения не было. Прежде здесь стоял код 3, а 3 в
            # таблице кита значит «замок держит другой живой прогон --
            # повторить позже»; повтор тут не помогает никогда (раунд 19, A-4).
            return 2
        say('КОНТРОЛЬ без мутации: ЗЕЛЁНО')

        reddened = 0
        for name, rel, old, new, want in rows:
            target = os.path.join(kit, rel)
            if not os.path.exists(target):
                say('МУТАЦИЯ %s: FAIL -- нет файла %s' % (name, rel))
                continue
            pristine = read(target)
            seen = pristine.count(old)
            if seen == 0:
                say('МУТАЦИЯ %s: FAIL -- вход не найден дословно в %s' % (name, rel))
                continue
            if seen != 1:
                say('МУТАЦИЯ %s: FAIL -- вход встречается %d раз в %s: мутация '
                    'подтвердилась бы по теневому совпадению' % (name, seen, rel))
                continue
            io.open(target, 'w', encoding='utf-8').write(pristine.replace(old, new))
            # Гейт вырезается заново: мутация могла править сам гейт.
            code, out = run_gate(kit, carve(kit))
            io.open(target, 'w', encoding='utf-8').write(pristine)
            if code == 0:
                say('МУТАЦИЯ %s: ЗЕЛЁНАЯ -- гейт её не увидел' % name)
            elif want not in out:
                say('МУТАЦИЯ %s: КРАСНАЯ НЕ ПО ТОЙ ПРИЧИНЕ (нет «%s»):' % (name, want))
                for line in out.splitlines():
                    print('    ' + line)
            else:
                say('МУТАЦИЯ %s: RED' % name)
                reddened += 1

        say('ИТОГ мутаций=%d покраснели=%d' % (len(rows), reddened))
        if len(rows) != EXPECTED_MUTATIONS:
            say('ОТКАЗ -- в таблице %d строк, объявлено %d'
                % (len(rows), EXPECTED_MUTATIONS))
            return 4
        return 0 if reddened == len(rows) else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
