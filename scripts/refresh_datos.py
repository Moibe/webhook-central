#!/usr/bin/env python3
"""Ayudante de refresh.sh: copia los datos de una instancia PROD a su DEV.

Subcomandos (todos imprimen un JSON en stdout; el detalle legible va a stderr,
que refresh.sh manda al log de la corrida):

  preparar --dev RAIZ --prod RAIZ --datos "VAR:default ..." --trabajo DIR
      Resuelve cada ruta de datos como la resuelve la app (la variable en el .env
      de esa raíz, o el default, relativa a la raíz), valida que dev y prod no se
      pisen, revisa espacio en disco y copia lo de prod a DIR/nuevo/. Prod SOLO se
      lee: las bases SQLite se sacan con la API de backup, que da una copia
      consistente aunque prod esté escribiendo en ese momento.
  cambiar --plan DIR/plan.json
      Mueve lo de dev a DIR/dev-anterior/ (con la misma estructura de carpetas,
      para restaurarlo a mano si hiciera falta) y pone lo nuevo en su lugar. Si
      algo falla a medias, regresa lo que alcanzó a mover.
  podar --base DIR --conservar N
      Borra las corridas de respaldo viejas y deja las N más recientes.
"""
import argparse
import json
import math
import os
import shutil
import sqlite3
import sys
import traceback
from pathlib import Path

CABECERA_SQLITE = b'SQLite format 3\x00'
# Archivos que SQLite deja junto a una base: si quedara un -wal viejo junto a una
# base nueva, SQLite lo aplicaría sobre ella y la corrompería.
ACOMPANANTES = ('-wal', '-shm', '-journal')
MARGEN_DISCO = 200 * 1024 * 1024


class ErrorRefresco(Exception):
    """Error explicado para quien aprieta el botón; refresh.sh lo regresa tal cual."""


def log(mensaje):
    print(mensaje, file=sys.stderr, flush=True)


def humano(n):
    if n < 1024:
        return f'{n} B'
    exp = min(int(math.log(n, 1024)), 4)
    return f'{n / 1024 ** exp:.1f} {"BKMGT"[exp]}{"B" if exp else ""}'


def leer_env(ruta):
    """Lee un .env con las reglas de python-dotenv que importan aquí (comentarios,
    `export`, comillas). Sólo se usan las variables de rutas: nunca se imprimen
    valores del .env."""
    valores = {}
    try:
        with open(ruta, encoding='utf-8') as f:
            for linea in f:
                linea = linea.strip()
                if not linea or linea.startswith('#') or '=' not in linea:
                    continue
                if linea.startswith('export '):
                    linea = linea[len('export '):].lstrip()
                clave, valor = linea.split('=', 1)
                valor = valor.strip()
                if len(valor) >= 2 and valor[0] == valor[-1] and valor[0] in '"\'':
                    valor = valor[1:-1]
                else:
                    valor = valor.split(' #', 1)[0].strip()
                valores[clave.strip()] = valor
    except FileNotFoundError:
        pass
    return valores


def resolver(raiz, env, variable, default):
    valor = (env.get(variable) or default).strip()
    ruta = valor if os.path.isabs(valor) else os.path.join(raiz, valor)
    return os.path.normpath(ruta)


def dentro_de(ruta, raiz):
    ruta = os.path.realpath(ruta)
    raiz = os.path.realpath(raiz)
    return ruta == raiz or ruta.startswith(raiz.rstrip(os.sep) + os.sep)


def es_sqlite(ruta):
    try:
        with open(ruta, 'rb') as f:
            return f.read(16) == CABECERA_SQLITE
    except OSError:
        return False


def tamano(ruta):
    if os.path.isfile(ruta):
        return os.path.getsize(ruta)
    total = 0
    for carpeta, _, archivos in os.walk(ruta):
        for nombre in archivos:
            try:
                total += os.path.getsize(os.path.join(carpeta, nombre))
            except OSError:
                pass
    return total


def quitar(ruta):
    if os.path.isdir(ruta) and not os.path.islink(ruta):
        shutil.rmtree(ruta)
    elif os.path.lexists(ruta):
        os.remove(ruta)


def copiar_sqlite(origen, destino):
    """Copia consistente con la API de backup de SQLite, abriendo prod en sólo
    lectura (si no se puede, en modo normal: el backup igual sólo lee)."""
    for ruta in [destino] + [destino + s for s in ACOMPANANTES]:
        quitar(ruta)
    try:
        fuente = sqlite3.connect(Path(origen).resolve().as_uri() + '?mode=ro', uri=True, timeout=30)
        fuente.execute('SELECT count(*) FROM sqlite_master').fetchone()
    except sqlite3.Error as e:
        log(f'   (sólo lectura no disponible para {origen}: {e}; se abre en modo normal)')
        fuente = sqlite3.connect(origen, timeout=30)
    copia = sqlite3.connect(destino)
    try:
        fuente.backup(copia)
    finally:
        copia.close()
        fuente.close()
    revision = sqlite3.connect(destino)
    try:
        resultado = revision.execute('PRAGMA quick_check').fetchone()[0]
    finally:
        revision.close()
    for sufijo in ACOMPANANTES:
        quitar(destino + sufijo)
    if resultado != 'ok':
        raise ErrorRefresco(f'La copia de {origen} no pasó la revisión de integridad: {resultado}')


def copiar_carpeta(origen, destino):
    shutil.copytree(origen, destino, symlinks=True)
    # Las bases SQLite de adentro (chroma.sqlite3) se vuelven a sacar con la API de
    # backup DESPUÉS de copiar lo demás: así quedan igual o más nuevas que los
    # índices binarios de Chroma, que es el orden que Chroma sabe reconciliar.
    for carpeta, _, archivos in os.walk(destino):
        for nombre in archivos:
            if nombre.endswith(ACOMPANANTES):
                continue
            ruta = os.path.join(carpeta, nombre)
            if es_sqlite(ruta):
                copiar_sqlite(os.path.join(origen, os.path.relpath(ruta, destino)), ruta)
    # Los -wal/-shm copiados con copytree eran del momento de la copia: fuera.
    for carpeta, _, archivos in os.walk(destino):
        for nombre in archivos:
            if nombre.endswith(ACOMPANANTES):
                quitar(os.path.join(carpeta, nombre))


def preparar(args):
    dev = os.path.realpath(args.dev)
    prod = os.path.realpath(args.prod)
    if not os.path.isdir(dev):
        raise ErrorRefresco(f'No existe la carpeta de dev: {dev}')
    if not os.path.isdir(prod):
        raise ErrorRefresco(f'No existe la carpeta de prod: {prod}')
    if dentro_de(dev, prod) or dentro_de(prod, dev):
        raise ErrorRefresco('La carpeta de dev y la de prod son la misma o una está dentro de la otra.')
    trabajo = os.path.abspath(args.trabajo)
    if dentro_de(trabajo, dev) or dentro_de(trabajo, prod):
        raise ErrorRefresco('La carpeta de respaldos no puede estar dentro de dev ni de prod.')

    pares = []
    for token in (args.datos or '').split():
        variable, _, default = token.partition(':')
        if not variable or not default:
            raise ErrorRefresco(f'REFRESH_DATA mal escrito: "{token}" (formato VARIABLE:default).')
        pares.append((variable, default))
    if not pares:
        raise ErrorRefresco('REFRESH_DATA está vacío en el .conf.')

    env_dev = leer_env(os.path.join(dev, '.env'))
    env_prod = leer_env(os.path.join(prod, '.env'))
    items = []
    for variable, default in pares:
        origen = resolver(prod, env_prod, variable, default)
        destino = resolver(dev, env_dev, variable, default)
        if os.path.realpath(origen) == os.path.realpath(destino):
            raise ErrorRefresco(f'{variable}: dev y prod usan el mismo lugar ({destino}). '
                                'Dale a dev su propia ruta en su .env antes de refrescar.')
        if not dentro_de(destino, dev) or os.path.realpath(destino) == dev:
            raise ErrorRefresco(f'{variable}: la ruta de dev ({destino}) no queda dentro de {dev}; '
                                'por seguridad sólo se reemplaza lo que vive adentro de dev.')
        if os.path.islink(destino):
            raise ErrorRefresco(f'{variable}: la ruta de dev ({destino}) es un enlace simbólico; no se toca.')
        if not os.path.lexists(origen):
            tipo = 'falta'
        elif os.path.isdir(origen):
            tipo = 'carpeta'
        elif es_sqlite(origen):
            tipo = 'sqlite'
        else:
            tipo = 'archivo'
        items.append({
            'variable': variable, 'origen': origen, 'destino': destino, 'tipo': tipo,
            'rel': os.path.relpath(destino, dev), 'bytes': tamano(origen) if tipo != 'falta' else 0,
        })
    for a in items:
        for b in items:
            if a is not b and dentro_de(a['destino'], b['destino']):
                raise ErrorRefresco(f"{a['variable']} queda dentro de {b['variable']} en dev; revisa REFRESH_DATA.")

    total = sum(i['bytes'] for i in items)
    os.makedirs(trabajo, exist_ok=True)
    libre = shutil.disk_usage(trabajo).free
    if libre < total + MARGEN_DISCO:
        raise ErrorRefresco(f'No hay espacio en disco: la copia necesita {humano(total + MARGEN_DISCO)} '
                            f'y hay {humano(libre)} libres.')
    if os.stat(trabajo).st_dev != os.stat(dev).st_dev:
        libre_dev = shutil.disk_usage(dev).free
        if libre_dev < total + MARGEN_DISCO:
            raise ErrorRefresco(f'No hay espacio en el disco de dev: hacen falta {humano(total + MARGEN_DISCO)} '
                                f'y hay {humano(libre_dev)} libres.')

    nuevo = os.path.join(trabajo, 'nuevo')
    log(f'Copiando {humano(total)} de {prod} a {nuevo}')
    for it in items:
        destino = os.path.join(nuevo, it['rel'])
        os.makedirs(os.path.dirname(destino), exist_ok=True)
        if it['tipo'] == 'falta':
            log(f"   {it['variable']}: no existe en prod ({it['origen']}); en dev se quitará lo que haya")
        elif it['tipo'] == 'sqlite':
            log(f"   {it['variable']}: base SQLite {it['rel']} ({humano(it['bytes'])}) con la API de backup")
            copiar_sqlite(it['origen'], destino)
        elif it['tipo'] == 'carpeta':
            log(f"   {it['variable']}: carpeta {it['rel']} ({humano(it['bytes'])})")
            copiar_carpeta(it['origen'], destino)
        else:
            log(f"   {it['variable']}: archivo {it['rel']} ({humano(it['bytes'])})")
            shutil.copy2(it['origen'], destino)

    plan = {'dev': dev, 'prod': prod, 'trabajo': trabajo, 'items': items, 'total_bytes': total,
            'resumen': ' · '.join(f"{i['rel']} {humano(i['bytes'])}" if i['tipo'] != 'falta'
                                  else f"{i['rel']} (no existe en prod)" for i in items)}
    with open(os.path.join(trabajo, 'plan.json'), 'w', encoding='utf-8') as f:
        json.dump(plan, f, ensure_ascii=False, indent=2)
    return {'ok': True, 'total_bytes': total, 'resumen': plan['resumen']}


def cambiar(args):
    with open(args.plan, encoding='utf-8') as f:
        plan = json.load(f)
    dev = plan['dev']
    anterior = os.path.join(plan['trabajo'], 'dev-anterior')
    nuevo = os.path.join(plan['trabajo'], 'nuevo')
    hechos = []  # ('movido', ruta_dev, ruta_respaldo) | ('puesto', ruta_dev)
    try:
        for it in plan['items']:
            destino = it['destino']
            for ruta in [destino] + [destino + s for s in ACOMPANANTES]:
                if os.path.lexists(ruta):
                    hacia = os.path.join(anterior, os.path.relpath(ruta, dev))
                    os.makedirs(os.path.dirname(hacia), exist_ok=True)
                    shutil.move(ruta, hacia)
                    hechos.append(('movido', ruta, hacia))
                    log(f'   dev → respaldo: {os.path.relpath(ruta, dev)}')
            if it['tipo'] != 'falta':
                os.makedirs(os.path.dirname(destino), exist_ok=True)
                shutil.move(os.path.join(nuevo, it['rel']), destino)
                hechos.append(('puesto', destino))
                log(f"   prod → dev: {it['rel']}")
    except Exception as e:
        log(f'Falló el cambio ({e!r}); deshaciendo lo que alcanzó a moverse…')
        todo_regresado = True
        for hecho in reversed(hechos):
            try:
                if hecho[0] == 'puesto':
                    quitar(hecho[1])
                else:
                    os.makedirs(os.path.dirname(hecho[1]), exist_ok=True)
                    shutil.move(hecho[2], hecho[1])
            except Exception as e2:
                todo_regresado = False
                log(f'   ¡no se pudo deshacer {hecho}: {e2!r}! Lo de dev está en {anterior}')
        if not todo_regresado:
            raise ErrorRefresco(f'No se pudieron reemplazar los datos de dev ({e}) y no todo se pudo '
                                f'regresar: lo que falta está en {anterior}.')
        # Todo volvió a su lugar: lo que quede en el respaldo son copias a medias
        # (p. ej. un move que copió pero no pudo borrar el original).
        shutil.rmtree(anterior, ignore_errors=True)
        raise ErrorRefresco(f'No se pudieron reemplazar los datos de dev ({e}); se regresó lo que había.')
    return {'ok': True, 'respaldo': anterior}


def podar(args):
    base = os.path.abspath(args.base)
    if not os.path.isdir(base):
        return {'ok': True, 'borradas': []}
    corridas = sorted(d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d)))
    sobran = corridas[:-args.conservar] if args.conservar > 0 else corridas
    for d in sobran:
        shutil.rmtree(os.path.join(base, d), ignore_errors=True)
        log(f'   respaldo viejo borrado: {d}')
    return {'ok': True, 'borradas': sobran}


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest='comando', required=True)
    a = sub.add_parser('preparar')
    a.add_argument('--dev', required=True)
    a.add_argument('--prod', required=True)
    a.add_argument('--datos', required=True)
    a.add_argument('--trabajo', required=True)
    b = sub.add_parser('cambiar')
    b.add_argument('--plan', required=True)
    c = sub.add_parser('podar')
    c.add_argument('--base', required=True)
    c.add_argument('--conservar', type=int, default=3)
    args = p.parse_args()
    try:
        resultado = {'preparar': preparar, 'cambiar': cambiar, 'podar': podar}[args.comando](args)
    except ErrorRefresco as e:
        log(f'❌ {e}')
        print(json.dumps({'ok': False, 'error': str(e)}, ensure_ascii=False))
        sys.exit(2)
    except Exception as e:
        traceback.print_exc()
        print(json.dumps({'ok': False, 'error': f'Error inesperado: {e}'}, ensure_ascii=False))
        sys.exit(1)
    print(json.dumps(resultado, ensure_ascii=False))


if __name__ == '__main__':
    main()
