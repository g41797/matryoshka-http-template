```mermaid
flowchart TD
    subgraph Clients_Layer [External Traffic]
        C1(Client 1)
        C2(Client 2)
        C3(Client 3)
        C4(Client 4)
    end
    subgraph Server_Boundary [odin-http server]
        direction TB
        subgraph Handlers_Layer [HTTP Handlers]
            H1[Handler 1]
            H2[Handler 2]
            H3[Handler 3]
            H4[Handler 4]
        end
    end
    M[(Shared Mailbox)]
    subgraph Workers_Layer [Matryoshka Workers]
        W1[Worker A]
        W2[Worker B]
    end
    C1 --- H1
    C2 --- H2
    C3 --- H3
    C4 --- H4
    H1 === M
    H2 === M
    H3 === M
    H4 === M
    M === W1
    M === W2
    classDef client fill:#f9f9f9,stroke:#333,stroke-width:1px;
    classDef handler fill:#e1f5fe,stroke:#01579b,stroke-width:2px;
    classDef mailbox fill:#fff9c4,stroke:#fbc02d,stroke-width:3px;
    classDef worker fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px;
    class C1,C2,C3,C4 client;
    class H1,H2,H3,H4 handler;
    class M mailbox;
    class W1,W2 worker;
```

# matryoshka-http-starter — Modular Monoliths in Odin

[![CI](https://github.com/g41797/matryoshka-http-starter/actions/workflows/ci.yml/badge.svg)](https://github.com/g41797/matryoshka-http-starter/actions/workflows/ci.yml)


Full scaffolding:

- HTTP handlers
- Workers Pipeline
- Examples
- Tests
- CI/CD
- Docs generation
- VSCode config

## Why this exists

I build server-side systems for a living.
Long-running, correct, boring in the best possible way.

After writing `sputnik` (Go) and `tofu` (Zig), I wanted the same thing in Odin:
explicit ownership, zero-copy message passing, and a thin HTTP layer — nothing more.

This repository is the first public Odin project that puts **matryoshka** and **odin-http** together into a complete, clone-and-go skeleton for real modular monoliths.

No framework.
No magic.
Just the pieces you actually need.

## Credits

- [matryoshka](https://github.com/g41797/matryoshka) — ownership-first concurrency building blocks (by me)
- [odin-http](https://github.com/laytan/odin-http) — clean HTTP/1.1 implementation (by laytan)

## Quick start

TBD

Clone it.
Open in VSCode.
Start writing your handlers and workers.

That’s it.

---

Made for Odin developers who want to ship real backend services without the usual ceremony.



## Why this exists
 
 
sad truth
first of all it's hard to start any Odin project with whole "environment" existing in another languages - examples, tests, readme, ci/cd documantation - lack of culture
 
without matryoshka and http - just simple template repo for the start
 
second - without server side processing and real projects - and now Odin has not any real system it will be in first 100 languages and not in first 10
 
Language is ready - devs are not

We need to start build prototypes of real systems

From something small
 
That's why it exists
