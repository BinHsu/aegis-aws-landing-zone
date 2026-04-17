# 014. ALB Session Affinity for gRPC Workloads

## Status
Accepted

## Context

aegis-core's architecture (per [aegis-core ADR-0017](https://github.com/BinHsu/aegis-core/blob/main/docs/adr/0017-gateway-engine-topology.md)) uses an N:N-ready topology: multiple gateway instances front multiple engine instances. The gateway is a gRPC client of the engine pool. Clients (browsers) connect to a gateway via HTTP/WebSocket.

aegis-core ADR-0004 requires session-level affinity at the gateway tier — a client's audio stream must stay pinned to one gateway instance for the duration of a transcription session (minutes to hours). Without affinity, mid-session failover drops the WebSocket connection and loses in-flight audio context.

The landing-zone must decide how the AWS Load Balancer Controller provisions the load balancer and routes traffic to the gateway pods.

### Constraints

- **Session duration**: minutes to hours (real-time transcription). Not seconds (stateless API) and not days (long-polling).
- **Protocol**: HTTP/WebSocket from client to gateway; gRPC from gateway to engine.
- **AWS Load Balancer Controller** is the ingress controller (ADR-013). It supports ALB (L7) and NLB (L4) via Ingress and Service annotations.
- **Cost**: ALB costs ~$0.02/hour + LCU charges. NLB costs ~$0.02/hour + NLCU charges. Both are negligible at lab scale.
- **Future multi-service**: the platform may serve additional HTTP endpoints (Grafana, ArgoCD UI) alongside the workload. L7 path routing is valuable for this.

## Decision

**ALB with target group stickiness (application cookie), provisioned by the AWS Load Balancer Controller via Ingress annotations.**

### Configuration

```yaml
# aegis-core Ingress annotations (for reference — lives in aegis-core manifests)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/target-group-attributes: >-
      stickiness.enabled=true,
      stickiness.type=app_cookie,
      stickiness.app_cookie.cookie_name=AEGIS_SESSION,
      stickiness.app_cookie.duration_seconds=3600
```

### Rationale

1. **ALB stickiness with application cookies** lets the gateway control session binding. The gateway sets the `AEGIS_SESSION` cookie on the first response; subsequent requests from the same client are routed to the same gateway pod. The 1-hour duration covers the expected session length with margin. If a session exceeds 1 hour, the cookie is refreshed by the gateway (rolling expiry).

2. **L7 path routing** is preserved. A single ALB can route `/api/*` to the gateway target group and `/grafana/*` to a Grafana target group (if Grafana gets an ALB later). NLB cannot do path-based routing — it would require separate NLBs per service.

3. **WebSocket upgrade works on ALB**. ALB natively supports HTTP → WebSocket upgrade. The sticky cookie ensures the upgraded connection stays on the same target. NLB would also support WebSocket (it's L4), but without the cookie-based affinity — NLB uses flow-based affinity (5-tuple hash), which breaks when the client's source port changes (NAT rebinding, mobile network switch).

4. **gRPC between gateway and engine is internal** (ClusterIP Service, not through the ALB). The ALB affinity decision only affects client → gateway routing. Gateway → engine uses client-side gRPC load balancing via a Headless Service (DNS-based, per aegis-core ADR-0017).

## Alternatives Considered

**NLB with client IP affinity.** Rejected. NLB's client IP affinity (`stickiness.enabled=true` on the target group) hashes the client's source IP. This breaks for clients behind corporate NAT (thousands of users sharing one IP get pinned to the same gateway) and for mobile clients whose IP changes mid-session. Application-cookie affinity is more reliable for session-length stickiness because the cookie survives IP changes.

**ALB with duration-based stickiness (AWSALB cookie).** Considered. ALB's built-in `lb_cookie` stickiness uses a duration-based cookie managed by the ALB itself. This works but has a 1-day minimum duration (86400 seconds) — far longer than the expected session length. Over-sticky routing means sessions that ended hours ago still pin new requests to the same target, reducing load distribution. Application cookies allow the gateway to control the exact lifecycle.

**No stickiness (stateless gateway).** Rejected. aegis-core's gateway maintains per-session state (WebSocket connection, audio buffer, engine assignment). Making it stateless would require externalizing all session state to Redis or a similar store — adding infrastructure and latency for a problem that cookie affinity solves at the load balancer level. This is over-engineering for a single-cluster lab.

**Service mesh (Istio/Linkerd) with session affinity.** Rejected for Phase 4. Service mesh adds significant operational surface (sidecar injection, mTLS certificate management, control plane) for a feature that ALB annotations provide natively. Deferred to Phase 5 if in-cluster mTLS or advanced traffic management becomes necessary.

## Consequences

The ALB is created by the AWS Load Balancer Controller when aegis-core's Ingress resource is applied. No landing-zone Terraform change is required — the LBC controller is already installed (Phase 3c) and watches for Ingress resources in all namespaces.

aegis-core is responsible for:
1. Setting the `AEGIS_SESSION` cookie in the gateway's HTTP response
2. Configuring the Ingress annotations shown above
3. Handling cookie refresh for sessions exceeding 1 hour

The platform provides:
1. AWS Load Balancer Controller (installed, IRSA-bound)
2. Public subnets tagged `kubernetes.io/role/elb=1` (for internet-facing ALB placement)
3. ACM certificate (when a domain is wired up — deferred)

Cost impact: ~$0.02/hour for the ALB when an Ingress exists. The ALB is deleted when the Ingress is deleted (ArgoCD prune or teardown). No persistent cost.
