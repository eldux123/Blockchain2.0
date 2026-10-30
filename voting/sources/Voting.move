// ============================================================================
//  CONTRATO DE VOTACIÓN EN APTOS 
// ----------------------------------------------------------------------------
//  Un administrador registra candidatos, los usuarios votan (una sola vez cada
//  uno) y al final el administrador declara ganador al candidato con más votos.
//  El estado (candidatos, votos y votantes) se guarda DENTRO de la cuenta del
//  administrador como recursos globales.
// ============================================================================
module my_addrx::Voting {
    // --- Librerías (imports) ---
    use std::signer;                                   // Para obtener la dirección de quien firma la transacción
    use std::vector;                                   // Lista dinámica (la usamos para recorrer candidatos)
    use aptos_std::simple_map::{Self, SimpleMap};      // Diccionario clave-valor (candidato -> votos)
    use aptos_framework::account;                      // Solo se usa en los tests (crear cuentas de prueba)
    #[test_only]
    use std::debug;                                    // Solo en tests: imprimir valores en consola (demo)
    #[test_only]
    use std::string::utf8;                             // Solo en tests: crear textos para los mensajes de la demo

    // --- Códigos de error ---
    // En Move, cuando una validación falla se "aborta" la transacción con un número.
    // Darles nombre hace el código legible y facilita identificar por qué falló.
    const E_NOT_OWNER: u64 = 0;                      // Quien llama NO es el administrador
    const E_IS_NOT_INITIALIZED: u64 = 1;             // El contrato aún no fue inicializado
    const E_DOES_NOT_CONTAIN_KEY: u64 = 2;           // El candidato buscado no existe
    const E_IS_INITIALIZED: u64 = 3;                 // El contrato ya estaba inicializado
    const E_IS_INITIALIZED_WITH_CANDIDATE: u64 = 4;  // Intento de agregar un candidato duplicado
    const E_WINNER_DECLARED: u64 = 5;                // Ya hay ganador; no se admiten más cambios
    const E_HAS_VOTED: u64 = 6;                       // Esa cuenta ya había votado

    // --- Estructura que guarda a los candidatos y el conteo de votos ---
    // 'has key' significa que se almacena como recurso global dentro de una cuenta.
    struct CandidateList has key {
        candidate_list: SimpleMap<address, u64>,  // Mapa: dirección del candidato -> número de votos
        c_list: vector<address>,                  // Lista de candidatos (sirve para recorrerlos al contar)
        winner: address                           // Dirección del ganador (@0x0 mientras no haya ganador)
    }

    // --- Estructura que registra quién ya votó ---
    struct VotingList has key {
        voters: SimpleMap<address, u64>           // Mapa: dirección del votante -> 1 (marca de "ya votó")
    }

    // ========================================================================
    //  FUNCIONES DE VALIDACIÓN (ayudantes reutilizables)
    // ========================================================================

    // Verifica que quien llama sea el administrador (dueño del módulo).
    public fun assert_is_owner(addr: address) {
        assert!(addr == @my_addrx, 0);
    }

    // Verifica que el contrato YA esté inicializado (existen ambos recursos).
    public fun assert_is_initialized(addr: address) {
        assert!(exists<CandidateList>(addr), 1);
        assert!(exists<VotingList>(addr), 1);
    }

    // Verifica que el contrato NO esté inicializado todavía (evita inicializar dos veces).
    public fun assert_uninitialized(addr: address) {
        assert!(!exists<CandidateList>(addr), 3);
        assert!(!exists<VotingList>(addr), 3);
    }

    // Verifica que una clave (dirección) SÍ exista en el mapa.
    public fun assert_contains_key(map: &SimpleMap<address, u64>, addr: &address) {
        assert!(simple_map::contains_key(map, addr), 2);
    }

    // Verifica que una clave (dirección) NO exista en el mapa (evita duplicados).
    public fun assert_not_contains_key(map: &SimpleMap<address, u64>, addr: &address) {
        assert!(!simple_map::contains_key(map, addr), 4);
    }

    // ========================================================================
    //  FUNCIONES PRINCIPALES (acciones del contrato)
    // ========================================================================

    // 1) Inicializa el contrato y registra el PRIMER candidato.
    //    Solo el administrador puede llamarla y solo una vez.
    //
    //  ----- LÓGICA DE HOARE  {P} initialize_with_candidate {Q} -----
    //  PRECONDICIÓN  {P}  (lo que debe cumplirse ANTES; viene de los assert!):
    //     - P1: signer::address_of(acc) == @my_addrx        (assert_is_owner -> abort 0)
    //     - P2: NO existe CandidateList en addr             (assert_uninitialized -> abort 3)
    //     - P3: NO existe VotingList  en addr               (assert_uninitialized -> abort 3)
    //  POSTCONDICIÓN {Q}  (lo que queda garantizado DESPUÉS, si no abortó):
    //     - Q1: existe CandidateList en addr y existe VotingList en addr
    //     - Q2: c_list == [c_addr]  (el primer candidato quedó en la lista)
    //     - Q3: candidate_list[c_addr] == 0  (el candidato arranca con 0 votos)
    //     - Q4: winner == @0x0  (todavía no hay ganador)
    //     - Q5: voters está vacío (nadie ha votado aún)
    public entry fun initialize_with_candidate(acc: &signer, c_addr: address) acquires CandidateList {
        let addr = signer::address_of(acc);   // Dirección de quien firma
        assert_is_owner(addr);                // Debe ser el administrador
        assert_uninitialized(addr);           // No debe estar ya inicializado

        // Crea y publica el recurso con la lista de candidatos (vacía al inicio).
        let c_store = CandidateList {
            candidate_list: simple_map::create(),
            c_list: vector::empty<address>(),
            winner: @0x0,                     // Aún no hay ganador
        };
        move_to(acc, c_store);                // Guarda el recurso dentro de la cuenta del admin

        // Crea y publica el recurso con la lista de votantes (vacía al inicio).
        let v_store = VotingList {
            voters: simple_map::create(),
        };
        move_to(acc, v_store);

        // Agrega el primer candidato con 0 votos, tanto al mapa como a la lista.
        let c_store = borrow_global_mut<CandidateList>(addr);
        simple_map::add(&mut c_store.candidate_list, c_addr, 0);
        vector::push_back(&mut c_store.c_list, c_addr);
    }

    // 2) Agrega un candidato adicional. Solo el administrador y antes de haber ganador.
    //
    //  ----- LÓGICA DE HOARE  {P} add_candidate {Q} -----
    //  PRECONDICIÓN  {P}:
    //     - P1: signer::address_of(acc) == @my_addrx        (assert_is_owner -> abort 0)
    //     - P2: el contrato está inicializado               (assert_is_initialized -> abort 1)
    //     - P3: winner == @0x0  (aún no hay ganador)        (assert -> abort 5)
    //     - P4: c_addr NO está en candidate_list            (assert_not_contains_key -> abort 4)
    //  POSTCONDICIÓN {Q}:
    //     - Q1: candidate_list[c_addr] == 0  (nuevo candidato con 0 votos)
    //     - Q2: c_addr es el ÚLTIMO elemento de c_list  (se agregó con push_back)
    //     - Q3: los demás candidatos y sus votos NO cambian
    //     - Q4: winner sigue == @0x0
    public entry fun add_candidate(acc: &signer, c_addr: address) acquires CandidateList {
        let addr = signer::address_of(acc);
        assert_is_owner(addr);                              // Debe ser el administrador
        assert_is_initialized(addr);                        // El contrato ya debe existir

        let c_store = borrow_global_mut<CandidateList>(addr);
        assert!(c_store.winner == @0x0, 5);                 // No se permiten cambios si ya hay ganador
        assert_not_contains_key(&c_store.candidate_list, &c_addr); // No permitir candidatos duplicados
        simple_map::add(&mut c_store.candidate_list, c_addr, 0);   // Alta con 0 votos
        vector::push_back(&mut c_store.c_list, c_addr);
    }

    // 3) Emite un voto. Cualquier cuenta puede votar, pero UNA sola vez.
    //    'store_addr' es la cuenta del administrador donde vive el estado.
    //
    //  ----- LÓGICA DE HOARE  {P} vote {Q} -----
    //  Sea v = addr del votante (signer), c = c_addr el candidato elegido.
    //  PRECONDICIÓN  {P}:
    //     - P1: el contrato está inicializado en store_addr (assert_is_initialized -> abort 1)
    //     - P2: winner == @0x0  (aún no hay ganador)        (assert -> abort 5)
    //     - P3: v NO está en voters  (no ha votado antes)   (assert -> abort 6)
    //     - P4: c SÍ está en candidate_list (candidato real)(assert_contains_key -> abort 2)
    //  POSTCONDICIÓN {Q}:
    //     - Q1: candidate_list[c] == old(candidate_list[c]) + 1  (sube EXACTAMENTE 1)
    //     - Q2: para todo candidato k != c:  candidate_list[k] == old(candidate_list[k])
    //           (los demás candidatos NO cambian)
    //     - Q3: v queda registrado en voters (voters[v] == 1)
    //     - Q4: winner sigue == @0x0  (votar no declara ganador)
    public entry fun vote(acc: &signer, c_addr: address, store_addr: address) acquires CandidateList, VotingList {
        let addr = signer::address_of(acc);   // Dirección del votante
        assert_is_initialized(store_addr);    // El contrato debe existir

        let c_store = borrow_global_mut<CandidateList>(store_addr);
        let v_store = borrow_global_mut<VotingList>(store_addr);
        assert!(c_store.winner == @0x0, 5);                              // No se vota si ya hay ganador
        assert!(!simple_map::contains_key(&v_store.voters, &addr), 6);   // Esa cuenta no debe haber votado
        assert_contains_key(&c_store.candidate_list, &c_addr);           // El candidato debe existir

        // Suma 1 voto al candidato elegido.
        let votes = simple_map::borrow_mut(&mut c_store.candidate_list, &c_addr);
        *votes = *votes + 1;
        // Marca al votante como que "ya votó" para impedir votos repetidos.
        simple_map::add(&mut v_store.voters, addr, 1);
    }

    // 4) Declara ganador al candidato con más votos. Solo el administrador.
    //
    //  ----- LÓGICA DE HOARE  {P} declare_winner {Q} -----
    //  PRECONDICIÓN  {P}:
    //     - P1: signer::address_of(acc) == @my_addrx        (assert_is_owner -> abort 0)
    //     - P2: el contrato está inicializado               (assert_is_initialized -> abort 1)
    //     - P3: winner == @0x0  (no se puede declarar dos veces) (assert -> abort 5)
    //  POSTCONDICIÓN {Q}:
    //     - Q1: winner es un candidato tal que sus votos son >= los de cualquier otro
    //           (es decir, winner tiene el MÁXIMO de votos)
    //     - Q2: en caso de EMPATE en el máximo, winner es el PRIMERO de c_list que
    //           alcanzó ese máximo (por la comparación estricta  max_votes < *votes)
    //     - Q3: CASO LÍMITE "nadie votó" (o todos los máximos valen 0): como la
    //           comparación es estricta (0 < 0 es falso), winner queda en @0x0.
    //           Es decir, SIN votos NO hay ganador (winner == @0x0), aunque la
    //           función no aborta. Esto se documenta en test_declare_winner_sin_votos.
    //     - Q4: los votos de los candidatos NO cambian (solo se lee, no se modifica)
    public entry fun declare_winner(acc: &signer) acquires CandidateList {
        let addr = signer::address_of(acc);
        assert_is_owner(addr);                 // Debe ser el administrador
        assert_is_initialized(addr);           // El contrato debe existir

        let c_store = borrow_global_mut<CandidateList>(addr);
        assert!(c_store.winner == @0x0, 5);    // No se puede declarar ganador dos veces

        // Recorre todos los candidatos buscando el de mayor número de votos.
        let candidates = vector::length(&c_store.c_list);
        let i = 0;
        let winner: address = @0x0;            // Ganador provisional (ninguno todavía)
        let max_votes: u64 = 0;                // Máximo de votos encontrado hasta ahora
        while (i < candidates) {
            let candidate = *vector::borrow(&c_store.c_list, (i as u64));
            let votes = simple_map::borrow(&c_store.candidate_list, &candidate);
            // Comparación estricta (<): en caso de empate gana el PRIMERO que alcanzó el máximo.
            if (max_votes < *votes) {
                max_votes = *votes;
                winner = candidate;
            };
            i = i + 1;
        };
        c_store.winner = winner;               // Guarda el ganador en el estado del contrato
    }

    // ========================================================================
    //  PRUEBAS UNITARIAS
    //  Se ejecutan con: aptos move test --dev   (son pruebas LOCALES, no un despliegue)
    // ========================================================================

    // Prueba del CAMINO FELIZ completo: inicializar, agregar candidato, votar y declarar ganador.
    // 2 votos para 0x1 y 1 voto para 0x2  =>  el ganador debe ser 0x1.
    #[test(admin = @my_addrx)]
    public entry fun test_flow(admin: signer) acquires CandidateList, VotingList {
        let c_addr = @0x1;
        let c_addr2 = @0x2;
        let voter = account::create_account_for_test(@0x3);
        let voter2 = account::create_account_for_test(@0x4);
        let voter3 = account::create_account_for_test(@0x5);

        initialize_with_candidate(&admin, c_addr);
        add_candidate(&admin, c_addr2);

        // Comprueba que ambos candidatos quedaron registrados.
        let candidate_list = &borrow_global<CandidateList>(signer::address_of(&admin)).candidate_list;
        assert_contains_key(candidate_list, &c_addr);
        assert_contains_key(candidate_list, &c_addr2);

        // Emite los tres votos.
        vote(&voter, c_addr, signer::address_of(&admin));
        vote(&voter2, c_addr, signer::address_of(&admin));
        vote(&voter3, c_addr2, signer::address_of(&admin));

        // Comprueba que los tres votantes quedaron registrados.
        let voters = &borrow_global<VotingList>(signer::address_of(&admin)).voters;
        assert_contains_key(voters, &signer::address_of(&voter));
        assert_contains_key(voters, &signer::address_of(&voter2));
        assert_contains_key(voters, &signer::address_of(&voter3));

        declare_winner(&admin);

        // El ganador debe ser el candidato 0x1 (tuvo 2 votos).
        let winner = &borrow_global<CandidateList>(signer::address_of(&admin)).winner;
        assert!(winner == &c_addr, 0);
    }

    // Prueba NEGATIVA: no se puede declarar ganador dos veces (debe abortar con E_WINNER_DECLARED).
    #[test(admin = @my_addrx)]
    #[expected_failure(abort_code = E_WINNER_DECLARED)]
    public entry fun test_declare_winner(admin: signer) acquires CandidateList, VotingList {
        let c_addr = @0x1;
        let c_addr2 = @0x2;
        let voter = account::create_account_for_test(@0x3);
        let voter2 = account::create_account_for_test(@0x4);
        let voter3 = account::create_account_for_test(@0x5);

        initialize_with_candidate(&admin, c_addr);
        add_candidate(&admin, c_addr2);
        vote(&voter, c_addr, signer::address_of(&admin));
        vote(&voter2, c_addr, signer::address_of(&admin));
        vote(&voter3, c_addr2, signer::address_of(&admin));
        declare_winner(&admin);
        declare_winner(&admin);   // <-- Segunda llamada: debe fallar
    }

    // Prueba NEGATIVA: alguien que no es el administrador no puede inicializar (E_NOT_OWNER).
    #[test]
    #[expected_failure(abort_code = E_NOT_OWNER)]
    public entry fun test_initialize_with_candidate_not_owner() acquires CandidateList {
        let c_addr = @0x1;
        let not_owner = account::create_account_for_test(@0x2);
        initialize_with_candidate(&not_owner, c_addr);   // <-- No es el admin: debe fallar
    }

    // Prueba NEGATIVA: no se puede inicializar dos veces (E_IS_INITIALIZED).
    #[test(admin = @my_addrx)]
    #[expected_failure(abort_code = E_IS_INITIALIZED)]
    public entry fun test_initialize_with_same_candidate(admin: signer) acquires CandidateList {
        let c_addr = @0x1;
        initialize_with_candidate(&admin, c_addr);
        initialize_with_candidate(&admin, c_addr);   // <-- Segunda inicialización: debe fallar
    }

    // Prueba NEGATIVA: una misma cuenta no puede votar dos veces (E_HAS_VOTED).
    #[test(admin = @my_addrx)]
    #[expected_failure(abort_code = E_HAS_VOTED)]
    public entry fun test_vote_twice(admin: signer) acquires CandidateList, VotingList {
        let c_addr = @0x1;
        let voter = account::create_account_for_test(@0x2);
        initialize_with_candidate(&admin, c_addr);
        vote(&voter, c_addr, signer::address_of(&admin));
        vote(&voter, c_addr, signer::address_of(&admin));   // <-- Segundo voto: debe fallar
    }

    // Prueba NEGATIVA: no se puede votar si el contrato no fue inicializado (E_IS_NOT_INITIALIZED).
    #[test(admin = @my_addrx)]
    #[expected_failure(abort_code = E_IS_NOT_INITIALIZED)]
    public entry fun test_vote_not_initialized(admin: signer) acquires CandidateList, VotingList {
        let c_addr = @0x1;
        let voter = account::create_account_for_test(@0x2);
        vote(&voter, c_addr, signer::address_of(&admin));   // <-- Sin inicializar: debe fallar
    }

    // Prueba NEGATIVA: no se pueden agregar candidatos después de declarar ganador (E_WINNER_DECLARED).
    #[test(admin = @my_addrx)]
    #[expected_failure(abort_code = E_WINNER_DECLARED)]
    public entry fun test_add_candidate_after_winner_declared(admin: signer) acquires CandidateList, VotingList {
        let c_addr = @0x1;
        let c_addr2 = @0x2;
        let c_addr3 = @0x3;
        let voter = account::create_account_for_test(@0x2);
        let voter2 = account::create_account_for_test(@0x3);
        initialize_with_candidate(&admin, c_addr);
        add_candidate(&admin, c_addr2);
        vote(&voter, c_addr, signer::address_of(&admin));
        vote(&voter2, c_addr, signer::address_of(&admin));
        declare_winner(&admin);
        add_candidate(&admin, c_addr3);   // <-- Agregar tras el ganador: debe fallar
    }

    // ========================================================================
    //  PRUEBAS DE POSTCONDICIÓN  {P} C {Q}
    //  Estas pruebas NO se limitan a "no abortó": leen el estado DESPUÉS de la
    //  llamada y COMPRUEBAN que las postcondiciones (Q) realmente se cumplen.
    // ========================================================================

    // ---- Ayudante solo-para-tests: devuelve los votos de un candidato ----
    #[test_only]
    fun votos_de(store_addr: address, c_addr: address): u64 acquires CandidateList {
        *simple_map::borrow(&borrow_global<CandidateList>(store_addr).candidate_list, &c_addr)
    }

    // POSTCONDICIÓN de vote:
    //   Q1: el candidato votado sube EXACTAMENTE en 1.
    //   Q2: los demás candidatos NO cambian.
    //   Q3: la cuenta votante queda registrada en voters.
    #[test(admin = @my_addrx)]
    public entry fun test_vote_postcondicion(admin: signer) acquires CandidateList, VotingList {
        let a = @0x1;
        let b = @0x2;
        let admin_addr = signer::address_of(&admin);
        let votante = account::create_account_for_test(@0x10);

        initialize_with_candidate(&admin, a);
        add_candidate(&admin, b);

        // Estado ANTES de votar (old).
        let votos_a_antes = votos_de(admin_addr, a);
        let votos_b_antes = votos_de(admin_addr, b);

        vote(&votante, a, admin_addr);

        // Q1: a sube EXACTAMENTE en 1.
        assert!(votos_de(admin_addr, a) == votos_a_antes + 1, 100);
        // Q2: b (el otro candidato) NO cambió.
        assert!(votos_de(admin_addr, b) == votos_b_antes, 101);
        // Q3: el votante quedó registrado en voters.
        let voters = &borrow_global<VotingList>(admin_addr).voters;
        assert!(simple_map::contains_key(voters, &signer::address_of(&votante)), 102);
    }

    // POSTCONDICIÓN de add_candidate:
    //   Q1: el candidato nuevo queda con 0 votos.
    //   Q2: el candidato nuevo queda al FINAL de c_list.
    #[test(admin = @my_addrx)]
    public entry fun test_add_candidate_postcondicion(admin: signer) acquires CandidateList {
        let a = @0x1;
        let b = @0x2;
        let admin_addr = signer::address_of(&admin);

        initialize_with_candidate(&admin, a);
        add_candidate(&admin, b);

        // Q1: el candidato b arranca con 0 votos.
        assert!(votos_de(admin_addr, b) == 0, 110);

        // Q2: b es el ÚLTIMO elemento de c_list.
        let c_list = &borrow_global<CandidateList>(admin_addr).c_list;
        let n = vector::length(c_list);
        assert!(*vector::borrow(c_list, n - 1) == b, 111);
        // Y sigue siendo el primero el candidato inicial a.
        assert!(*vector::borrow(c_list, 0) == a, 112);
    }

    // POSTCONDICIÓN de declare_winner:
    //   Q1: winner es el candidato con MÁS votos.
    #[test(admin = @my_addrx)]
    public entry fun test_declare_winner_postcondicion(admin: signer) acquires CandidateList, VotingList {
        let a = @0x1;
        let b = @0x2;
        let admin_addr = signer::address_of(&admin);
        let v1 = account::create_account_for_test(@0x10);
        let v2 = account::create_account_for_test(@0x11);
        let v3 = account::create_account_for_test(@0x12);

        initialize_with_candidate(&admin, a);
        add_candidate(&admin, b);
        // a recibe 2 votos, b recibe 1 => gana a.
        vote(&v1, a, admin_addr);
        vote(&v2, a, admin_addr);
        vote(&v3, b, admin_addr);

        declare_winner(&admin);

        // Q1: el ganador es el de más votos (a, con 2).
        let winner = borrow_global<CandidateList>(admin_addr).winner;
        assert!(winner == a, 120);
        // Verificación extra: a de verdad tiene >= votos que b.
        assert!(votos_de(admin_addr, a) >= votos_de(admin_addr, b), 121);
    }

    // POSTCONDICIÓN de declare_winner con EMPATE:
    //   Q2: en empate gana el PRIMERO registrado en c_list.
    //   Aquí a y b empatan a 1 voto; a se registró primero => gana a.
    #[test(admin = @my_addrx)]
    public entry fun test_declare_winner_empate(admin: signer) acquires CandidateList, VotingList {
        let a = @0x1;   // registrado primero
        let b = @0x2;   // registrado después
        let admin_addr = signer::address_of(&admin);
        let v1 = account::create_account_for_test(@0x10);
        let v2 = account::create_account_for_test(@0x11);

        initialize_with_candidate(&admin, a);
        add_candidate(&admin, b);
        // Empate 1 a 1.
        vote(&v1, a, admin_addr);
        vote(&v2, b, admin_addr);

        declare_winner(&admin);

        // Q2: con empate gana el primero de c_list (a).
        let winner = borrow_global<CandidateList>(admin_addr).winner;
        assert!(winner == a, 130);
        // Confirmamos que de verdad fue empate (mismos votos).
        assert!(votos_de(admin_addr, a) == votos_de(admin_addr, b), 131);
    }

    // CASO LÍMITE de declare_winner: NADIE votó.
    //   Documenta el RESULTADO REAL: como la comparación es estricta (0 < 0 falso),
    //   winner queda en @0x0. Es decir, SIN votos NO hay ganador y la función NO aborta.
    #[test(admin = @my_addrx)]
    public entry fun test_declare_winner_sin_votos(admin: signer) acquires CandidateList {
        let a = @0x1;
        let b = @0x2;
        let admin_addr = signer::address_of(&admin);

        initialize_with_candidate(&admin, a);
        add_candidate(&admin, b);
        // Nadie vota.
        declare_winner(&admin);

        // RESULTADO REAL: winner sigue en @0x0 (no hay ganador aunque no abortó).
        let winner = borrow_global<CandidateList>(admin_addr).winner;
        assert!(winner == @0x0, 140);
    }

    // ========================================================================
    //  PRUEBA DE INVARIANTE
    //  Invariante del sistema:  suma de votos de TODOS los candidatos
    //                           == número de cuentas en voters.
    //  (cada cuenta vota exactamente una vez => cada voto suma 1 a algún candidato
    //   y agrega exactamente 1 entrada a voters.)
    // ========================================================================
    #[test(admin = @my_addrx)]
    public entry fun test_invariante_suma_votos(admin: signer) acquires CandidateList, VotingList {
        let a = @0x1;
        let b = @0x2;
        let c = @0x3;
        let admin_addr = signer::address_of(&admin);

        initialize_with_candidate(&admin, a);
        add_candidate(&admin, b);
        add_candidate(&admin, c);

        // 5 cuentas votan (3 por a, 1 por b, 1 por c).
        let v1 = account::create_account_for_test(@0x10);
        let v2 = account::create_account_for_test(@0x11);
        let v3 = account::create_account_for_test(@0x12);
        let v4 = account::create_account_for_test(@0x13);
        let v5 = account::create_account_for_test(@0x14);
        vote(&v1, a, admin_addr);
        vote(&v2, a, admin_addr);
        vote(&v3, a, admin_addr);
        vote(&v4, b, admin_addr);
        vote(&v5, c, admin_addr);

        // Suma de votos recorriendo c_list.
        let c_store = borrow_global<CandidateList>(admin_addr);
        let total_votos: u64 = 0;
        let i = 0;
        let n = vector::length(&c_store.c_list);
        while (i < n) {
            let cand = *vector::borrow(&c_store.c_list, i);
            total_votos = total_votos + *simple_map::borrow(&c_store.candidate_list, &cand);
            i = i + 1;
        };

        // Número de votantes registrados.
        let num_votantes = simple_map::length(&borrow_global<VotingList>(admin_addr).voters);

        // INVARIANTE: total de votos == número de votantes.
        assert!(total_votos == num_votantes, 150);
        // En este escenario concreto deben ser 5.
        assert!(total_votos == 5, 151);
    }

    // ========================================================================
    //  PRUEBA DE DEMOSTRACIÓN (para la presentación)
    //  Imprime en consola cada paso para VER cómo cambian los votos y el ganador.
    //  Ejecutar con:  aptos move test --dev --filter demo
    // ========================================================================
    #[test(admin = @my_addrx)]
    public entry fun demo_paso_a_paso(admin: signer) acquires CandidateList, VotingList {
        let admin_addr = signer::address_of(&admin);
        let candidato_A = @0x1;   // candidato A
        let candidato_B = @0x2;   // candidato B

        // Creamos tres votantes de prueba.
        let votante1 = account::create_account_for_test(@0x3);
        let votante2 = account::create_account_for_test(@0x4);
        let votante3 = account::create_account_for_test(@0x5);

        debug::print(&utf8(b"=== PASO 1: Inicializar eleccion y registrar candidato A ==="));
        initialize_with_candidate(&admin, candidato_A);
        debug::print(&utf8(b"Votos del candidato A (0x1):"));
        debug::print(simple_map::borrow(&borrow_global<CandidateList>(admin_addr).candidate_list, &candidato_A));

        debug::print(&utf8(b"=== PASO 2: Agregar candidato B ==="));
        add_candidate(&admin, candidato_B);
        debug::print(&utf8(b"Votos del candidato B (0x2):"));
        debug::print(simple_map::borrow(&borrow_global<CandidateList>(admin_addr).candidate_list, &candidato_B));

        debug::print(&utf8(b"=== PASO 3: Votan 3 personas (2 por A, 1 por B) ==="));
        vote(&votante1, candidato_A, admin_addr);
        vote(&votante2, candidato_A, admin_addr);
        vote(&votante3, candidato_B, admin_addr);

        debug::print(&utf8(b"Votos finales del candidato A (0x1):"));
        debug::print(simple_map::borrow(&borrow_global<CandidateList>(admin_addr).candidate_list, &candidato_A));
        debug::print(&utf8(b"Votos finales del candidato B (0x2):"));
        debug::print(simple_map::borrow(&borrow_global<CandidateList>(admin_addr).candidate_list, &candidato_B));

        debug::print(&utf8(b"=== PASO 4: Declarar ganador ==="));
        declare_winner(&admin);
        debug::print(&utf8(b"Direccion del GANADOR (deberia ser 0x1):"));
        debug::print(&borrow_global<CandidateList>(admin_addr).winner);

        // Comprobacion automatica: el ganador debe ser el candidato A.
        assert!(borrow_global<CandidateList>(admin_addr).winner == candidato_A, 0);
    }

    // ========================================================================
    //  (OPCIONAL) ESPECIFICACIONES PARA EL MOVE PROVER
    // ------------------------------------------------------------------------
    //  Esto NO son tests: son especificaciones formales que el Move Prover
    //  verifica MATEMÁTICAMENTE para TODOS los casos posibles (no solo los
    //  ejemplos de los #[test]). Se ejecutarían con:   aptos move prove
    //
    //  IMPORTANTE: están COMENTADAS a propósito. En este entorno el backend del
    //  Prover (Boogie + Z3) NO está instalado, así que dejarlas activas no
    //  aporta nada al `aptos move test` y podría estorbar. Para usarlas:
    //    1) Instala el backend:   aptos update prover-dependencies
    //       (descarga Boogie y Z3 y fija las variables BOOGIE_EXE y Z3_EXE)
    //       Requisitos previos: .NET SDK (ya tienes dotnet) para Boogie.
    //    2) Descomenta el bloque `spec` de abajo.
    //    3) Ejecuta:   aptos move prove
    //
    //  spec vote {
    //      // El voto sube EXACTAMENTE en 1 para el candidato elegido (Q1).
    //      ensures simple_map::spec_get(
    //                  global<CandidateList>(store_addr).candidate_list, c_addr)
    //              == old(simple_map::spec_get(
    //                  global<CandidateList>(store_addr).candidate_list, c_addr)) + 1;
    //      // El votante queda registrado en voters (Q3).
    //      ensures simple_map::spec_contains_key(
    //                  global<VotingList>(store_addr).voters, signer::address_of(acc));
    //      // Abortos: debe abortar si no hay candidato, si ya votó, o si ya hay ganador.
    //      aborts_if !exists<CandidateList>(store_addr);
    //      aborts_if !exists<VotingList>(store_addr);
    //      aborts_if global<CandidateList>(store_addr).winner != @0x0;
    //      aborts_if simple_map::spec_contains_key(
    //                  global<VotingList>(store_addr).voters, signer::address_of(acc));
    //      aborts_if !simple_map::spec_contains_key(
    //                  global<CandidateList>(store_addr).candidate_list, c_addr);
    //  }
    //
    //  spec declare_winner {
    //      let addr = signer::address_of(acc);
    //      // Solo el admin, inicializado y sin ganador previo.
    //      aborts_if addr != @my_addrx;
    //      aborts_if !exists<CandidateList>(addr);
    //      aborts_if !exists<VotingList>(addr);
    //      aborts_if global<CandidateList>(addr).winner != @0x0;
    //      // (Nota) Probar formalmente "winner es el de MÁS votos" requiere
    //      // cuantificar sobre c_list con un invariante de bucle (spec del while).
    //      // Para la demo basta con la propiedad de abortos + los #[test] de
    //      // postcondición, que ya cubren el máximo y el empate.
    //  }
    // ========================================================================
}
