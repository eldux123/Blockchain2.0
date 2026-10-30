# Contrato de Votación en Aptos (Move) — Demostración con Lógica de Hoare

Contrato inteligente de votación escrito en **Move** para la blockchain **Aptos**.
Un administrador registra candidatos, los usuarios votan (una sola vez cada uno) y
al final el administrador declara ganador al candidato con más votos.

Este proyecto está pensado como **demostración académica**: además de funcionar,
se verifica su correctitud aplicando **lógica de Hoare** (`{P} C {Q}`) sobre el
código, con pruebas unitarias que comprueban las **postcondiciones** reales.

> Todas las pruebas son **locales** (Move VM). El contrato **no** está desplegado
> en Testnet ni Mainnet.

---

## Tabla de contenido

- [¿Qué hace el contrato?](#qué-hace-el-contrato)
- [Reglas del negocio](#reglas-del-negocio)
- [Estructura del estado](#estructura-del-estado)
- [Funciones y su lógica de Hoare](#funciones-y-su-lógica-de-hoare)
- [Requisitos](#requisitos)
- [Cómo ejecutar las pruebas](#cómo-ejecutar-las-pruebas)
- [Qué prueban los tests](#qué-prueban-los-tests)
- [Casos límite conocidos](#casos-límite-conocidos)
- [Move Prover (opcional)](#move-prover-opcional)
- [Qué demuestra y qué NO demuestra](#qué-demuestra-y-qué-no-demuestra)
- [Estructura del proyecto](#estructura-del-proyecto)

---

## ¿Qué hace el contrato?

Módulo: `my_addrx::Voting` (archivo [`sources/Voting.move`](sources/Voting.move)).

1. El **administrador** (`@my_addrx`) inicializa la elección y registra el primer candidato.
2. El administrador agrega más candidatos.
3. Cualquier cuenta **vota una sola vez** por un candidato existente.
4. El administrador **declara ganador** al candidato con más votos.

El estado (candidatos, votos y votantes) se guarda como **recursos globales** dentro
de la cuenta del administrador.

---

## Reglas del negocio

| Regla | Dónde se aplica |
|-------|-----------------|
| Solo `@my_addrx` inicializa, agrega candidatos y declara ganador | `assert_is_owner` (abort `0`) |
| No se puede inicializar dos veces | `assert_uninitialized` (abort `3`) |
| Para votar/agregar/declarar, el contrato debe estar inicializado | `assert_is_initialized` (abort `1`) |
| Cada cuenta vota una sola vez | abort `6` (`E_HAS_VOTED`) |
| Solo se vota por candidatos existentes | `assert_contains_key` (abort `2`) |
| No se permiten candidatos duplicados | `assert_not_contains_key` (abort `4`) |
| Tras declarar ganador no se vota ni se agregan candidatos | abort `5` (`E_WINNER_DECLARED`) |
| Gana el de más votos; en empate, el **primero** de `c_list` | comparación estricta `max_votes < *votes` |

### Códigos de error

| Código | Nombre | Significado |
|:------:|--------|-------------|
| 0 | `E_NOT_OWNER` | Quien llama no es el administrador |
| 1 | `E_IS_NOT_INITIALIZED` | El contrato aún no fue inicializado |
| 2 | `E_DOES_NOT_CONTAIN_KEY` | El candidato buscado no existe |
| 3 | `E_IS_INITIALIZED` | El contrato ya estaba inicializado |
| 4 | `E_IS_INITIALIZED_WITH_CANDIDATE` | Candidato duplicado |
| 5 | `E_WINNER_DECLARED` | Ya hay ganador; no se admiten más cambios |
| 6 | `E_HAS_VOTED` | Esa cuenta ya había votado |

---

## Estructura del estado

```move
struct CandidateList has key {
    candidate_list: SimpleMap<address, u64>,  // candidato -> número de votos
    c_list: vector<address>,                  // candidatos en orden de registro
    winner: address                           // @0x0 mientras no haya ganador
}

struct VotingList has key {
    voters: SimpleMap<address, u64>           // votante -> 1 (marca de "ya votó")
}
```

---

## Funciones y su lógica de Hoare

La **lógica de Hoare** describe cada función con una terna `{P} C {Q}`:

- **P (precondición):** lo que debe cumplirse *antes* de llamar. En el código son los `assert!`.
- **C:** la función.
- **Q (postcondición):** lo que queda garantizado *después*, si la función no abortó.

En el archivo `Voting.move` cada función tiene su `{P}`/`{Q}` documentada en comentarios.
Resumen:

### `initialize_with_candidate(acc, c_addr)`
- **P:** `acc` es el admin **y** no existen `CandidateList` ni `VotingList`.
- **Q:** existen ambos recursos; `c_list == [c_addr]`; `votos[c_addr] == 0`; `winner == @0x0`; `voters` vacío.

### `add_candidate(acc, c_addr)`
- **P:** `acc` es admin; inicializado; `winner == @0x0`; `c_addr` no existe aún.
- **Q:** `votos[c_addr] == 0`; `c_addr` queda al **final** de `c_list`; los demás no cambian; `winner == @0x0`.

### `vote(acc, c_addr, store_addr)`
- **P:** inicializado; `winner == @0x0`; el votante no votó antes; `c_addr` existe.
- **Q:** `votos[c_addr]` sube **exactamente en 1**; los demás candidatos no cambian; el votante queda en `voters`; `winner == @0x0`.

### `declare_winner(acc)`
- **P:** `acc` es admin; inicializado; `winner == @0x0`.
- **Q:** `winner` es el candidato con **más votos**; en empate, el **primero** de `c_list`; si nadie votó, `winner` queda en `@0x0` (ver [casos límite](#casos-límite-conocidos)).

---

## Requisitos

- [Aptos CLI](https://aptos.dev/tools/aptos-cli/) instalado.
- La dependencia `AptosFramework` se descarga automáticamente (ver `Move.toml`).

El `Move.toml` usa `my_addrx = "0xCAFE"` como dirección de desarrollo (`[dev-addresses]`),
por eso las pruebas se corren con el flag `--dev`.

---

## Cómo ejecutar las pruebas

Desde la carpeta `voting/`:

```powershell
aptos move test --dev
```

Para ver solo la demostración paso a paso (imprime en consola cómo cambian los votos):

```powershell
aptos move test --dev --filter demo
```

Resultado esperado: **14 pruebas, todas PASS.**

## Demo interactiva (interfaz web + red local)

Para la demostración en vivo hay un script que prepara TODO automáticamente:
arranca la red local, fondea las cuentas, publica el contrato, inicializa la
elección y abre la interfaz web.

```powershell
# Desde la carpeta del proyecto:
.\scripts\setup-demo.ps1

# Para empezar de cero (borrar votos de una demo anterior):
.\scripts\setup-demo.ps1 -Reset
```

> Deja abierta la ventana del nodo durante toda la demo. La interfaz
> ([`frontend/demo.html`](frontend/demo.html)) necesita conexión a internet para
> cargar el SDK de Aptos. Si prefieres los comandos a mano, están en
> [`docs/COMANDOS.md`](docs/COMANDOS.md).

---

## Qué prueban los tests

Hay **14 pruebas** en total.

### Pruebas de seguridad / precondiciones (que deben **fallar** correctamente)

| Test | Verifica |
|------|----------|
| `test_initialize_with_candidate_not_owner` | No-admin no puede inicializar (abort `0`) |
| `test_initialize_with_same_candidate` | No se inicializa dos veces (abort `3`) |
| `test_vote_not_initialized` | No se vota sin inicializar (abort `1`) |
| `test_vote_twice` | Una cuenta no vota dos veces (abort `6`) |
| `test_declare_winner` | No se declara ganador dos veces (abort `5`) |
| `test_add_candidate_after_winner_declared` | No se agregan candidatos tras el ganador (abort `5`) |

### Pruebas de postcondición (comprueban el **estado resultante**, no solo que no aborte)

| Test | Postcondición verificada |
|------|--------------------------|
| `test_vote_postcondicion` | El voto sube **exactamente 1**; los demás candidatos no cambian; el votante queda en `voters` |
| `test_add_candidate_postcondicion` | El candidato nuevo queda con **0 votos** y al **final** de `c_list` |
| `test_declare_winner_postcondicion` | `winner` es el candidato con **más votos** |
| `test_declare_winner_empate` | En **empate**, gana el **primero** registrado |
| `test_declare_winner_sin_votos` | Si **nadie votó**, `winner` queda en `@0x0` (documenta el resultado real) |
| `test_invariante_suma_votos` | **Invariante:** suma de votos de todos los candidatos == número de votantes |

### Otras

| Test | Qué hace |
|------|----------|
| `test_flow` | Camino feliz completo (inicializar → agregar → votar → declarar) |
| `demo_paso_a_paso` | Igual que el flujo, pero imprime cada paso en consola para la exposición |

---

## Casos límite conocidos

Detectados al revisar el código. **No se modificó la lógica del contrato.**

1. **Sin votos no hay ganador.** `declare_winner` usa comparación estricta
   (`max_votes < *votes`) y `winner` arranca en `@0x0`. Si nadie votó, la función
   **no aborta** pero deja `winner == @0x0`, el mismo valor que significa "todavía
   no hay ganador". Documentado y probado en `test_declare_winner_sin_votos`.

2. **`@0x0` sobrecargado.** `@0x0` significa a la vez "sin ganador" y podría ser una
   dirección de candidato válida (nada impide `add_candidate(admin, @0x0)`). Si ese
   candidato ganara, `winner == @0x0` sería ambiguo.

3. **El admin y los candidatos pueden votar.** `vote` no prohíbe que el admin o un
   candidato voten. Es intencional en el diseño actual; se señala por si en tu
   modelo debiera restringirse.

Una mejora posible (que **cambiaría la estructura**) sería usar un campo
`winner_declared: bool` separado de la dirección, para no sobrecargar `@0x0`.

---

## Move Prover (opcional)

El archivo incluye, **comentadas**, especificaciones (`spec`) para `vote` y
`declare_winner`. A diferencia de los `#[test]` (que prueban ejemplos concretos),
el **Move Prover** verifica las propiedades **matemáticamente para todos los casos**.

En este entorno el backend del Prover (**Boogie + Z3**) **no está instalado**. Para usarlo:

```powershell
# 1) Instalar el backend (descarga Boogie y Z3, y fija BOOGIE_EXE y Z3_EXE)
aptos update prover-dependencies

# 2) Descomentar el bloque `spec` al final de Voting.move

# 3) Ejecutar el prover
aptos move prove
```

> Requisito previo de Boogie: el **.NET SDK** (`dotnet`), que ya está disponible en el entorno.

---

## Qué demuestra y qué NO demuestra

**Demuestra:**
- Que las **precondiciones** (`assert!`) bloquean lo que deben: no-admin, doble
  inicialización, doble voto, votar sin inicializar y cambios tras el ganador.
- Que las **postcondiciones** se cumplen inspeccionando el estado: el voto suma 1
  exacto, nadie más se altera, el ganador es correcto, el empate se resuelve por
  orden de registro y se mantiene el invariante "votos totales = votantes".
- En términos de Hoare: para cada función, que `{P} C {Q}` se cumple en los
  escenarios probados.

**NO demuestra:**
- **No es una prueba universal.** Cada `#[test]` verifica *ejemplos concretos*, no
  todos los casos posibles. Para eso se necesita el Move Prover (no instalado aquí).
- **No prueba nada en red real.** Son pruebas locales (Move VM); el contrato no está
  desplegado. No cubren gas, concurrencia ni orden real de transacciones.
- Los casos límite se **documentan**, no se afirman como comportamiento *deseado*.

---

## Estructura del proyecto

```
voting/
├── Move.toml              # Configuración del paquete y dependencias (Aptos/Move)
├── README.md              # Este archivo
├── .gitignore             # Ignora build/, .aptos/ y las claves de demo
├── sources/
│   └── Voting.move        # Contrato + lógica de Hoare (comentarios) + 14 pruebas
├── frontend/
│   └── demo.html          # Interfaz web que usa el contrato en la red local
├── scripts/
│   └── setup-demo.ps1     # Automatiza TODO el setup de la demo (un solo archivo)
├── docs/
│   └── COMANDOS.md        # Comandos manuales (alternativa al script)
├── keys/                  # Claves de las cuentas de la red local (demo)
├── .aptos/                # Config del CLI y estado de la red local (generado)
└── build/                 # Artefactos de compilación (generado)
```
