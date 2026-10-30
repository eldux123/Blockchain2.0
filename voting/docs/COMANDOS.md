# Comandos manuales de la demo

> Normalmente **no necesitas estos comandos**: el script `scripts/setup-demo.ps1`
> hace todo el proceso automáticamente. Esta guía es por si quieres ejecutar los
> pasos a mano, o entender qué hace el script por dentro.

Direcciones de las cuentas (red local):

| Rol | Perfil CLI | Dirección |
|-----|-----------|-----------|
| Admin | `default` | `0x82e85f5a4b543ee051869e43f0f4af091d35ac15ffc787554c325105ef241246` |
| Votante 1 | `votante1` | `0x1813ac6cb64e19ff99f5a8e10d58b65e02f249b106ea5ac5534405c5961c970a` |
| Votante 2 | `votante2` | `0x29efc2c044c0036ce14592c6b5ecbe5e223e905cafd9d63c86dec94ac536c6e9` |

---

## PASO 0 — Preparar la terminal (una vez por ventana)

```powershell
$env:PATH += ";$env:USERPROFILE\.aptoscli\bin"
cd c:\Users\erick\Downloads\Blockchain\ic\voting
```

## PASO 1 — Arrancar la red local (dejar esta ventana abierta)

```powershell
aptos node run-local-testnet --with-faucet
```

Para empezar de cero (borra el estado anterior):

```powershell
aptos node run-local-testnet --with-faucet --force-restart
```

## PASO 2 — Fondear cuentas y publicar el contrato (en otra ventana)

```powershell
aptos account fund-with-faucet --account default  --profile default
aptos account fund-with-faucet --account votante1 --profile votante1
aptos account fund-with-faucet --account votante2 --profile votante2

aptos move publish --named-addresses my_addrx=default --profile default --assume-yes
```

## PASO 3 — Inicializar la elección

```powershell
aptos move run --function-id default::Voting::initialize_with_candidate --args address:0x1 --assume-yes --profile default
aptos move run --function-id default::Voting::add_candidate --args address:0x2 --assume-yes --profile default
```

---

## Comandos útiles durante la demo

**Ver el estado (votos y ganador):**
```powershell
aptos account list --query resources --account default
```

**Votar** (el segundo argumento es la dirección del admin; `--profile` indica quién vota):
```powershell
# Votante 1 vota por el candidato 0x1
aptos move run --function-id default::Voting::vote --args address:0x1 address:0x82e85f5a4b543ee051869e43f0f4af091d35ac15ffc787554c325105ef241246 --assume-yes --profile votante1
```

> Si el mismo perfil vota dos veces, aborta con **E_HAS_VOTED** (prueba de la precondición).

**Declarar ganador** (solo admin):
```powershell
aptos move run --function-id default::Voting::declare_winner --assume-yes --profile default
```

> Tras declarar ganador, votar o agregar candidatos aborta con **E_WINNER_DECLARED**.
