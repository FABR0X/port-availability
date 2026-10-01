# Verificador de puertos TCP (Linux con Docker + Windows con PowerShell)

Ejercicio: dado un puerto como argumento, determinar si esta **ABIERTO** o **CERRADO**.
Dos implementaciones equivalentes:

```
.
|-- linux/
|   |-- Dockerfile
|   `-- check_port.sh
|-- windows/
|   `-- check_port.ps1
`-- README.md
```

| Archivo | Entorno | Metodo |
|---|---|---|
| `linux/check_port.sh` + `linux/Dockerfile` | Linux (imagen Alpine en Docker) | Conexion TCP con `bash` `/dev/tcp` + `timeout` |
| `windows/check_port.ps1` | Windows PowerShell 5.1 / PowerShell 7+ | `System.Net.Sockets.TcpClient.ConnectAsync` con timeout |

Ambos scripts usan los **mismos codigos de salida**, lo que permite usarlos igual
en un pipeline o en un `if`:

| Codigo | Significado |
|---|---|
| `0` | Puerto ABIERTO |
| `1` | Puerto CERRADO o filtrado |
| `2` | Uso incorrecto (argumentos invalidos) |

---

## 1. Version Linux (Docker)

Todos los comandos de esta seccion se ejecutan **desde la carpeta `linux/`**.

### Construir la imagen

```bash
cd linux
docker build -t port-check:linux .
```

### Uso

```bash
# puerto en el localhost del contenedor / de la maquina
docker run --rm port-check:linux 80

# puerto + host destino
docker run --rm port-check:linux 5432 127.0.0.1

# opciones largas, timeout de 5 s
docker run --rm port-check:linux -p 443 -H google.com -t 5

# solo la palabra ABIERTO o CERRADO (util para scripts)
docker run --rm port-check:linux -q 3306

# revisar el estado de un puerto del equipo anfitrion (Windows)
docker run --rm port-check:linux 5432 host.docker.internal
```

Salida de ejemplo:

```
=== Verificacion de puerto ===
[INFO] Fecha/hora : 2026-10-01 14:20:02
[INFO] Host       : host.docker.internal
[INFO] Puerto     : 5432
[INFO] Timeout    : 3s
[INFO] Metodo     : conexion TCP (bash /dev/tcp)

[ ABIERTO ] El puerto 5432 en host.docker.internal acepta conexiones TCP (0 ms).
```

Tambien se puede usar el script directamente si se tiene Bash en Linux o en WSL/Git Bash:

```bash
chmod +x check_port.sh
./check_port.sh 5432 127.0.0.1
TARGET_HOST=host.docker.internal ./check_port.sh 3306 -t 5
```

Variables de entorno: `TARGET_HOST` (host por defecto) y `PORT_CHECK_TIMEOUT` (segundos).

---

## 2. Version Windows (PowerShell)

Todos los comandos de esta seccion se ejecutan **desde la carpeta `windows/`**.

### Uso

```powershell
# forma posicional: puerto
.\check_port.ps1 80

# puerto + host
.\check_port.ps1 5432 127.0.0.1

# opciones con alias
.\check_port.ps1 -Port 443 -HostName google.com -TimeoutSeconds 5
.\check_port.ps1 -p 3306 -H 127.0.0.1 -t 5
.\check_port.ps1 -q 5432            # solo ABIERTO / CERRADO

# usar el puerto en un condicional
if ((.\check_port.ps1 -q 5432) -eq 'ABIERTO') { 'Postgres responde' }

# variable de entorno en lugar del argumento
$env:TARGET_HOST = '192.168.1.10'
.\check_port.ps1 -q 8080
```

> `-HostName` acepta los alias `-H`, `-Host` y `-TargetHost`. No se puede llamar
> al parametro `-Host` directamente porque `$Host` es una variable reservada de
> PowerShell (por eso el alias es la forma comoda de escribirlo).

Funciona en Windows PowerShell 5.1 y en PowerShell 7 (`pwsh`). Si la politica de
ejecucion lo bloquea:

```powershell
powershell -ExecutionPolicy Bypass -File .\check_port.ps1 80
```

---

## 3. Como decide abierto / cerrado

- **ABIERTO**: la conexion TCP se establece. En Linux, `exec 3<>/dev/tcp/HOST/PUERTO`
  tiene exito; en PowerShell, `ConnectAsync` completa y `TcpClient.Connected` es `true`.
- **CERRADO**: llega un RST (*connection refused*), typical de un puerto sin servicio
  escuchando -> falla rapido.
- **CERRADO (filtrado)**: no llega ninguna respuesta (firewall) -> se agota el
  `timeout`. El script no puede distinguir "filtrado" de "host sin respuesta",
  asi que ambos casos se reportan como cerrado.

El `timeout` es indispensable: sin el, un puerto filtrado dejaria el script
esperando indefinidamente.

---

## 4. Notas de red en Docker Desktop (Windows/macOS)

Esto es la parte que mas confunde al comparar las dos versiones:

- Dentro del contenedor, `127.0.0.1` es **el propio contenedor**, no el equipo
  anfitrion. Por eso `docker run --rm port-check:linux 5432` da CERRADO aunque
  el PostgreSQL de Windows este escuchando en `127.0.0.1:5432`.
- Para revisar puertos del equipo anfitrion hay dos opciones:
  - `host.docker.internal` (Docker Desktop lo resuelve a la pasarela de la VM):
    `docker run --rm port-check:linux 5432 host.docker.internal`
  - `--network host` (solo da acceso al localhost de la VM de Docker, no al de
    Windows).
- La ruta de red puede no coincidir con la de Windows PowerShell: el Firewall de
  Windows puede permitir el trafico que llega de la VM (WSL) y bloquear el que
  llega por la IP de la red fisica, de modo que el mismo puerto puede reportarse
  ABIERTO desde el contenedor y CERRADO desde Windows si se usa la IP LAN.
  Compare siempre sobre el mismo destino (por ejemplo un host externo).

---

## 5. Verificacion cruzada (opcional)

```powershell
# 1. publicar un puerto desde un contenedor y verlo desde Windows
docker run -d --name srv-tcp -p 8080:8080 --entrypoint nc port-check:linux -lk -p 8080
.\windows\check_port.ps1 8080        # -> [ ABIERTO ]
docker rm -f srv-tcp

# 2. mismo host externo en las dos versiones
docker run --rm port-check:linux -q -p 443 -H google.com -t 5   # -> ABIERTO
.\windows\check_port.ps1 -q -HostName google.com -Port 443 -TimeoutSeconds 5  # -> ABIERTO
```
