# E08 collector overhead smoke

E08 is a two-Worker, low-rate functional smoke for the collector-overhead
experiment. It runs three cells in a fixed order:

1. `collector-off`
2. `collector-on-10-percent`
3. `collector-on-100-percent`

This is not the formal experiment. The smoke checks that each mode is really
activated, events reach MySQL without observed queue/delivery loss, Pod-level
sampling preserves complete traces, and collector resources can be measured.
KS tests, confidence intervals, high start rates, and 8/16-node comparisons are
deferred.

## What the implementation adds

The Kubernetes controller now applies deterministic sampling at Pod scope.
All lifecycle events for a selected Pod are retained together; events are not
independently sampled. The controller publishes:

- `hooke_collector_sample_percent`
- `hooke_collector_sampling_events_total{decision}`
- `hooke_collector_queue_events_total{result}`
- `hooke_collector_delivery_events_total{result}`
- `hooke_collector_queue_depth`
- `hooke_collector_queue_capacity`
- `hooke_collector_batch_send_seconds`

The current collector uses Kubernetes informers and does not contain an eBPF
ring buffer. Therefore E08 records `ring_buffer_supported=false` and never
substitutes queue counters for ring-buffer submitted/lost counters.

The Helm chart accepts `image.digest` and renders `repository@digest`. The E08
runner uses one immutable multi-binary image for the ingester, migration,
controller, node-agent, `hookectl`, and finite workload. The node-agent
DaemonSet is constrained to the same two configured Worker nodes in both
collector-on cells.

The finite workload emits the same two SDK markers in every cell. Those markers
provide MySQL-backed ground truth even when the Kubernetes collector is off;
they are constant experimental instrumentation, not counted as collector
lifecycle events.

## Prerequisites

- an ACK kubeconfig with sufficient Helm and workload RBAC;
- exactly two Ready, schedulable physical Worker nodes with the same instance
  type and an architecture matching the E08 image;
- a working `metrics.k8s.io/v1beta1` API;
- an existing MySQL database reachable from the ACK VPC;
- Docker Buildx and push access to an ACK-reachable image registry;
- no existing `hooke-e08-system` namespace, E08 Helm release, or E08 Lease.

The read-only preflight also requires enough request headroom on each target
node for one node-agent and one of the two concurrent workload Pods. This
prevents a resource-saturated node from silently collapsing the workload onto
the other target.

The runner creates an isolated namespace and Kubernetes Secret for the DSN.
The DSN is not copied to artifacts. Cleanup removes the temporary Hooke release,
Secret, workload namespaces, and Lease.

## Build and configure

Commit the E08 implementation first. A pushed image is rejected unless it was
built from a clean worktree, and the runner requires its revision label and
metadata commit to match `HEAD`.

```bash
IMAGE_REPOSITORY=registry.example.com/hooke/e08 make e08-image-push
cp configs/collector-overhead.env.example configs/collector-overhead.env
```

Set the ACK context identity, two node names, emitted `E08_IMAGE` digest, and
the private MySQL DSN. Then enable only the context confirmation:

```bash
CONFIG=configs/collector-overhead.env make e08-ack-check
```

`--check-only` is read-only. After it passes, set
`CONFIRM_E08_EXECUTION=yes` and run:

```bash
CONFIG=configs/collector-overhead.env make e08-ack
```

## PASS criteria

- the finite Indexed Job succeeds without restarts and uses both fixed nodes;
- every workload Pod persists `USEFUL_WORK_STARTED` and
  `USEFUL_WORK_FINISHED`;
- collector-off has no controller/node-agent Pods and no controller events;
- 10% mode has retained and sampled-out events plus a partial population of
  complete Pod traces;
- 100% mode retains `POD_CREATED`, `POD_SCHEDULED`, and `CONTAINER_STARTED` for
  every workload Pod;
- invalid, queue-full, and delivery-error deltas are zero, the final queue
  depth is zero, retained equals enqueued, and sent equals enqueued;
- Metrics API samples the controller and node-agent on both target nodes;
- every workload Pod uses the configured image digest.

Artifacts are written under
`artifacts/e08-collector-overhead-smoke-<UTC timestamp>/`. The generated report
states explicitly that a smoke PASS is not a production-overhead conclusion.
