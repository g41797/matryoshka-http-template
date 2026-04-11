```mermaid
flowchart TD
    %% Node Definitions
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

    %% Flow Connections
    C1 --- H1
    C2 --- H2
    C3 --- H3
    C4 --- H4

    %% Fan-In Logic
    H1 === M
    H2 === M
    H3 === M
    H4 === M

    %% Fan-Out Logic
    M === W1
    M === W2

    %% Styling
    classDef client fill:#f9f9f9,stroke:#333,stroke-width:1px;
    classDef handler fill:#e1f5fe,stroke:#01579b,stroke-width:2px;
    classDef mailbox fill:#fff9c4,stroke:#fbc02d,stroke-width:3px;
    classDef worker fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px;

    class C1,C2,C3,C4 client;
    class H1,H2,H3,H4 handler;
    class M mailbox;
    class W1,W2 worker;
```

# matryoshka-http-template


[![CI](https://github.com/g41797/matryoshka-http-template/actions/workflows/ci.yml/badge.svg)](https://github.com/g41797/matryoshka-http-template/actions/workflows/ci.yml)
[![Deploy docs to GitHub Pages](https://github.com/g41797/matryoshka-http-template/actions/workflows/docs.yml/badge.svg)](https://github.com/g41797/matryoshka-http-template/actions/workflows/docs.yml)

A template repository demonstrating server-side Odin architecture using:
- [matryoshka](https://github.com/g41797/matryoshka) — building blocks
- [odin-http](https://github.com/laytan/odin-http) — HTTP facade


Work In Progress
