# 1.2. Reinstall over leftover CRDs (102_reinstall)

## Tested steps

1. Install the ServiceTemplate for `postgres-operator` and wait for it to report
   `valid`.
2. Deploy one MultiClusterService carrying that single service.
3. `postgres-operator` — deployed helm release in the child cluster, pods ready.
4. The MCS reports `ClusterInReadyState`.
5. Remove the services: MCS, ServiceSet, helm release and workloads all gone —
   except the CRDs, which helm leaves in the cluster on uninstall.
6. Install the whole thing again. The chart ships its CRDs in `crds/`, so this
   second install meets the ones the first left behind, and the
   `installOptions.existingCRDs` policy decides whether it proceeds. Sveltos
   overwrote the existing CRD until 1.17.0 and fails the install since.
7. Remove the services again, so the next scenario starts on an empty cluster.

## Scenario schema

```mermaid
%%{init: {'flowchart': {'padding': 10, 'nodeSpacing': 18, 'rankSpacing': 28, 'subGraphTitleMargin': {'top': 6, 'bottom': 10}}}}%%
flowchart LR
    P1["1) Build environment"]

    subgraph P2["2) Deploy services"]
        subgraph W2[" "]
            direction LR
            subgraph D1["Install ServiceTemplates"]
                T1["postgres-operator-1-14-0"]
            end

            subgraph D2["Deploy MultiClusterService"]
                subgraph DM["mcs-102-reinstall"]
                    M1["postgres-operator-1-14-0"]
                end
            end

            D1 --> D2
        end
    end

    P3["3) Upgrade services<br/>(skipped)"]

    subgraph P4["4) Clean up"]
        C1["Remove services"] --> R1["Deploy again<br/>over the CRDs left behind"] --> C3["Remove services"] --> C2["Remove k0s cluster"]
    end

    P1 --> P2 --> P3 --> P4

    classDef off fill:#d7dde5,stroke:#7c8a9c,color:#33415a
    classDef purple fill:#ede9fe,stroke:#7c3aed,color:#0b1220
    classDef pink fill:#fce7f3,stroke:#db2777,color:#0b1220
    classDef green fill:#dcfce7,stroke:#16a34a,color:#0b1220
    classDef bare fill:none,stroke:none

    class P1,P3 off
    class D1,D2 purple
    class DM,T1,M1 pink
    class C1,R1,C3,C2 green
    class W2 bare
```

Defined in [`102_reinstall.yaml`](102_reinstall.yaml).
